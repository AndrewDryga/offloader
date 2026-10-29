defmodule Offloader.Engine.Error do
  @moduledoc "A wrapped engine error with a stable reason atom and the underlying message."
  @enforce_keys [:reason, :message]
  defstruct [:reason, :message]

  @type t :: %__MODULE__{reason: atom(), message: String.t()}

  def new(reason, message), do: %__MODULE__{reason: reason, message: message}
end

defmodule Offloader.Engine do
  @moduledoc """
  The DuckDB materialization + query boundary. Narrow on purpose: load a validated
  snapshot into a local table, execute a compiled parameterized query against it,
  list a table's columns, and drop it once it is retired. Endpoint contracts do
  not know this exists (`docs/architecture.md` — "DuckDB is an implementation
  detail").

  ## Reads and writes are separated so reads scale

  One DuckDB *database* is shared. A single **writer** connection, owned by this
  GenServer, serializes the rare mutations (materialize / drop). **Reads go through a
  pool** of dedicated connections and *bypass the GenServer entirely* — `execute/3`
  runs in the caller's process, so thousands of concurrent requests are limited by
  DuckDB's own parallelism, not by one mailbox. Every build is its own table, so a
  write never touches what a reader queries, and DuckDB's MVCC lets a query that has
  started finish even if its table is dropped meanwhile.

  The pool is an ETS table of `{slot, connection}` plus an `:atomics` array used as a
  per-slot spinlock (0 = free, 1 = busy): a caller claims a slot with an atomic
  compare-and-swap, runs its query, and releases it — so each connection is used by
  at most one process at a time (duckdbex connections are not concurrency-safe). The
  pool handle lives in `:persistent_term` keyed by this engine's pid, so the hot path
  is a lock-free read. A slot whose connection errors is transparently reconnected
  and the query retried once.

  The database is a persistent file under `OFFLOADER_CACHE_DIR`, so materialized
  snapshots survive a restart (warm cache).

  Safety: only *values* are ever sent as query parameters (`$1`, `$2`, …). Table
  names and file paths come from validated config/manifests, never from a consumer;
  identifiers are quoted and paths are single-quote-escaped as defense in depth.

  Aggregates (`sum`, …), `to_json` (nested columns), and remote/`read_parquet`
  reads live in DuckDB extensions; every connection enables autoinstall+autoload, so
  the first run may fetch them (then cached under `~/.duckdb`). Offline runs need that
  cache present.
  """

  use GenServer
  require Logger

  alias Offloader.Engine.Error
  alias Offloader.Manifest

  @default_pool_size 16
  # Default cap on concurrent remote_scan reads (see `remote_cap/1`). 16 held up in the
  # blitz benchmark; a bigger pool then serves local_table without lifting this ceiling.
  @default_remote_cap 16
  # Full scans through the pool before giving up (with a 1ms yield between cycles).
  @max_checkout_cycles 50
  # All writer calls serialize on one connection and can queue behind a long
  # materialize, and DDL can block on a DuckDB checkpoint once the persistent DB is
  # large (dozens of datasets). So NO writer call uses the 5s GenServer default — and
  # a call that DOES exceed its budget returns {:error, timeout} rather than raising,
  # so a slow dataset can never crash a caller (boot, a refresh worker).
  @writer_timeout 120_000
  # Materializing a big table over the network (dozens of parquet parts from GCS) can
  # take minutes; give it a generous ceiling.
  @materialize_timeout 600_000

  defstruct [:db, :writer, :cache_dir, :pool]

  # ── public API ────────────────────────────────────────────────────────────────

  @doc """
  Start the engine. Opts:
    * `:cache_dir` (required) — where the persistent DuckDB file lives.
    * `:pool_size` (optional) — read connections; defaults to `OFFLOADER_POOL_SIZE`
      or `#{@default_pool_size}`.
    * `:object_store` (optional) — S3/GCS credential map applied to every connection.
    * `:name` (optional).
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Materialize a validated manifest into `table`. Returns {:ok, %{table, row_count}}.
  `sort_columns` (the dataset's filter columns) sorts the table on write so DuckDB's per-row-group
  min/max zone maps prune scans for those filters — a cheap, one-time cost at materialize.
  """
  @spec materialize(GenServer.server(), String.t(), Manifest.t(), [String.t()], [map()]) ::
          {:ok, map()} | {:error, Error.t()}
  def materialize(server, table, %Manifest{} = manifest, sort_columns \\ [], contract \\ []),
    do:
      writer_call(
        server,
        {:materialize, table, manifest, sort_columns, contract},
        @materialize_timeout
      )

  @doc """
  Run a compiled SQL string with bound value params, on a pooled read connection in
  the CALLER's process (no GenServer round-trip). Returns {:ok, %{columns, rows}}.
  `json_columns` names output columns whose (VARCHAR) value is a JSON document to be
  wrapped as a raw JSON fragment (embedded verbatim on serialize). `types:` lists each
  output column's DuckDB type (a compiled plan's `types`), used to decode DATE and
  TIMESTAMP values; without it values come back exactly as duckdbex returns them.
  """
  @spec execute(GenServer.server(), String.t(), [term()], [String.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def execute(server, sql, params \\ [], json_columns \\ [], opts \\ []) do
    case pool(server) do
      nil ->
        {:error, Error.new(:not_ready, "engine is not ready")}

      pool ->
        pooled_query(pool, sql, params, {json_columns, opts[:types] || []}, max_slots(pool, opts))
    end
  end

  # remote_scan reads hold a connection for a whole slow object-store read; cap how many pool
  # slots they may claim (`remote_cap`) so a burst can't occupy the pool and starve local_table
  # queries — which keep access to the full `size`, i.e. always `size - remote_cap` free slots.
  defp max_slots(%{size: size, remote_cap: cap}, opts), do: if(opts[:remote], do: cap, else: size)

  @doc "List a materialized table's column names in order."
  @spec known_columns(GenServer.server(), String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def known_columns(server, table),
    do: writer_call(server, {:known_columns, table}, @writer_timeout)

  @doc """
  Each manifest file's top-level column names, as `{manifest path, [name]}`: one
  `parquet_schema` read of every Parquet footer, and a DESCRIBE per CSV file.
  """
  @spec file_columns(GenServer.server(), [map()], String.t()) ::
          {:ok, [{String.t(), [String.t()]}]} | {:error, Error.t()}
  def file_columns(server, files, dir),
    do: writer_call(server, {:file_columns, files, dir}, @writer_timeout)

  @doc "Every snapshot table in the database (base tables named `snap_…`)."
  @spec snapshot_tables(GenServer.server()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def snapshot_tables(server), do: writer_call(server, :snapshot_tables, @writer_timeout)

  @doc "The columns a manifest's files load as (their union), `{name, duckdb_type}` in order."
  @spec describe_files(GenServer.server(), [map()], String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, Error.t()}
  def describe_files(server, files, dir),
    do: writer_call(server, {:describe_files, files, dir}, @writer_timeout)

  @doc "Drop a snapshot table (cleanup after a swap or in tests)."
  @spec drop(GenServer.server(), String.t()) :: :ok | {:error, Error.t()}
  def drop(server, table), do: writer_call(server, {:drop, table}, @writer_timeout)

  # A writer call that turns a timeout / down-engine into a stable {:error, Error{}},
  # never a raised exit — so one slow dataset can't take down its caller.
  defp writer_call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, Error.new(:timeout, "engine writer timed out after #{timeout}ms")}

    :exit, reason ->
      {:error, Error.new(:engine_unavailable, "engine call failed: #{inspect(reason)}")}
  end

  @doc "Pool statistics for diagnostics: %{connections, busy, saturated, remote_cap}."
  @spec pool_stats(GenServer.server()) :: map()
  def pool_stats(server) do
    case pool(server) do
      nil ->
        %{connections: 0, busy: 0, saturated: false, remote_cap: 0}

      %{locks: locks, size: size, remote_cap: cap} ->
        busy = Enum.count(1..size, fn i -> :atomics.get(locks, i) == 1 end)
        %{connections: size, busy: busy, saturated: busy >= size, remote_cap: cap}
    end
  end

  def stop(server), do: GenServer.stop(server)

  # ── GenServer (owns the writer connection + the pool lifecycle) ────────────────

  @impl true
  def init(opts) do
    cache_dir = Keyword.fetch!(opts, :cache_dir)
    File.mkdir_p!(cache_dir)
    db_path = Path.join(cache_dir, "offloader.duckdb")
    object_store = Keyword.get(opts, :object_store)
    size = pool_size(opts)

    with {:ok, db} <- open_db(db_path, 5),
         {:ok, writer} <- new_connection(db, object_store),
         :ok <- apply_db_settings(writer),
         {:ok, pool} <- build_pool(db, size, object_store) do
      :persistent_term.put({__MODULE__, self()}, pool)
      schedule_secret_refresh(object_store)
      Logger.info("Offloader engine: DuckDB ready with a #{size}-connection read pool")
      {:ok, %__MODULE__{db: db, writer: writer, cache_dir: cache_dir, pool: pool}}
    else
      {:error, reason} -> {:stop, {:engine_open_failed, reason}}
    end
  end

  # DuckDB's single-writer file lock can briefly linger after a crashed process, so a
  # supervised restart that reopens the same file immediately can fail. Retry a few times
  # with a short backoff so a transient reopen race doesn't flap the Engine straight into
  # the top supervisor's restart-intensity ceiling (an app-wide shutdown).
  defp open_db(path, attempts) when attempts > 1 do
    case open_file(path) do
      {:ok, db} ->
        {:ok, db}

      {:error, _reason} ->
        Process.sleep(200)
        open_db(path, attempts - 1)
    end
  end

  defp open_db(path, _attempts), do: open_file(path)

  # DuckDB 2.0 writes a file it creates in a format 1.5 cannot open, so rolling the image back
  # to a release on duckdbex 0.5 (v0.1.10 and earlier) would crash-loop on the cache volume.
  # Create files in the 1.5-readable format while that rollback still matters.
  defp open_file(path) do
    with {:ok, config} <- Duckdbex.create_config(),
         :ok <- Duckdbex.set_config_option(config, "storage_compatibility_version", "v1.0.0") do
      Duckdbex.open(path, config)
    end
  end

  # Keep object-store credentials (HMAC secret / session token / bearer) out of the
  # crash-report state OTP logs on an abnormal exit.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %__MODULE__{pool: %{object_store: os} = pool} = st when is_map(os) ->
        %{st | pool: %{pool | object_store: redact_credentials(os)}}

      st ->
        st
    end)
  end

  defp redact_credentials(os) do
    Enum.reduce([:secret, :token, :key_id, :session_token], os, fn k, acc ->
      if is_binary(Map.get(acc, k)), do: Map.put(acc, k, "[redacted]"), else: acc
    end)
  end

  # Bearer tokens expire (~1h); re-registering the secret on the writer rotates the
  # credential for EVERY connection of this database instance (verified: CREATE OR
  # REPLACE SECRET propagates immediately). A failed refresh retries sooner and keeps
  # serving — the old token stays valid until Google expires it.
  @impl true
  def handle_info(:refresh_object_store, state) do
    object_store = state.pool.object_store

    case Offloader.ObjectStore.configure(state.writer, object_store) do
      :ok ->
        schedule_secret_refresh(object_store)

      {:error, reason} ->
        Logger.warning("Offloader engine: object-store secret refresh failed: #{inspect(reason)}")
        Process.send_after(self(), :refresh_object_store, :timer.minutes(1))
    end

    {:noreply, state}
  end

  # Re-register the writer secret before the CURRENT token expires — driven by the
  # token's real lifetime (a metadata-server token can have only minutes left), not a
  # fixed timer that would leave the writer with an expired secret.
  defp schedule_secret_refresh(%{type: "gcs_bearer"}),
    do:
      Process.send_after(
        self(),
        :refresh_object_store,
        Offloader.Gcs.TokenCache.refresh_after_ms()
      )

  defp schedule_secret_refresh(_), do: :ok

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase({__MODULE__, self()})
    :ok
  end

  @impl true
  def handle_call({:materialize, table, manifest, sort_columns, contract}, _from, state) do
    ident = quote_ident(table)
    select = Offloader.Sql.cast_to_contract(read_expr(manifest), contract)
    sql = "CREATE OR REPLACE TABLE #{ident} AS #{select}#{order_by(sort_columns)}"

    with {:ok, _} <- run(state.writer, sql, [], :materialize_failed),
         {:ok, count} <- table_count(state.writer, ident) do
      {:reply, {:ok, %{table: table, row_count: count}}, state}
    else
      {:error, %Error{}} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:known_columns, table}, _from, state) do
    case run(state.writer, "SELECT * FROM #{quote_ident(table)} LIMIT 0", [], :unknown_table) do
      {:ok, result} -> {:reply, {:ok, Duckdbex.columns(result)}, state}
      {:error, %Error{}} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:snapshot_tables, _from, state) do
    sql =
      "SELECT table_name FROM information_schema.tables " <>
        "WHERE table_type = 'BASE TABLE' AND starts_with(table_name, 'snap_')"

    case run(state.writer, sql, [], :list_failed) do
      {:ok, result} -> {:reply, {:ok, result |> Duckdbex.fetch_all() |> List.flatten()}, state}
      {:error, %Error{}} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:describe_files, files, dir}, _from, state) do
    sql = "DESCRIBE SELECT * FROM (#{Offloader.Sql.read_files_expr(files, dir)})"

    case run(state.writer, sql, [], :schema_failed) do
      {:ok, result} ->
        {:reply, {:ok, for([name, type | _] <- Duckdbex.fetch_all(result), do: {name, type})},
         state}

      {:error, %Error{}} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:file_columns, files, dir}, _from, state) do
    {parquet, csv} = Enum.split_with(files, &(&1["format"] == "parquet"))

    with {:ok, from_parquet} <- parquet_columns(state.writer, parquet, dir),
         {:ok, from_csv} <- csv_columns(state.writer, csv, dir) do
      {:reply, {:ok, from_parquet ++ from_csv}, state}
    else
      {:error, %Error{}} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:drop, table}, _from, state) do
    case run(state.writer, "DROP TABLE IF EXISTS #{quote_ident(table)}", [], :drop_failed) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, %Error{}} = err -> {:reply, err, state}
    end
  end

  # ── read pool (lock-free checkout; runs in the caller process) ─────────────────

  defp pool(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> :persistent_term.get({__MODULE__, pid}, nil)
      _ -> nil
    end
  end

  defp pooled_query(pool, sql, params, decoding, max_slots) do
    case checkout(pool, max_slots) do
      {:ok, idx, conn} ->
        try do
          run_and_read(pool, idx, conn, sql, params, decoding)
        after
          checkin(pool, idx)
        end

      :error ->
        {:error, Error.new(:pool_busy, "all read connections are busy")}
    end
  end

  # Run on the checked-out connection. On a *connection-level* failure (network / I/O
  # / a wedged connection) — not an ordinary SQL error like an unknown table — replace
  # that slot's connection once and retry, so a single bad connection can't poison a
  # slot for every future request. Result rows are read while the slot is still held
  # (the query result is tied to its connection).
  defp run_and_read(pool, idx, conn, sql, params, decoding) do
    case run(conn, sql, params, :query_failed) do
      {:ok, result} ->
        {:ok, read_result(result, decoding)}

      {:error, %Error{} = err} = failure ->
        if retryable?(err),
          do: retry_on_fresh(pool, idx, sql, params, decoding, failure),
          else: failure
    end
  end

  defp retry_on_fresh(pool, idx, sql, params, decoding, failure) do
    case reconnect(pool, idx) do
      {:ok, fresh} ->
        case run(fresh, sql, params, :query_failed) do
          {:ok, result} -> {:ok, read_result(result, decoding)}
          {:error, %Error{}} = err2 -> err2
        end

      :error ->
        failure
    end
  end

  # A dropped/broken connection surfaces as a connection/IO/network error — those are
  # worth a reconnect. Catalog/Binder/Parser errors are the query's fault; retrying on
  # a fresh connection would just fail again, so return them straight away.
  defp retryable?(%Error{message: msg}) do
    String.contains?(msg, [
      "Connection Error",
      "connection closed",
      "I/O Error",
      "IO Error",
      "Could not establish",
      "HTTP Error",
      "Network"
    ])
  end

  defp read_result(result, {json_columns, types}) do
    columns = Duckdbex.columns(result)
    json_idx = json_indexes(columns, json_columns)
    types = List.to_tuple(types)

    rows =
      result
      |> Duckdbex.fetch_all()
      |> Enum.map(&decode_row(&1, json_idx, types))

    %{columns: columns, rows: rows}
  end

  defp json_indexes(_columns, []), do: %{}

  defp json_indexes(columns, json_columns) do
    want = MapSet.new(json_columns)

    columns
    |> Enum.with_index()
    |> Enum.filter(fn {name, _i} -> MapSet.member?(want, name) end)
    |> Map.new(fn {_name, i} -> {i, true} end)
  end

  defp decode_row(row, json_idx, types) do
    row
    |> Enum.with_index()
    |> Enum.map(fn {value, i} ->
      cond do
        Map.has_key?(json_idx, i) -> decode_json(value)
        i < tuple_size(types) -> decode(elem(types, i), value)
        true -> value
      end
    end)
  end

  # Decode a value by its column's type, never by tuple shape: duckdbex returns DATE as
  # {y,m,d}, but also DECIMAL as {unscaled,width,scale} and INTERVAL as {months,days,micros}.
  # A compiled plan casts every output to a contract type, so DATE and TIMESTAMP are the only
  # tuples left; every other value is already JSON-ready.
  defp decode("DATE", {y, m, d}) do
    case Date.new(y, m, d) do
      {:ok, date} -> Date.to_iso8601(date)
      _ -> "#{y}-#{p2(m)}-#{p2(d)}"
    end
  end

  defp decode("TIMESTAMP", {{y, mo, d}, {h, mi, s, us}}) do
    case NaiveDateTime.new(y, mo, d, h, mi, s, {us, 6}) do
      {:ok, dt} -> NaiveDateTime.to_iso8601(dt)
      _ -> "#{y}-#{p2(mo)}-#{p2(d)}T#{p2(h)}:#{p2(mi)}:#{p2(s)}"
    end
  end

  defp decode(_type, value), do: value

  # A `to_json(col)` projection returns a JSON document as VARCHAR. Wrap it as a pre-encoded
  # fragment so the response carries it verbatim — never decoded to a term and re-encoded (the
  # response cache stores the term, so that re-encode would otherwise run on every serve).
  defp decode_json(nil), do: nil
  defp decode_json(value) when is_binary(value), do: Offloader.RawJSON.new(value)
  defp decode_json(value), do: value

  # ── checkout / checkin (atomics spinlock over ETS slots) ───────────────────────

  # `max_slots` bounds which slots this query may claim: `size` for local_table (the whole
  # pool), a smaller `remote_cap` for remote_scan. Slots [0, max_slots) are scanned; the
  # reserved tail [remote_cap, size) is therefore reachable only by local_table queries.
  defp checkout(%{table: table, locks: locks}, max_slots) do
    start = rem(:erlang.phash2(self()), max_slots)
    try_checkout(table, locks, max_slots, start, start, 0)
  end

  defp try_checkout(_table, _locks, _max_slots, _idx, _start, cycles)
       when cycles >= @max_checkout_cycles,
       do: :error

  defp try_checkout(table, locks, max_slots, idx, start, cycles) do
    case :atomics.compare_exchange(locks, idx + 1, 0, 1) do
      :ok ->
        [{_key, conn}] = :ets.lookup(table, {:conn, idx})
        {:ok, idx, conn}

      _busy ->
        next = rem(idx + 1, max_slots)

        if next == start do
          Process.sleep(1)
          try_checkout(table, locks, max_slots, next, start, cycles + 1)
        else
          try_checkout(table, locks, max_slots, next, start, cycles)
        end
    end
  end

  defp checkin(%{locks: locks}, idx), do: :atomics.put(locks, idx + 1, 0)

  defp reconnect(%{table: table, object_store: object_store}, idx) do
    [{:db, db}] = :ets.lookup(table, :db)

    case new_connection(db, object_store) do
      {:ok, conn} ->
        :ets.insert(table, {{:conn, idx}, conn})
        Logger.warning("Offloader engine: reconnected read pool slot #{idx}")
        {:ok, conn}

      {:error, reason} ->
        Logger.error("Offloader engine: pool slot #{idx} reconnect failed: #{inspect(reason)}")
        :error
    end
  end

  # ── setup ──────────────────────────────────────────────────────────────────────

  # The database handle lives in this engine-owned table, never in the persistent_term pool: an
  # engine killed through its link never runs terminate/2, and a handle left in persistent_term
  # would keep the database open (its threads and its file lock) for the life of the VM.
  defp build_pool(db, size, object_store) do
    table = :ets.new(:offloader_engine_pool, [:public, :set, read_concurrency: true])
    :ets.insert(table, {:db, db})
    locks = :atomics.new(size, [])

    Enum.reduce_while(0..(size - 1), :ok, fn i, :ok ->
      case new_connection(db, object_store) do
        {:ok, conn} ->
          :ets.insert(table, {{:conn, i}, conn})
          {:cont, :ok}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      :ok ->
        {:ok,
         %{
           table: table,
           locks: locks,
           size: size,
           remote_cap: remote_cap(size),
           object_store: object_store
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concurrent-remote_scan ceiling: the configured value clamped to the pool (can't reserve
  # more slots than exist), else the default. With the default pool (16) this equals the pool
  # — no reservation, unchanged behavior; it only bites once the pool is sized up past it.
  defp remote_cap(size),
    do: min(size, Offloader.Config.remote_scan_concurrency() || @default_remote_cap)

  defp new_connection(db, object_store) do
    with {:ok, conn} <- Duckdbex.connection(db),
         :ok <- enable_extensions(conn),
         :ok <- pin_utc(conn),
         :ok <- enable_remote_read_caches(conn),
         :ok <- Offloader.ObjectStore.configure(conn, object_store) do
      {:ok, conn}
    end
  end

  defp pool_size(opts) do
    opts[:pool_size] || Offloader.Config.pool_size() || @default_pool_size
  end

  defp enable_extensions(conn) do
    with {:ok, _} <- Duckdbex.query(conn, "SET autoinstall_known_extensions=true;"),
         {:ok, _} <- Duckdbex.query(conn, "SET autoload_known_extensions=true;") do
      :ok
    end
  end

  # DuckDB bundles ICU, whose TimeZone follows the host: a TIMESTAMPTZ cast to the contract's
  # TIMESTAMP, or compared with a date param, would shift with the machine. Pin UTC.
  defp pin_utc(conn) do
    with {:ok, _} <- Duckdbex.query(conn, "SET TimeZone = 'UTC';"), do: :ok
  end

  # Cache remote object-store metadata across queries so remote_scan endpoints don't
  # re-fetch file metadata and every Parquet footer from GCS/S3 on each request. DuckDB
  # keeps these off by default because a file can change under a cached URL — but Offloader
  # snapshots are IMMUTABLE: a new snapshot is new file URLs (commit protocol), so a cached
  # URL's bytes never change underneath us. The footer cache also re-reads a local file
  # whose mtime changed. (`enable_external_file_cache`, the data-block cache, is on by
  # default.) No-op cost for local_table deployments — there are no remote files to cache.
  defp enable_remote_read_caches(conn) do
    with {:ok, _} <- Duckdbex.query(conn, "SET enable_http_metadata_cache=true;"),
         {:ok, _} <- Duckdbex.query(conn, "SET parquet_metadata_cache=true;") do
      :ok
    end
  end

  # threads/memory_limit are DuckDB-global, so applying them once (on the writer) caps
  # the whole database — including pool connections. In a container, bound threads to
  # the cgroup CPU: DuckDB otherwise sees all host cores and oversubscribes under load.
  # DuckDB 2.0 also starts async I/O threads at four per host core (48 on 12 cores), and
  # `threads` doesn't change that, so the same cap sizes them at that ratio.
  defp apply_db_settings(conn) do
    with :ok <- set_threads(conn, Offloader.Config.duckdb_threads()) do
      set_memory_limit(conn, Offloader.Config.duckdb_memory_limit())
    end
  end

  defp set_threads(_conn, nil), do: :ok

  defp set_threads(conn, n) when is_integer(n) and n > 0 do
    with {:ok, _} <- Duckdbex.query(conn, "SET threads TO #{n};"),
         {:ok, _} <- Duckdbex.query(conn, "SET async_threads TO #{4 * n};") do
      :ok
    else
      {:error, msg} -> {:error, Error.new(:settings_failed, to_string(msg))}
    end
  end

  defp set_memory_limit(_conn, nil), do: :ok

  defp set_memory_limit(conn, limit) when is_binary(limit) do
    case Duckdbex.query(conn, "SET memory_limit = '#{Offloader.Sql.escape(limit)}';") do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, Error.new(:settings_failed, to_string(msg))}
    end
  end

  defp read_expr(%Manifest{files: files, dir: dir}), do: Offloader.Sql.read_files_expr(files, dir)

  defp parquet_columns(_conn, [], _dir), do: {:ok, []}

  defp parquet_columns(conn, files, dir) do
    by_path = Map.new(files, &{Offloader.Sql.resolve_path(&1["path"], dir), &1["path"]})
    list = Enum.map_join(Map.keys(by_path), ", ", &"'#{Offloader.Sql.escape(&1)}'")
    sql = "SELECT file_name, name, num_children FROM parquet_schema([#{list}])"

    with {:ok, result} <- run(conn, sql, [], :schema_failed) do
      columns =
        result
        |> Duckdbex.fetch_all()
        |> Enum.group_by(&hd/1, &tl/1)
        |> Enum.map(fn {path, [[_root, count] | nodes]} ->
          {Map.get(by_path, path, path), top_level(nodes, count || 0, [])}
        end)

      {:ok, columns}
    end
  end

  # parquet_schema lists each file's schema tree depth-first: the root's num_children is the
  # number of top-level columns, and every node is followed by its own subtree. Total on any
  # input: this runs in the writer, which must not crash on an odd footer.
  defp top_level(_nodes, 0, names), do: Enum.reverse(names)
  defp top_level([], _count, names), do: Enum.reverse(names)

  defp top_level([[name, children] | rest], count, names),
    do: rest |> skip_subtree(children || 0) |> top_level(count - 1, [name | names])

  defp skip_subtree(nodes, 0), do: nodes
  defp skip_subtree([], _count), do: []

  defp skip_subtree([[_name, children] | rest], count),
    do: rest |> skip_subtree(children || 0) |> skip_subtree(count - 1)

  defp csv_columns(conn, files, dir) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      path = Offloader.Sql.resolve_path(file["path"], dir)
      sql = "DESCRIBE SELECT * FROM read_csv_auto('#{Offloader.Sql.escape(path)}')"

      case run(conn, sql, [], :schema_failed) do
        {:ok, result} ->
          names = result |> Duckdbex.fetch_all() |> Enum.map(&hd/1)
          {:cont, {:ok, acc ++ [{file["path"], names}]}}

        {:error, %Error{}} = err ->
          {:halt, err}
      end
    end)
  end

  # Sort the materialized table on the dataset's filter columns so DuckDB's per-row-group min/max
  # zone maps prune scans for those filters. Empty list -> no ORDER BY (original behavior).
  defp order_by([]), do: ""
  defp order_by(columns), do: " ORDER BY " <> Enum.map_join(columns, ", ", &quote_ident/1)

  defp table_count(conn, quoted_ident) do
    case run(conn, "SELECT count(*) FROM #{quoted_ident}", [], :materialize_failed) do
      {:ok, result} ->
        [[n]] = Duckdbex.fetch_all(result)
        {:ok, n}

      {:error, _} = err ->
        err
    end
  end

  defp run(conn, sql, params, reason) do
    result =
      if params == [], do: Duckdbex.query(conn, sql), else: Duckdbex.query(conn, sql, params)

    case result do
      {:ok, query_result} -> {:ok, query_result}
      {:error, message} -> {:error, Error.new(reason, to_string(message))}
    end
  end

  defp quote_ident(name), do: Offloader.Sql.quote_ident(name)

  defp p2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
