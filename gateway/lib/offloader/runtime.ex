defmodule Offloader.Runtime do
  @moduledoc """
  Ties the catalog, the DuckDB engine, and the active snapshots together and serves
  requests. On start it loads the project (`OFFLOADER_CONFIG`), materializes each
  dataset's current manifest into the engine, and swaps a view named after the
  dataset to point at it. `serve/5` authenticates is done separately (`authorize/3`),
  compiles the endpoint + request into a plan, executes it, and returns stable JSON
  with `request_id`, `snapshot_id`, and freshness metadata.

  Snapshot refresh/rollback (G08) and hardened auth (G06) build on this; for now a
  dataset whose manifest fails to load is simply left un-materialized (its endpoints
  answer `not_ready`), so a bad manifest never takes the gateway down.
  """

  use GenServer
  require Logger

  alias Offloader.{ApiError, Auth, Catalog, Compiler, Config, Engine, Manifest}

  defstruct [:catalog, :engine, :snapshots]

  # ── public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Authorize a bearer token for an endpoint. Returns {:ok, tenant} or a stable error."
  @spec authorize(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, ApiError.t()}
  def authorize(server \\ __MODULE__, token, endpoint_name),
    do: GenServer.call(server, {:authorize, token, endpoint_name})

  @doc "Serve an endpoint for a tenant. Returns {:ok, response_map} or {:error, %ApiError{}}."
  @spec serve(GenServer.server(), String.t(), String.t(), map(), String.t()) ::
          {:ok, map()} | {:error, ApiError.t()}
  def serve(server \\ __MODULE__, endpoint_name, tenant, params, request_id),
    do: GenServer.call(server, {:serve, endpoint_name, tenant, params, request_id})

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    config_path = opts[:config_path] || Config.config_path()
    cache_dir = opts[:cache_dir] || Config.cache_dir()

    with {:ok, catalog} <- Catalog.load(config_path),
         {:ok, engine} <- Engine.start_link(cache_dir: cache_dir) do
      snapshots = materialize_all(catalog, engine)
      {:ok, %__MODULE__{catalog: catalog, engine: engine, snapshots: snapshots}}
    else
      {:error, reason} -> {:stop, {:runtime_init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:authorize, token, endpoint_name}, _from, state) do
    reply =
      with {:ok, key} <- Auth.authenticate(state.catalog.keys, token) do
        Auth.authorize(key, endpoint_name)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:serve, name, tenant, params, request_id}, _from, state) do
    result =
      with {:ok, endpoint} <- fetch_endpoint(state, name),
           {:ok, snapshot} <- fetch_snapshot(state, endpoint.dataset),
           {:ok, plan} <- Compiler.compile(endpoint, params, tenant, endpoint.dataset),
           {:ok, rows} <- execute(state.engine, plan) do
        {:ok, response(endpoint, snapshot, rows, request_id)}
      end

    {:reply, result, state}
  end

  # ── init helpers ──────────────────────────────────────────────────────────────

  defp materialize_all(catalog, engine) do
    for {id, dataset} <- catalog.datasets,
        snap = materialize_one(catalog, engine, id, dataset),
        into: %{} do
      {id, snap}
    end
  end

  defp materialize_one(catalog, engine, id, dataset) do
    manifest_path = Path.join(catalog.config_dir, dataset.manifest)

    with {:ok, manifest} <- Manifest.load(manifest_path),
         table = snapshot_table(id, manifest.snapshot_id),
         {:ok, _} <- Engine.materialize(engine, table, manifest),
         :ok <- Engine.swap(engine, id, table) do
      %{
        snapshot_id: manifest.snapshot_id,
        watermark: manifest.watermark,
        table: table
      }
    else
      other ->
        # A bad manifest leaves this dataset un-materialized (endpoints -> not_ready),
        # rather than crashing the whole gateway. Refresh/rollback is G08.
        Logger.warning("dataset #{id} not materialized: #{inspect(other)}")
        nil
    end
  end

  defp snapshot_table(dataset_id, snapshot_id) do
    "snap_" <> dataset_id <> "_" <> String.replace(snapshot_id, ~r/[^a-zA-Z0-9_]/, "_")
  end

  # ── serve helpers ─────────────────────────────────────────────────────────────

  defp fetch_endpoint(state, name) do
    case Map.fetch(state.catalog.endpoints, name) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> {:error, ApiError.new(:not_found, "endpoint not found")}
    end
  end

  defp fetch_snapshot(state, dataset) do
    case Map.fetch(state.snapshots, dataset) do
      {:ok, snapshot} -> {:ok, snapshot}
      :error -> {:error, ApiError.new(:not_ready, "snapshot is not ready")}
    end
  end

  defp execute(engine, plan) do
    case Engine.execute(engine, plan.sql, plan.params) do
      {:ok, result} ->
        {:ok, result}

      {:error, engine_error} ->
        # Never leak SQL/engine detail to the caller.
        Logger.error("engine error: #{inspect(engine_error)}")
        {:error, ApiError.new(:internal, "internal error")}
    end
  end

  defp response(endpoint, snapshot, result, request_id) do
    data = Enum.map(result.rows, fn row -> result.columns |> Enum.zip(row) |> Map.new() end)

    %{
      data: data,
      meta: %{
        request_id: request_id,
        endpoint: endpoint.name,
        snapshot_id: snapshot.snapshot_id,
        row_count: length(data),
        freshness: freshness(endpoint, snapshot)
      }
    }
  end

  defp freshness(endpoint, snapshot) do
    age = watermark_age_seconds(snapshot.watermark)
    max_minutes = endpoint.freshness_minutes

    %{
      watermark: snapshot.watermark,
      age_seconds: age,
      max_staleness_minutes: max_minutes,
      stale: is_integer(age) and is_integer(max_minutes) and age > max_minutes * 60
    }
  end

  defp watermark_age_seconds(watermark) do
    case DateTime.from_iso8601(watermark) do
      {:ok, dt, _off} -> DateTime.diff(DateTime.utc_now(), dt)
      _ -> nil
    end
  end
end
