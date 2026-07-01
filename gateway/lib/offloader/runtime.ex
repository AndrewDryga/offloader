defmodule Offloader.Runtime do
  @moduledoc """
  Ties the catalog, the DuckDB engine, and each dataset's snapshot state together,
  and serves requests. On start it loads the project (`OFFLOADER_CONFIG`) and
  refreshes every dataset once.

  Refresh is safe by construction: a candidate manifest is validated, checked for
  compatibility against the dataset contract, and materialized into a NEW table
  before the active view is atomically swapped. A failed validation or
  materialization leaves the current snapshot serving untouched and only records the
  failed attempt — the gateway never serves partial or breaking data. The previous
  good snapshot is retained so `rollback/2` can revert.

  Per dataset the state is `%{active, previous, last_attempted}`, which `serve/5`
  and the diagnostics endpoint (G09) read. An optional `:refresh_interval_ms` polls;
  by default refresh is manual/boot-only.
  """

  use GenServer
  require Logger

  alias Offloader.{ApiError, Auth, Catalog, Compiler, Config, Engine, Manifest}

  defstruct [:catalog, :engine, :snapshots, :refresh_interval_ms]

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

  @doc """
  Refresh a dataset from a manifest (defaults to the dataset's configured manifest).
  Returns {:ok, snapshot_id} on a successful swap, or {:error, reason} on a rejected
  or failed attempt — in which case the active snapshot is unchanged.
  """
  @spec refresh(GenServer.server(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def refresh(server \\ __MODULE__, dataset_id, manifest_path \\ nil),
    do: GenServer.call(server, {:refresh, dataset_id, manifest_path}, 60_000)

  @doc "Roll a dataset back to its previous good snapshot. {:ok, snapshot_id} or {:error, :no_previous}."
  @spec rollback(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def rollback(server \\ __MODULE__, dataset_id),
    do: GenServer.call(server, {:rollback, dataset_id})

  @doc "The snapshot state for a dataset: %{active, previous, last_attempted}."
  @spec snapshot_state(GenServer.server(), String.t()) :: map() | nil
  def snapshot_state(server \\ __MODULE__, dataset_id),
    do: GenServer.call(server, {:snapshot_state, dataset_id})

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    config_path = opts[:config_path] || Config.config_path()
    cache_dir = opts[:cache_dir] || Config.cache_dir()

    with {:ok, catalog} <- Catalog.load(config_path),
         {:ok, engine} <- Engine.start_link(cache_dir: cache_dir) do
      base = %__MODULE__{
        catalog: catalog,
        engine: engine,
        snapshots: %{},
        refresh_interval_ms: opts[:refresh_interval_ms]
      }

      # Initial refresh of every dataset from its configured manifest.
      state =
        Enum.reduce(Map.keys(catalog.datasets), base, fn id, acc ->
          elem(do_refresh(acc, id, nil), 0)
        end)

      schedule_poll(state)
      {:ok, state}
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
           {:ok, snapshot} <- fetch_active(state, endpoint.dataset),
           {:ok, plan} <- Compiler.compile(endpoint, params, tenant, endpoint.dataset),
           {:ok, rows} <- execute(state.engine, plan) do
        {:ok, response(endpoint, snapshot, rows, request_id)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:refresh, dataset_id, manifest_path}, _from, state) do
    {state, result} = do_refresh(state, dataset_id, manifest_path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:rollback, dataset_id}, _from, state) do
    {state, result} = do_rollback(state, dataset_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:snapshot_state, dataset_id}, _from, state) do
    {:reply, Map.get(state.snapshots, dataset_id), state}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      Enum.reduce(Map.keys(state.catalog.datasets), state, fn id, acc ->
        elem(do_refresh(acc, id, nil), 0)
      end)

    schedule_poll(state)
    {:noreply, state}
  end

  # ── refresh / rollback ──────────────────────────────────────────────────────────

  # Returns {new_state, {:ok, snapshot_id} | {:error, reason}}. Never swaps in a bad
  # snapshot: validate -> compatibility -> materialize -> atomic swap, in that order.
  defp do_refresh(state, dataset_id, manifest_path) do
    dataset = state.catalog.datasets[dataset_id]
    path = manifest_path || Path.join(state.catalog.config_dir, dataset.manifest)
    entry = current_entry(state, dataset_id)

    case Manifest.load(path) do
      {:error, errors} ->
        reject(state, dataset_id, entry, nil, :rejected, summarize(errors))

      {:ok, manifest} ->
        case Manifest.compatibility(manifest, dataset) do
          {:error, errors} ->
            reject(state, dataset_id, entry, manifest.snapshot_id, :rejected, summarize(errors))

          :ok ->
            materialize_and_swap(state, dataset_id, entry, manifest)
        end
    end
  end

  defp materialize_and_swap(state, dataset_id, entry, manifest) do
    table = snapshot_table(dataset_id, manifest.snapshot_id)

    case Engine.materialize(state.engine, table, manifest) do
      {:error, error} ->
        reject(state, dataset_id, entry, manifest.snapshot_id, :failed, error.message)

      {:ok, _} ->
        :ok = Engine.swap(state.engine, dataset_id, table)
        # Retain exactly one previous snapshot for rollback; drop older tables.
        drop_table(state.engine, entry.previous, entry.active)

        new_entry = %{
          active: snap(manifest, table),
          previous: entry.active,
          last_attempted: attempt(manifest.snapshot_id, :ok, nil)
        }

        {put_snapshot(state, dataset_id, new_entry), {:ok, manifest.snapshot_id}}
    end
  end

  defp reject(state, dataset_id, entry, snapshot_id, status, error_summary) do
    Logger.warning("refresh #{dataset_id} #{status}: #{error_summary}")
    new_entry = %{entry | last_attempted: attempt(snapshot_id, status, error_summary)}
    {put_snapshot(state, dataset_id, new_entry), {:error, status}}
  end

  defp do_rollback(state, dataset_id) do
    entry = current_entry(state, dataset_id)

    case entry.previous do
      nil ->
        {state, {:error, :no_previous}}

      previous ->
        :ok = Engine.swap(state.engine, dataset_id, previous.table)
        new_entry = %{entry | active: previous, previous: entry.active}
        {put_snapshot(state, dataset_id, new_entry), {:ok, previous.snapshot_id}}
    end
  end

  # ── state helpers ─────────────────────────────────────────────────────────────

  defp current_entry(state, dataset_id),
    do: Map.get(state.snapshots, dataset_id, %{active: nil, previous: nil, last_attempted: nil})

  defp put_snapshot(state, dataset_id, entry),
    do: %{state | snapshots: Map.put(state.snapshots, dataset_id, entry)}

  defp snap(manifest, table),
    do: %{snapshot_id: manifest.snapshot_id, watermark: manifest.watermark, table: table}

  defp attempt(snapshot_id, status, error),
    do: %{snapshot_id: snapshot_id, status: status, error: error, at: DateTime.utc_now()}

  # Drop a table unless it is still the active or previous one we are keeping.
  defp drop_table(_engine, nil, _keep), do: :ok

  defp drop_table(engine, %{table: table}, keep) do
    unless keep && table == keep.table, do: Engine.drop(engine, table)
    :ok
  end

  defp snapshot_table(dataset_id, snapshot_id),
    do: "snap_" <> dataset_id <> "_" <> String.replace(snapshot_id, ~r/[^a-zA-Z0-9_]/, "_")

  defp summarize(errors) when is_list(errors), do: "#{length(errors)} validation error(s)"
  defp summarize(other), do: inspect(other)

  defp schedule_poll(%{refresh_interval_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :poll, ms)

  defp schedule_poll(_state), do: :ok

  # ── serve helpers ─────────────────────────────────────────────────────────────

  defp fetch_endpoint(state, name) do
    case Map.fetch(state.catalog.endpoints, name) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> {:error, ApiError.new(:not_found, "endpoint not found")}
    end
  end

  defp fetch_active(state, dataset) do
    case state.snapshots[dataset] do
      %{active: %{} = active} -> {:ok, active}
      _ -> {:error, ApiError.new(:not_ready, "snapshot is not ready")}
    end
  end

  defp execute(engine, plan) do
    case Engine.execute(engine, plan.sql, plan.params) do
      {:ok, result} ->
        {:ok, result}

      {:error, engine_error} ->
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
