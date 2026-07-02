defmodule Offloader.Runtime do
  @moduledoc """
  Ties the catalog, the DuckDB engine, and each dataset's snapshot state together,
  and serves requests. On start it loads the project (`OFFLOADER_CONFIG`), seeds any
  snapshots still materialized on disk (warm start), refreshes every dataset once,
  and starts one `Offloader.Refresh.Worker` per dataset.

  ## Reads bypass the GenServer

  Serving must not queue behind a slow refresh, so the read path runs in the CALLER's
  process, not the GenServer's mailbox. The immutable catalog lives in
  `:persistent_term`; per-dataset snapshot state and the response cache live in
  concurrent ETS tables. `serve/5`, `authorize/3`, `diagnostics/1`, and the health
  reads all hit those directly — a multi-second `materialize` never blocks a request
  or a liveness probe.

  ## Refresh is per-dataset workers; the Runtime applies the bookkeeping

  Each dataset's poll loop lives in its own supervised `Refresh.Worker`, so a slow or
  wedged source delays only that dataset. The slow work (resolve, materialize, swap —
  see `Offloader.Refresh`) runs in the worker; the worker then hands the outcome to
  this GenServer (`{:apply_refresh, ...}`), which remains the single writer of the
  snapshot ETS, the response cache, and the warm-start sidecar. A failed or rejected
  refresh records the attempt and leaves the active snapshot serving. The previous
  good snapshot is retained so `rollback/2` can revert — including across a restart,
  via the sidecar (`<cache_dir>/snapshots.json`) plus the persistent DuckDB file.
  """

  use GenServer
  require Logger

  alias Offloader.{ApiError, Auth, Catalog, Compiler, Config, Engine, Refresh}
  alias Offloader.Refresh.Worker

  defstruct [
    :catalog,
    :engine,
    :snapshots,
    :snapshots_table,
    :cache_table,
    :cache_dir,
    :worker_sup,
    :refresh_interval_ms,
    # hot config reload: datasets mid schema-cutover, monitor refs of their in-flight staging
    # builds, and the auth mode the latest config asked for (the SERVED mode may lag it while a
    # tenant-scoped endpoint is still cutting over).
    pending: %{},
    staging_refs: %{},
    stage_gen: 0,
    intended_auth_mode: nil
  ]

  @snapshots_ets [:public, :set, read_concurrency: true]
  @cache_ets [:public, :set, read_concurrency: true, write_concurrency: true]
  @sidecar "snapshots.json"
  # How long to wait before re-staging a schema cutover whose build wasn't ready yet
  # (the producer may not have published matching data at the moment config changed).
  @stage_retry_ms 30_000

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
  Manually refresh a dataset (forced — re-materializes even for the same snapshot).
  `manifest_path` overrides a static dataset's configured manifest. Runs in the
  dataset's own worker; returns {:ok, snapshot_id} or {:error, reason} with the
  active snapshot untouched on failure.
  """
  @spec refresh(GenServer.server(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def refresh(server \\ __MODULE__, dataset_id, manifest_path \\ nil) do
    with runtime when is_pid(runtime) <- GenServer.whereis(server),
         worker when is_pid(worker) <- Worker.whereis(runtime, dataset_id) do
      Worker.refresh(worker, manifest_path)
    else
      _ -> {:error, :unknown_dataset}
    end
  end

  @doc "Roll a dataset back to its previous good snapshot. {:ok, snapshot_id} or {:error, :no_previous}."
  @spec rollback(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def rollback(server \\ __MODULE__, dataset_id),
    # The handler runs a writer swap (120s budget), so the CALL must allow at least
    # that — the 5s default would crash the caller for an action that still applies.
    do: GenServer.call(server, {:rollback, dataset_id}, 120_000)

  @doc """
  Hot-reload the served project from an already-validated catalog — no restart, zero
  downtime. Endpoint/data changes apply at once; a dataset SCHEMA change is staged
  blue-green (the old snapshot + endpoints keep serving while the new-schema table builds,
  then that dataset's table and endpoints flip together). Called by `Offloader.Config.Sync`.
  """
  @spec reload(GenServer.server(), Catalog.t()) :: :ok
  def reload(server \\ __MODULE__, %Catalog{} = catalog),
    do: GenServer.call(server, {:reload, catalog}, 120_000)

  @doc "The snapshot state for a dataset: %{active, previous, last_attempted}."
  @spec snapshot_state(GenServer.server(), String.t()) :: map() | nil
  def snapshot_state(server \\ __MODULE__, dataset_id) do
    case context(server) do
      nil -> nil
      ctx -> lookup_snapshot(ctx, dataset_id)
    end
  end

  @doc "The active snap for a dataset (what `serve` reads), or nil. A plain ETS read."
  @spec snapshot_active(GenServer.server(), String.t()) :: map() | nil
  def snapshot_active(server \\ __MODULE__, dataset_id) do
    case snapshot_state(server, dataset_id) do
      %{active: active} -> active
      _ -> nil
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

  @doc "True when the API serves without authentication (project `auth: none`)."
  @spec public?(GenServer.server()) :: boolean()
  def public?(server \\ __MODULE__) do
    case context(server) do
      nil -> false
      ctx -> ctx.catalog.auth_mode == "none"
    end
  end

  # ── GenServer (owns the ETS tables + all snapshot-state writes) ─────────────────

  @impl true
  def init(opts) do
    config_path = opts[:config_path] || Config.config_path()
    cache_dir = opts[:cache_dir] || Config.cache_dir()

    # Config.Loader resolves a local path as-is, or fetches a `gs://…` project tree into
    # <cache_dir>/config first — so the container can be fully stateless (config in the bucket).
    with {:ok, catalog} <- Config.Loader.load(config_path, cache_dir),
         {:ok, engine} <-
           Engine.start_link(cache_dir: cache_dir, object_store: Config.object_store()),
         # High restart intensity: with dozens of datasets, a transient burst of worker
         # crashes must not exceed the supervisor's tolerance and take down serving.
         {:ok, worker_sup} <-
           DynamicSupervisor.start_link(
             strategy: :one_for_one,
             max_restarts: 1000,
             max_seconds: 10
           ) do
      state = %__MODULE__{
        catalog: catalog,
        engine: engine,
        snapshots: %{},
        snapshots_table: :ets.new(:offloader_snapshots, @snapshots_ets),
        cache_table: :ets.new(:offloader_cache, @cache_ets),
        cache_dir: cache_dir,
        worker_sup: worker_sup,
        refresh_interval_ms: opts[:refresh_interval_ms],
        intended_auth_mode: catalog.auth_mode
      }

      # Publish the read context before the initial refresh so reads resolve at once.
      :persistent_term.put({__MODULE__, self()}, context_of(state))

      warn_missing_source_credentials(catalog)

      # Warm-start from disk first (already-materialized datasets serve at once), then
      # a per-dataset initial refresh — fault-isolated: a slow/failing source records
      # an attempt and boot moves on (engine calls return {:error}, never raise), so
      # one bad dataset can neither crash nor wedge the gateway. Workers own refresh
      # after boot.
      state =
        state
        |> seed_from_sidecar()
        |> initial_refresh()
        |> start_workers()

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

  # A worker finished a refresh: apply the bookkeeping (the single-writer step).
  @impl true
  def handle_call({:apply_refresh, dataset_id, outcome}, _from, state) do
    {:reply, :ok, apply_outcome(state, dataset_id, outcome)}
  end

  @impl true
  def handle_call({:rollback, dataset_id}, _from, state) do
    {state, result} = do_rollback(state, dataset_id)
    {:reply, result, state}
  end

  # Hot config reload: reconcile the running project against a new validated catalog.
  @impl true
  def handle_call({:reload, catalog}, _from, state) do
    {:reply, :ok, apply_reload(state, catalog)}
  end

  # A staged (blue-green) schema build finished — cut it over if it's still the current target
  # for this dataset, else drop the table it built. (async_nolink delivers `{ref, result}`.)
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.staging_refs, ref) do
      {{dataset_id, gen}, refs} ->
        Process.demonitor(ref, [:flush])
        {:noreply, on_staged_result(%{state | staging_refs: refs}, dataset_id, gen, result)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # A staging build crashed before delivering a result — retry it (unless superseded).
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.staging_refs, ref) do
      {{dataset_id, gen}, refs} ->
        Logger.error("staged build for #{dataset_id} crashed (#{inspect(reason)}) — will retry")
        state = %{state | staging_refs: refs}

        state =
          if match?(%{gen: ^gen}, state.pending[dataset_id]) do
            Process.send_after(self(), {:retry_stage, dataset_id, gen}, @stage_retry_ms)
            state
          else
            state
          end

        {:noreply, state}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # Re-attempt a schema cutover whose build wasn't ready last time (data may have caught up).
  @impl true
  def handle_info({:retry_stage, dataset_id, gen}, state) do
    state =
      case state.pending[dataset_id] do
        %{gen: ^gen} -> start_staging(state, dataset_id, gen)
        _ -> state
      end

    {:noreply, state}
  end

  # ── boot: warm start + initial refresh + workers ────────────────────────────────

  # Seed snapshot state from the sidecar for every dataset whose materialized table
  # survived in the persistent DuckDB file — endpoints serve immediately; the initial
  # refresh then no-ops (same snapshot) or picks up a newer one.
  defp seed_from_sidecar(state) do
    for {dataset_id, snap} <- read_sidecar(state.cache_dir),
        Map.has_key?(state.catalog.datasets, dataset_id),
        match?({:ok, _}, Engine.known_columns(state.engine, snap.table)),
        reduce: state do
      acc ->
        Logger.info("warm start: #{dataset_id} serving #{snap.snapshot_id} from disk")
        put_snapshot(acc, dataset_id, %{active: snap, previous: nil, last_attempted: nil})
    end
  end

  defp initial_refresh(state) do
    Enum.reduce(Map.keys(state.catalog.datasets), state, fn id, acc ->
      dataset = acc.catalog.datasets[id]
      active = current_entry(acc, id).active
      outcome = Refresh.perform(acc.engine, dataset, active, how(dataset, acc), force: false)
      apply_outcome(acc, id, outcome)
    end)
  end

  defp how(%{source: nil} = dataset, state),
    do: {:static, Path.join(state.catalog.config_dir, dataset.manifest)}

  defp how(%{source: source}, _state), do: {:source, source}

  # A `source: databricks` dataset reads from GCS: the resolver lists via the OAuth
  # token chain, and DuckDB reads via HMAC (gs://) or the bearer secret (https://). If
  # NO credentials are configured, reads 403 on a private bucket — surface that as a
  # clear boot warning instead of a silent runtime failure.
  defp warn_missing_source_credentials(catalog) do
    has_source = Enum.any?(catalog.datasets, fn {_id, ds} -> ds.source != nil end)

    if has_source and is_nil(Config.object_store()) do
      Logger.warning(
        "a dataset uses a `source:` (remote GCS) but no object-store credentials are " <>
          "configured (set OFFLOADER_GCS_AUTH=bearer or OFFLOADER_S3_TYPE=gcs) — remote " <>
          "reads will fail on a private bucket"
      )
    end
  end

  defp start_workers(state) do
    for {_id, dataset} <- state.catalog.datasets, reduce: state do
      acc -> start_worker_for(acc, dataset)
    end
  end

  defp start_worker_for(state, dataset) do
    {:ok, _pid} =
      DynamicSupervisor.start_child(
        state.worker_sup,
        {Worker,
         runtime: self(),
         dataset: dataset,
         engine: state.engine,
         config_dir: state.catalog.config_dir,
         refresh_interval_ms: state.refresh_interval_ms}
      )

    state
  end

  defp terminate_worker(state, dataset_id) do
    case Worker.whereis(self(), dataset_id) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(state.worker_sup, pid)
      _ -> :ok
    end

    state
  end

  defp restart_worker(state, dataset_id, dataset),
    do: state |> terminate_worker(dataset_id) |> start_worker_for(dataset)

  # ── hot config reload: zero-downtime reconcile (single writer) ──────────────────

  # Reconcile the running project against a new validated catalog. Removed/added/data-only
  # dataset changes and all endpoint/key/auth changes apply at once; a dataset SCHEMA change
  # is staged blue-green (see stage_one/cutover) so nothing it serves ever breaks.
  defp apply_reload(state, new) do
    old_ids = Map.keys(state.catalog.datasets)
    new_ids = Map.keys(new.datasets)

    state =
      state
      |> teardown_removed(old_ids -- new_ids)
      |> reconcile_common(new, old_ids -- (old_ids -- new_ids))
      |> add_new(new, new_ids -- old_ids)

    # Serve `new` everywhere except datasets still mid schema-cutover, which keep their
    # currently-served (old) dataset + endpoints until their build cuts over.
    served = merge_pending(new, Map.keys(state.pending), state.catalog)
    state = %{state | catalog: served, intended_auth_mode: new.auth_mode}

    Logger.info(
      "config reload applied (#{map_size(new.datasets)} datasets, #{map_size(new.endpoints)} endpoints)"
    )

    republish(state)
  end

  defp teardown_removed(state, ids) do
    for id <- ids, reduce: state do
      acc ->
        acc = terminate_worker(acc, id)
        entry = current_entry(acc, id)
        drop_table_async(acc.engine, entry.active, nil)
        drop_table_async(acc.engine, entry.previous, nil)
        :ets.delete(acc.snapshots_table, id)

        %{
          acc
          | snapshots: Map.delete(acc.snapshots, id),
            pending: Map.delete(acc.pending, id)
        }
    end
  end

  defp add_new(state, new, ids) do
    for id <- ids, reduce: state do
      # Boot does a synchronous initial refresh; a reload doesn't, so kick the new worker to
      # materialize now (a static/no-interval dataset would otherwise never poll).
      acc -> acc |> start_worker_for(new.datasets[id]) |> trigger_refresh(id)
    end
  end

  defp reconcile_common(state, new, ids) do
    for id <- ids, reduce: state do
      acc ->
        served = acc.catalog.datasets[id]
        target = new.datasets[id]

        cond do
          served == target and not Map.has_key?(acc.pending, id) ->
            acc

          schema_or_tenant_changed?(served, target) ->
            stage_one(acc, new, id)

          # data-only change, or a revert that cancels an in-flight cutover: the schema the
          # live endpoints expect is unchanged, so adopt the new def and refresh in place.
          true ->
            acc |> drop_pending(id) |> restart_worker(id, target) |> trigger_refresh(id)
        end
    end
  end

  # Nudge a dataset's worker to refresh now (used after a reload adds or re-points a dataset —
  # boot already refreshes synchronously, but a reload must trigger it explicitly).
  defp trigger_refresh(state, dataset_id) do
    case Worker.whereis(self(), dataset_id) do
      pid when is_pid(pid) -> send(pid, :poll)
      _ -> :ok
    end

    state
  end

  defp schema_or_tenant_changed?(a, b),
    do: a.schema != b.schema or a.tenant_column != b.tenant_column

  # Begin (or supersede) a blue-green schema cutover: freeze the old worker so no stale
  # refresh can clobber the swap, record the target under a fresh generation, and build the
  # new table off to the side. The old snapshot + endpoints keep serving until it's ready.
  defp stage_one(state, new, id) do
    target = new.datasets[id]

    case state.pending[id] do
      %{new_dataset: ^target} ->
        # already staging exactly this target — let the in-flight build finish
        state

      _ ->
        gen = state.stage_gen + 1

        %{state | stage_gen: gen}
        |> terminate_worker(id)
        |> put_pending(id, %{
          gen: gen,
          new_dataset: target,
          new_endpoints: endpoints_of(new, id),
          status: :staging
        })
        |> start_staging(id, gen)
    end
  end

  defp start_staging(state, id, gen) do
    dataset = state.pending[id].new_dataset
    how = how(dataset, state)
    engine = state.engine
    # A table unique to this build generation, distinct from the live snapshot table — the
    # build never touches what's currently serving.
    table = Refresh.snapshot_table(id, "stg#{gen}")

    # async_nolink monitors the build, so a task that dies before delivering a result surfaces
    # as a :DOWN and self-heals (retry) instead of wedging the dataset in `pending` forever.
    task =
      Task.Supervisor.async_nolink(Offloader.TaskSupervisor, fn ->
        Refresh.stage(engine, dataset, how, table)
      end)

    put_in(state.staging_refs[task.ref], {id, gen})
  end

  defp on_staged_result(state, id, gen, result) do
    case state.pending[id] do
      %{gen: ^gen} = pending ->
        case result do
          {:staged, snap} ->
            cutover(state, id, pending, snap)

          {_status, attempt} ->
            Logger.warning("staged schema cutover for #{id} not ready yet: #{attempt.error}")
            Process.send_after(self(), {:retry_stage, id, gen}, @stage_retry_ms)
            put_pending(state, id, %{pending | status: {:error, attempt.error}})
        end

      _ ->
        # superseded by a newer reload (or the dataset was removed): drop the built table.
        drop_staged(state, result)
    end
  end

  # The cutover. Order matters for tenant isolation: publish the NEW contract BEFORE flipping
  # the physical view. The only inconsistent read window is then new-endpoint-vs-OLD-table,
  # which fails CLOSED (a new tenant filter or a new column hits the old table and errors). The
  # reverse order could serve an OLD no-filter endpoint against the NEW (multi-tenant) table and
  # leak another tenant's rows. A schema cutover is not a rollback target, so the old-schema
  # tables are dropped and `previous` is cleared.
  defp cutover(state, id, pending, snap) do
    old_catalog = state.catalog

    published =
      state
      |> drop_pending(id)
      |> adopt(id, pending.new_dataset, pending.new_endpoints)
      |> republish()

    case Engine.swap(published.engine, id, snap.table) do
      :ok ->
        entry = current_entry(published, id)
        drop_table_async(published.engine, entry.active, snap)
        drop_table_async(published.engine, entry.previous, snap)

        published
        |> put_snapshot(id, %{active: snap, previous: nil, last_attempted: ok_attempt(snap)})
        |> flush_cache()
        |> start_worker_for(pending.new_dataset)
        |> tap(fn _ ->
          Logger.info("config reload: schema cutover complete for #{id} → #{snap.snapshot_id}")
        end)

      {:error, error} ->
        # The view never flipped. Revert to the old contract (don't keep serving new-endpoint-
        # vs-old-table errors) and retry the build. Swap of an existing table effectively never
        # fails, so this path is a belt-and-suspenders guard.
        Logger.error("cutover swap failed for #{id}: #{inspect(error)} — reverting, will retry")
        Process.send_after(self(), {:retry_stage, id, pending.gen}, @stage_retry_ms)

        %{published | catalog: old_catalog}
        |> republish()
        |> put_pending(id, pending)
    end
  end

  # Replace a dataset's contract + its endpoint group in the served catalog.
  defp adopt(state, id, dataset, endpoints) do
    kept = for {n, ep} <- state.catalog.endpoints, ep.dataset != id, into: %{}, do: {n, ep}

    catalog = %{
      state.catalog
      | datasets: Map.put(state.catalog.datasets, id, dataset),
        endpoints: Map.merge(kept, endpoints)
    }

    %{state | catalog: catalog}
  end

  # Overlay the pending (still-building) datasets' currently-served defs onto the new catalog,
  # so those datasets keep serving exactly what they serve now until their cutover lands.
  defp merge_pending(new, [], _served), do: new

  defp merge_pending(new, pending_ids, served) do
    pset = MapSet.new(pending_ids)

    datasets =
      for id <- pending_ids, reduce: new.datasets do
        acc -> Map.put(acc, id, served.datasets[id])
      end

    endpoints =
      Map.merge(
        for(
          {n, ep} <- new.endpoints,
          not MapSet.member?(pset, ep.dataset),
          into: %{},
          do: {n, ep}
        ),
        for({n, ep} <- served.endpoints, MapSet.member?(pset, ep.dataset), into: %{}, do: {n, ep})
      )

    %{new | datasets: datasets, endpoints: endpoints}
  end

  # Publish the served catalog and flush the response cache. Never serve `auth: none` while a
  # tenant-scoped endpoint is mid-cutover — fail closed to `required` until it lands.
  defp republish(state) do
    served_auth = served_auth_mode(state.intended_auth_mode, state.catalog.endpoints)
    state = put_in(state.catalog.auth_mode, served_auth)
    :persistent_term.put({__MODULE__, self()}, context_of(state))
    flush_cache(state)
  end

  defp flush_cache(state) do
    :ets.delete_all_objects(state.cache_table)
    state
  end

  defp served_auth_mode("none", endpoints) do
    if Enum.any?(endpoints, fn {_n, ep} -> ep.tenant_column != nil end) do
      Logger.warning(
        "auth: none deferred — a tenant-scoped endpoint is still mid-cutover; staying auth: required"
      )

      "required"
    else
      "none"
    end
  end

  defp served_auth_mode(mode, _endpoints), do: mode

  defp endpoints_of(catalog, id),
    do: for({n, ep} <- catalog.endpoints, ep.dataset == id, into: %{}, do: {n, ep})

  defp put_pending(state, id, entry), do: %{state | pending: Map.put(state.pending, id, entry)}
  defp drop_pending(state, id), do: %{state | pending: Map.delete(state.pending, id)}

  defp drop_staged(state, {:staged, snap}) do
    drop_table_async(state.engine, %{table: snap.table}, nil)
    state
  end

  defp drop_staged(state, _result), do: state

  defp ok_attempt(snap),
    do: %{snapshot_id: snap.snapshot_id, status: :ok, error: nil, at: DateTime.utc_now()}

  # ── applying refresh outcomes (single writer) ───────────────────────────────────

  defp apply_outcome(state, dataset_id, {:swapped, snap, attempt}) do
    entry = current_entry(state, dataset_id)
    # Retain exactly one previous snapshot for rollback; drop older tables. This is
    # fire-and-forget: dropping the superseded table is a WRITER call that can queue
    # behind a concurrent multi-minute materialize, and the Runtime must NOT block on
    # it here — otherwise every other worker's apply_refresh call times out, the
    # workers crash, and the DynamicSupervisor cascade takes down serving.
    drop_table_async(state.engine, entry.previous, entry.active)

    state =
      put_snapshot(state, dataset_id, %{
        active: snap,
        previous: entry.active,
        last_attempted: attempt
      })

    # Snapshot-based invalidation: a new snapshot drops the response cache.
    :ets.delete_all_objects(state.cache_table)
    write_sidecar(state)
    state
  end

  defp apply_outcome(state, dataset_id, {_status, attempt}) do
    entry = current_entry(state, dataset_id)
    put_snapshot(state, dataset_id, %{entry | last_attempted: attempt})
  end

  defp do_rollback(state, dataset_id) do
    entry = current_entry(state, dataset_id)

    case entry.previous do
      nil ->
        {state, {:error, :no_previous}}

      previous ->
        :ok = Engine.swap(state.engine, dataset_id, previous.table)

        state =
          put_snapshot(state, dataset_id, %{entry | active: previous, previous: entry.active})

        :ets.delete_all_objects(state.cache_table)
        write_sidecar(state)
        {state, {:ok, previous.snapshot_id}}
    end
  end

  # ── warm-start sidecar ──────────────────────────────────────────────────────────

  # %{dataset_id => active snap}, written atomically on every swap/rollback so a
  # restart can serve the on-disk snapshot before the first remote resolve.
  defp write_sidecar(state) do
    payload =
      state.snapshots
      |> Enum.filter(fn {_id, entry} -> entry.active end)
      |> Map.new(fn {id, entry} -> {id, entry.active} end)

    path = Path.join(state.cache_dir, @sidecar)
    tmp = path <> ".tmp"

    with {:ok, json} <- Jason.encode(payload),
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error -> Logger.warning("could not write warm-start sidecar: #{inspect(error)}")
    end
  end

  defp read_sidecar(cache_dir) do
    with {:ok, body} <- File.read(Path.join(cache_dir, @sidecar)),
         {:ok, payload} when is_map(payload) <- Jason.decode(body) do
      for {id, snap} <- payload, is_map(snap), is_binary(snap["snapshot_id"]), into: %{} do
        {id,
         %{
           snapshot_id: snap["snapshot_id"],
           watermark: snap["watermark"],
           table: snap["table"],
           files: snap["files"] || [],
           dir: snap["dir"]
         }}
      end
    else
      _ -> %{}
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
      config_sync: config_sync_diag(),
      datasets:
        Enum.map(ctx.catalog.datasets, fn {id, dataset} ->
          dataset_diagnostics(ctx, id, dataset)
        end)
    }
  end

  # Hot config auto-sync status, JSON-safe (or {enabled: false} when it isn't running). Read
  # caller-side from the Config.Sync process — never touches the Runtime mailbox.
  defp config_sync_diag do
    case GenServer.whereis(Offloader.Config.Sync) do
      pid when is_pid(pid) ->
        # lock-free read — the diagnostics/metrics path must never block on the Sync mailbox
        s = Offloader.Config.Sync.published_status()

        %{
          enabled: true,
          result: sync_result(s.result),
          error: sync_error(s.result),
          last_checked: iso8601(s.last_checked),
          last_applied: iso8601(s.last_applied)
        }

      _ ->
        %{enabled: false}
    end
  end

  defp sync_result({:error, _}), do: "error"
  defp sync_result(result) when is_atom(result), do: Atom.to_string(result)

  # Only the error CLASS, never the reason's payload — a fetch error like
  # {:no_config_objects, bucket, prefix} must not render the config bucket/prefix into the
  # admin diagnostics. Full detail stays in the operator log.
  defp sync_error({:error, reason}), do: error_class(reason)
  defp sync_error(_result), do: nil

  defp error_class(tag) when is_atom(tag), do: Atom.to_string(tag)

  defp error_class(tuple) when is_tuple(tuple) and is_atom(elem(tuple, 0)),
    do: Atom.to_string(elem(tuple, 0))

  defp error_class(_reason), do: "error"
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp dataset_diagnostics(ctx, id, dataset) do
    entry = lookup_snapshot(ctx, id) || %{active: nil, previous: nil, last_attempted: nil}

    %{
      dataset: id,
      source: if(dataset.source, do: dataset.source.type, else: "static_manifest"),
      # `active_snapshot` IS the last good one — a failed refresh never changes it.
      # `last_attempted` (below) carries when we last tried and its status.
      active_snapshot: snapshot_summary(entry.active),
      last_attempted: attempt_summary(entry.last_attempted),
      refresh_error: refresh_error(entry.last_attempted),
      source_reachable: source_reachable(ctx, dataset, entry),
      manifest_valid: entry.last_attempted && entry.last_attempted.status in [:ok, :unchanged],
      stale: stale?(entry.active)
    }
  end

  # Static: the manifest file is checkable directly. Dynamic: the last attempt is the
  # evidence (a failed resolve marks the source unreachable).
  defp source_reachable(ctx, %{source: nil} = dataset, _entry),
    do: File.exists?(Path.join(ctx.catalog.config_dir, dataset.manifest))

  defp source_reachable(_ctx, _dataset, %{last_attempted: nil}), do: nil

  defp source_reachable(_ctx, _dataset, %{last_attempted: attempt}),
    do: attempt.status != :failed

  defp snapshot_summary(nil), do: nil

  defp snapshot_summary(%{snapshot_id: id, watermark: wm}),
    do: %{snapshot_id: id, watermark: wm, age_seconds: watermark_age_seconds(wm)}

  defp attempt_summary(nil), do: nil

  defp attempt_summary(%{snapshot_id: id, status: status, at: at}),
    do: %{snapshot_id: id, status: status, at: DateTime.to_iso8601(at)}

  defp refresh_error(%{status: status, error: error}) when status not in [:ok, :unchanged],
    do: error

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

  # ── state helpers ─────────────────────────────────────────────────────────────

  defp current_entry(state, dataset_id),
    do: Map.get(state.snapshots, dataset_id, %{active: nil, previous: nil, last_attempted: nil})

  # Writer source of truth is the state map; mirror each change into ETS for readers.
  defp put_snapshot(state, dataset_id, entry) do
    :ets.insert(state.snapshots_table, {dataset_id, entry})
    %{state | snapshots: Map.put(state.snapshots, dataset_id, entry)}
  end

  # Drop a superseded table off the Runtime's mailbox (a slow writer call must not
  # block apply_refresh) — cleanup only, so a failed drop just leaves a stale table.
  defp drop_table_async(_engine, nil, _keep), do: :ok

  defp drop_table_async(engine, %{table: table}, keep) do
    unless keep && table == keep.table do
      Task.Supervisor.start_child(Offloader.TaskSupervisor, fn -> Engine.drop(engine, table) end)
    end

    :ok
  end

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

  defp watermark_age_seconds(watermark) when is_binary(watermark) do
    case DateTime.from_iso8601(watermark) do
      {:ok, dt, _off} -> DateTime.diff(DateTime.utc_now(), dt)
      _ -> nil
    end
  end

  defp watermark_age_seconds(_), do: nil
end
