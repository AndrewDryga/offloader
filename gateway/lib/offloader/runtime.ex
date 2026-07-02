defmodule Offloader.Runtime do
  @moduledoc """
  Ties the catalog, the DuckDB engine, and each dataset's snapshot state together,
  and serves requests. On start it loads the project (`OFFLOADER_CONFIG`) and
  refreshes every dataset once.

  ## Reads bypass the GenServer

  Serving must not queue behind a slow refresh, so the read path runs in the CALLER's
  process, not the GenServer's mailbox. The immutable catalog lives in
  `:persistent_term`; per-dataset snapshot state and the response cache live in
  concurrent ETS tables. `serve/5`, `authorize/3`, `diagnostics/1`, and the health
  reads all hit those directly — a multi-second `materialize` on the writer never
  blocks a request or a liveness probe.

  The GenServer owns only WRITES: `refresh` and `rollback` mutate the snapshot ETS
  (and drop the response cache) under its single mailbox, so a candidate snapshot is
  validated, checked for compatibility, and materialized into a NEW table before the
  active view is atomically swapped. A failed validation or materialization leaves
  the current snapshot serving untouched and only records the failed attempt — the
  gateway never serves partial or breaking data. The previous good snapshot is
  retained so `rollback/2` can revert.

  Per dataset the state is `%{active, previous, last_attempted}`. An optional
  `:refresh_interval_ms` polls; by default refresh is manual/boot-only.
  """

  use GenServer
  require Logger

  alias Offloader.{ApiError, Auth, Catalog, Compiler, Config, Engine, Manifest}

  defstruct [
    :catalog,
    :engine,
    :snapshots,
    :snapshots_table,
    :cache_table,
    :cache_dir,
    :refresh_interval_ms
  ]

  @snapshots_ets [:public, :set, read_concurrency: true]
  @cache_ets [:public, :set, read_concurrency: true, write_concurrency: true]

  # ── public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Authorize a bearer token for an endpoint. Returns {:ok, tenant} or a stable error."
  @spec authorize(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, ApiError.t()}
  def authorize(server \\ __MODULE__, token, endpoint_name) do
    case context(server) do
      nil ->
        {:error, ApiError.new(:not_ready, "service is starting")}

      ctx ->
        with {:ok, key} <- Auth.authenticate(ctx.catalog.keys, token) do
          Auth.authorize(key, endpoint_name)
        end
    end
  end

  @doc "Serve an endpoint for a tenant. Returns {:ok, response_map} or {:error, %ApiError{}}."
  @spec serve(GenServer.server(), String.t(), String.t() | nil, map(), String.t()) ::
          {:ok, map()} | {:error, ApiError.t()}
  def serve(server \\ __MODULE__, endpoint_name, tenant, params, request_id) do
    case context(server) do
      nil -> {:error, ApiError.new(:not_ready, "service is starting")}
      ctx -> do_serve(ctx, endpoint_name, tenant, params, request_id)
    end
  end

  @doc """
  Refresh a dataset from a manifest (defaults to the dataset's configured manifest).
  Returns {:ok, snapshot_id} on a successful swap, or {:error, reason} on a rejected
  or failed attempt — in which case the active snapshot is unchanged.
  """
  @spec refresh(GenServer.server(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def refresh(server \\ __MODULE__, dataset_id, manifest_path \\ nil),
    do: GenServer.call(server, {:refresh, dataset_id, manifest_path}, 120_000)

  @doc "Roll a dataset back to its previous good snapshot. {:ok, snapshot_id} or {:error, :no_previous}."
  @spec rollback(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def rollback(server \\ __MODULE__, dataset_id),
    do: GenServer.call(server, {:rollback, dataset_id})

  @doc "The snapshot state for a dataset: %{active, previous, last_attempted}."
  @spec snapshot_state(GenServer.server(), String.t()) :: map() | nil
  def snapshot_state(server \\ __MODULE__, dataset_id) do
    case context(server) do
      nil -> nil
      ctx -> lookup_snapshot(ctx, dataset_id)
    end
  end

  @doc "True once every dataset has an active snapshot serving."
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server \\ __MODULE__) do
    case context(server) do
      nil -> false
      ctx -> all_active?(ctx)
    end
  end

  @doc "The full operator diagnostics map (never contains secrets or raw credentialed paths)."
  @spec diagnostics(GenServer.server()) :: map()
  def diagnostics(server \\ __MODULE__) do
    case context(server) do
      nil -> %{ready: false, datasets: [], build_version: Offloader.version()}
      ctx -> build_diagnostics(ctx)
    end
  end

  @doc "The loaded catalog (used to generate docs/OpenAPI that match what the runtime enforces)."
  @spec catalog(GenServer.server()) :: Catalog.t() | nil
  def catalog(server \\ __MODULE__) do
    case context(server) do
      nil -> nil
      ctx -> ctx.catalog
    end
  end

  # ── GenServer (owns the ETS tables + all writes) ───────────────────────────────

  @impl true
  def init(opts) do
    config_path = opts[:config_path] || Config.config_path()
    cache_dir = opts[:cache_dir] || Config.cache_dir()

    with {:ok, catalog} <- Catalog.load(config_path),
         {:ok, engine} <-
           Engine.start_link(cache_dir: cache_dir, object_store: Config.object_store()) do
      snapshots_table = :ets.new(:offloader_snapshots, @snapshots_ets)
      cache_table = :ets.new(:offloader_cache, @cache_ets)

      state = %__MODULE__{
        catalog: catalog,
        engine: engine,
        snapshots: %{},
        snapshots_table: snapshots_table,
        cache_table: cache_table,
        cache_dir: cache_dir,
        refresh_interval_ms: opts[:refresh_interval_ms]
      }

      # Publish the read context before the initial refresh so reads resolve at once.
      :persistent_term.put({__MODULE__, self()}, context_of(state))

      # Initial refresh of every dataset from its configured manifest.
      state =
        Enum.reduce(Map.keys(catalog.datasets), state, fn id, acc ->
          elem(do_refresh(acc, id, nil), 0)
        end)

      schedule_poll(state)
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:runtime_init_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase({__MODULE__, self()})
    :ok
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
  def handle_info(:poll, state) do
    state =
      Enum.reduce(Map.keys(state.catalog.datasets), state, fn id, acc ->
        elem(do_refresh(acc, id, nil), 0)
      end)

    schedule_poll(state)
    {:noreply, state}
  end

  # ── read context (persistent_term + ETS; resolved per call) ────────────────────

  defp context(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> :persistent_term.get({__MODULE__, pid}, nil)
      _ -> nil
    end
  end

  defp context_of(state) do
    %{
      catalog: state.catalog,
      engine: state.engine,
      snapshots_table: state.snapshots_table,
      cache_table: state.cache_table,
      cache_dir: state.cache_dir
    }
  end

  defp lookup_snapshot(%{snapshots_table: table}, dataset_id) do
    case :ets.lookup(table, dataset_id) do
      [{^dataset_id, entry}] -> entry
      [] -> nil
    end
  end

  defp all_active?(ctx) do
    Enum.all?(Map.keys(ctx.catalog.datasets), fn id ->
      match?(%{active: %{}}, lookup_snapshot(ctx, id))
    end)
  end

  # ── refresh / rollback (GenServer-only writes) ─────────────────────────────────

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

        state = put_snapshot(state, dataset_id, new_entry)
        # Snapshot-based invalidation: a new snapshot drops the response cache.
        :ets.delete_all_objects(state.cache_table)
        {state, {:ok, manifest.snapshot_id}}
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
        state = put_snapshot(state, dataset_id, new_entry)
        :ets.delete_all_objects(state.cache_table)
        {state, {:ok, previous.snapshot_id}}
    end
  end

  # ── diagnostics ─────────────────────────────────────────────────────────────────

  # A redacted operator view: snapshot state, source reachability, disk, DuckDB, and
  # versions. Contains only ids/statuses/counts — never API keys, tokens, or paths
  # beyond the local cache directory.
  defp build_diagnostics(ctx) do
    %{
      build_version: Offloader.version(),
      config_version: ctx.catalog.version,
      object_store_mode: ctx.catalog.object_store_mode,
      duckdb_status: duckdb_status(ctx.engine),
      pool: Engine.pool_stats(ctx.engine),
      disk: disk_free(ctx.cache_dir),
      ready: all_active?(ctx),
      datasets:
        Enum.map(ctx.catalog.datasets, fn {id, dataset} ->
          dataset_diagnostics(ctx, id, dataset)
        end)
    }
  end

  defp dataset_diagnostics(ctx, id, dataset) do
    entry = lookup_snapshot(ctx, id) || %{active: nil, previous: nil, last_attempted: nil}
    manifest_path = Path.join(ctx.catalog.config_dir, dataset.manifest)

    %{
      dataset: id,
      active_snapshot: snapshot_summary(entry.active),
      last_good_snapshot: snapshot_summary(entry.active),
      last_attempted: attempt_summary(entry.last_attempted),
      refresh_error: refresh_error(entry.last_attempted),
      source_reachable: File.exists?(manifest_path),
      manifest_valid: entry.last_attempted && entry.last_attempted.status == :ok,
      stale: stale?(entry.active)
    }
  end

  defp snapshot_summary(nil), do: nil

  defp snapshot_summary(%{snapshot_id: id, watermark: wm}),
    do: %{snapshot_id: id, watermark: wm, age_seconds: watermark_age_seconds(wm)}

  defp attempt_summary(nil), do: nil

  defp attempt_summary(%{snapshot_id: id, status: status, at: at}),
    do: %{snapshot_id: id, status: status, at: DateTime.to_iso8601(at)}

  defp refresh_error(%{status: status, error: error}) when status != :ok, do: error
  defp refresh_error(_), do: nil

  defp stale?(nil), do: nil

  defp stale?(%{watermark: wm}) do
    case watermark_age_seconds(wm) do
      age when is_integer(age) -> age > 24 * 3600
      _ -> nil
    end
  end

  defp duckdb_status(engine) do
    case Engine.execute(engine, "SELECT 1", []) do
      {:ok, _} -> "ok"
      _ -> "error"
    end
  end

  # Free bytes on the cache filesystem via `df -Pk` (portable macOS/Linux). Best-effort.
  defp disk_free(dir) do
    with true <- is_binary(dir) and File.exists?(dir),
         {out, 0} <- System.cmd("df", ["-Pk", dir], stderr_to_stdout: true),
         [_header, data | _] <- String.split(out, "\n"),
         [_fs, _blocks, _used, avail_kb | _] <- String.split(data, ~r/\s+/) do
      %{cache_dir_free_bytes: String.to_integer(avail_kb) * 1024}
    else
      _ -> %{cache_dir_free_bytes: nil}
    end
  end

  # ── state helpers ─────────────────────────────────────────────────────────────

  defp current_entry(state, dataset_id),
    do: Map.get(state.snapshots, dataset_id, %{active: nil, previous: nil, last_attempted: nil})

  # Writer source of truth is the state map; mirror each change into ETS for readers.
  defp put_snapshot(state, dataset_id, entry) do
    :ets.insert(state.snapshots_table, {dataset_id, entry})
    %{state | snapshots: Map.put(state.snapshots, dataset_id, entry)}
  end

  defp snap(manifest, table),
    do: %{
      snapshot_id: manifest.snapshot_id,
      watermark: manifest.watermark,
      table: table,
      files: manifest.files,
      dir: manifest.dir
    }

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

  # ── serve helpers (caller process; ETS reads) ──────────────────────────────────

  defp fetch_endpoint(ctx, name) do
    case Map.fetch(ctx.catalog.endpoints, name) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> {:error, ApiError.new(:not_found, "endpoint not found")}
    end
  end

  defp fetch_active(ctx, dataset) do
    case lookup_snapshot(ctx, dataset) do
      %{active: %{} = active} -> {:ok, active}
      _ -> {:error, ApiError.new(:not_ready, "snapshot is not ready")}
    end
  end

  defp execute(engine, plan) do
    case Engine.execute(engine, plan.sql, plan.params, plan.json_columns) do
      {:ok, result} ->
        {:ok, result}

      {:error, engine_error} ->
        Logger.error("engine error: #{inspect(engine_error)}")
        {:error, ApiError.new(:internal, "internal error")}
    end
  end

  defp do_serve(ctx, name, tenant, params, request_id) do
    with {:ok, endpoint} <- fetch_endpoint(ctx, name),
         {:ok, snapshot} <- fetch_active(ctx, endpoint.dataset) do
      key = cache_key(endpoint, tenant, params, snapshot.snapshot_id)

      case cache_get(ctx, endpoint, key) do
        {:ok, data} ->
          {:ok, response(endpoint, snapshot, data, request_id, "hit")}

        :miss ->
          serve_fresh(ctx, endpoint, snapshot, tenant, params, request_id, key)
      end
    end
  end

  defp cache_get(ctx, endpoint, key) do
    if cacheable?(endpoint) do
      case :ets.lookup(ctx.cache_table, key) do
        [{^key, data}] -> {:ok, data}
        [] -> :miss
      end
    else
      :miss
    end
  end

  defp serve_fresh(ctx, endpoint, snapshot, tenant, params, request_id, key) do
    source = source_for(endpoint, snapshot)

    with {:ok, plan} <- Compiler.compile(endpoint, params, tenant, source),
         {:ok, result} <- execute(ctx.engine, plan) do
      data = Enum.map(result.rows, fn row -> result.columns |> Enum.zip(row) |> Map.new() end)

      if cacheable?(endpoint), do: :ets.insert(ctx.cache_table, {key, data})
      status = if cacheable?(endpoint), do: "miss", else: "off"
      {:ok, response(endpoint, snapshot, data, request_id, status)}
    end
  end

  # local_table (default) reads the materialized view; remote_scan reads the snapshot's
  # source files directly per request.
  defp source_for(%{serving_mode: "remote_scan"}, snapshot),
    do: {:scan, snapshot.files, snapshot.dir}

  defp source_for(endpoint, _snapshot), do: {:table, endpoint.dataset}

  defp cacheable?(%{cache_policy: "snapshot"}), do: true
  defp cacheable?(_), do: false

  # Key includes endpoint (which fixes the projection), tenant, the full request
  # params, and the snapshot id — so a new snapshot invalidates by construction.
  defp cache_key(endpoint, tenant, params, snapshot_id),
    do: {endpoint.name, endpoint.version, tenant, params, snapshot_id}

  defp response(endpoint, snapshot, data, request_id, cache_status) do
    %{
      data: data,
      meta: %{
        request_id: request_id,
        endpoint: endpoint.name,
        snapshot_id: snapshot.snapshot_id,
        row_count: length(data),
        serving_mode: endpoint.serving_mode,
        cache: cache_status,
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
