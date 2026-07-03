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
  snapshot into a local table, atomically swap the active pointer, execute a
  compiled parameterized query, and list a table's columns. Endpoint contracts do
  not know this exists (`docs/architecture.md` — "DuckDB is an implementation
  detail").

  ## Reads and writes are separated so reads scale

  One DuckDB *database* is shared. A single **writer** connection, owned by this
  GenServer, serializes the rare mutations (materialize / swap / drop) so a
  materialization can't be corrupted mid-swap. **Reads go through a pool** of
  dedicated connections and *bypass the GenServer entirely* — `execute/3` runs in
  the caller's process, so thousands of concurrent requests are limited by DuckDB's
  own parallelism, not by one mailbox. DuckDB's MVCC keeps the previous snapshot
  visible to in-flight readers until a `CREATE OR REPLACE` commits, so a swap never
  blocks or tears a concurrent read (verified: readers see a consistent snapshot
  across atomic swaps).

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

  @hugeint_base 18_446_744_073_709_551_616
  @default_pool_size 16
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

  @doc "Materialize a validated manifest into `table`. Returns {:ok, %{table, row_count}}."
  @spec materialize(GenServer.server(), String.t(), Manifest.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def materialize(server, table, %Manifest{} = manifest),
    do: writer_call(server, {:materialize, table, manifest}, @materialize_timeout)

  @doc "Atomically point `active` (a view) at `table`, so readers see the new snapshot at once."
  @spec swap(GenServer.server(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def swap(server, active, table),
    do: writer_call(server, {:swap, active, table}, @writer_timeout)

  @doc """
  Run a compiled SQL string with bound value params, on a pooled read connection in
  the CALLER's process (no GenServer round-trip). Returns {:ok, %{columns, rows}}.
  `json_columns` names output columns whose (VARCHAR) value is a JSON document to be
  decoded into a nested term.
  """
  @spec execute(GenServer.server(), String.t(), [term()], [String.t()]) ::
          {:ok, map()} | {:error, Error.t()}
  def execute(server, sql, params \\ [], json_columns \\ []) do
    case pool(server) do
      nil -> {:error, Error.new(:not_ready, "engine is not ready")}
      pool -> pooled_query(pool, sql, params, json_columns)
    end
  end

  @doc "List a materialized table's column names in order."
  @spec known_columns(GenServer.server(), String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def known_columns(server, table),
    do: writer_call(server, {:known_columns, table}, @writer_timeout)

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

  @doc "Pool statistics for diagnostics: %{connections, busy, saturated}."
  @spec pool_stats(GenServer.server()) :: map()
  def pool_stats(server) do
    case pool(server) do
      nil ->
        %{connections: 0, busy: 0, saturated: false}

      %{locks: locks, size: size} ->
        busy = Enum.count(1..size, fn i -> :atomics.get(locks, i) == 1 end)
        %{connections: size, busy: busy, saturated: busy >= size}
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

    with {:ok, db} <- Duckdbex.open(db_path),
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
  def handle_call({:materialize, table, manifest}, _from, state) do
    ident = quote_ident(table)
    sql = "CREATE OR REPLACE TABLE #{ident} AS #{read_expr(manifest)}"

    with {:ok, _} <- run(state.writer, sql, [], :materialize_failed),
         {:ok, count} <- table_count(state.writer, ident) do
      {:reply, {:ok, %{table: table, row_count: count}}, state}
    else
      {:error, %Error{}} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:swap, active, table}, _from, state) do
    sql = "CREATE OR REPLACE VIEW #{quote_ident(active)} AS SELECT * FROM #{quote_ident(table)}"

    case run(state.writer, sql, [], :swap_failed) do
      {:ok, _} -> {:reply, :ok, state}
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

  defp pooled_query(pool, sql, params, json_columns) do
    case checkout(pool) do
      {:ok, idx, conn} ->
        try do
          run_and_read(pool, idx, conn, sql, params, json_columns)
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
  defp run_and_read(pool, idx, conn, sql, params, json_columns) do
    case run(conn, sql, params, :query_failed) do
      {:ok, result} ->
        {:ok, read_result(result, json_columns)}

      {:error, %Error{} = err} = failure ->
        if retryable?(err),
          do: retry_on_fresh(pool, idx, sql, params, json_columns, failure),
          else: failure
    end
  end

  defp retry_on_fresh(pool, idx, sql, params, json_columns, failure) do
    case reconnect(pool, idx) do
      {:ok, fresh} ->
        case run(fresh, sql, params, :query_failed) do
          {:ok, result} -> {:ok, read_result(result, json_columns)}
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

  defp read_result(result, json_columns) do
    columns = Duckdbex.columns(result)
    json_idx = json_indexes(columns, json_columns)

    rows =
      result
      |> Duckdbex.fetch_all()
      |> Enum.map(&normalize_row(&1, json_idx))

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

  defp normalize_row(row, json_idx) do
    row
    |> Enum.with_index()
    |> Enum.map(fn {value, i} ->
      if Map.has_key?(json_idx, i), do: decode_json(value), else: normalize(value)
    end)
  end

  # A `to_json(col)` projection returns a JSON document as VARCHAR; decode it so the
  # response carries a nested object/array instead of a JSON string.
  defp decode_json(nil), do: nil

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp decode_json(value), do: value

  # ── checkout / checkin (atomics spinlock over ETS slots) ───────────────────────

  defp checkout(%{table: table, locks: locks, size: size}) do
    start = rem(:erlang.phash2(self()), size)
    try_checkout(table, locks, size, start, start, 0)
  end

  defp try_checkout(_table, _locks, _size, _idx, _start, cycles)
       when cycles >= @max_checkout_cycles,
       do: :error

  defp try_checkout(table, locks, size, idx, start, cycles) do
    case :atomics.compare_exchange(locks, idx + 1, 0, 1) do
      :ok ->
        [{_key, conn}] = :ets.lookup(table, {:conn, idx})
        {:ok, idx, conn}

      _busy ->
        next = rem(idx + 1, size)

        if next == start do
          Process.sleep(1)
          try_checkout(table, locks, size, next, start, cycles + 1)
        else
          try_checkout(table, locks, size, next, start, cycles)
        end
    end
  end

  defp checkin(%{locks: locks}, idx), do: :atomics.put(locks, idx + 1, 0)

  defp reconnect(%{table: table, db: db, object_store: object_store}, idx) do
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

  defp build_pool(db, size, object_store) do
    table = :ets.new(:offloader_engine_pool, [:public, :set, read_concurrency: true])
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
      :ok -> {:ok, %{table: table, locks: locks, size: size, db: db, object_store: object_store}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp new_connection(db, object_store) do
    with {:ok, conn} <- Duckdbex.connection(db),
         :ok <- enable_extensions(conn),
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

  # threads/memory_limit are DuckDB-global, so applying them once (on the writer) caps
  # the whole database — including pool connections. In a container, bound threads to
  # the cgroup CPU: DuckDB otherwise sees all host cores and oversubscribes under load.
  defp apply_db_settings(conn) do
    with :ok <- set_threads(conn, Offloader.Config.duckdb_threads()) do
      set_memory_limit(conn, Offloader.Config.duckdb_memory_limit())
    end
  end

  defp set_threads(_conn, nil), do: :ok

  defp set_threads(conn, n) when is_integer(n) and n > 0 do
    case Duckdbex.query(conn, "SET threads TO #{n};") do
      {:ok, _} -> :ok
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

  defp table_count(conn, quoted_ident) do
    case run(conn, "SELECT count(*) FROM #{quoted_ident}", [], :materialize_failed) do
      {:ok, result} ->
        [[n]] = Duckdbex.fetch_all(result)
        {:ok, normalize(n)}

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

  # Normalize duckdbex value encodings to JSON-friendly terms. duckdbex hands back
  # calendar tuples for the temporal types and a {hi,lo} pair for HUGEINT — none of
  # which Jason can encode, so an un-normalized value would crash the response.
  #   DATE                 -> {y,m,d}                 -> "YYYY-MM-DD"
  #   TIMESTAMP/TIMESTAMPTZ -> {{y,mo,d},{h,mi,s,us}} -> ISO-8601 datetime
  #   TIME                 -> {h,mi,s,us}             -> ISO-8601 time
  #   HUGEINT              -> {hi,lo}                 -> integer
  # Nested STRUCT/MAP/LIST columns are handled up-front via `to_json` (decode_json/1),
  # so they never reach this scalar path.
  defp normalize({{y, mo, d}, {h, mi, s, us}})
       when is_integer(y) and is_integer(h) and is_integer(us) do
    case NaiveDateTime.new(y, mo, d, h, mi, s, {us, 6}) do
      {:ok, dt} -> NaiveDateTime.to_iso8601(dt)
      _ -> "#{y}-#{p2(mo)}-#{p2(d)}T#{p2(h)}:#{p2(mi)}:#{p2(s)}"
    end
  end

  defp normalize({h, mi, s, us})
       when is_integer(h) and is_integer(mi) and is_integer(s) and is_integer(us) do
    case Time.new(h, mi, s, {us, 6}) do
      {:ok, t} -> Time.to_iso8601(t)
      _ -> "#{p2(h)}:#{p2(mi)}:#{p2(s)}"
    end
  end

  defp normalize({y, m, d}) when is_integer(y) and is_integer(m) and is_integer(d) do
    case Date.new(y, m, d) do
      {:ok, date} -> Date.to_iso8601(date)
      _ -> "#{y}-#{p2(m)}-#{p2(d)}"
    end
  end

  defp normalize({hi, lo}) when is_integer(hi) and is_integer(lo), do: hi * @hugeint_base + lo
  defp normalize(value), do: value

  defp p2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
