defmodule Offloader.Engine do
  @moduledoc """
  The DuckDB materialization + query boundary. Narrow on purpose: load a validated
  snapshot into a local table, atomically swap the active pointer, execute a
  compiled parameterized query, and list a table's columns. Endpoint contracts do
  not know this exists (`docs/architecture.md` — "DuckDB is an implementation
  detail").

  A single GenServer owns the DuckDB database + connection and serializes access,
  so concurrent callers can't corrupt a materialization mid-swap. The database is a
  persistent file under `OFFLOADER_CACHE_DIR`, so materialized snapshots survive a
  restart (warm cache).

  Safety: only *values* are ever sent as query parameters (`$1`, `$2`, …). Table
  names and file paths come from validated config/manifests, never from a consumer;
  identifiers are quoted and paths are single-quote-escaped as defense in depth.

  Aggregates (`sum`, `avg`, …) live in DuckDB's `core_functions` extension; the
  connection enables autoinstall+autoload, so the first run may fetch it (then it is
  cached under `~/.duckdb`). Offline runs need that cache present.
  """

  use GenServer

  alias Offloader.Engine.Error
  alias Offloader.Manifest

  @hugeint_base 18_446_744_073_709_551_616

  defstruct [:db, :conn, :cache_dir]

  # ── public API ────────────────────────────────────────────────────────────────

  @doc "Start the engine. Opts: :cache_dir (required), :name (optional)."
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Materialize a validated manifest into `table`. Returns {:ok, %{table, row_count}}."
  @spec materialize(GenServer.server(), String.t(), Manifest.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def materialize(server, table, %Manifest{} = manifest),
    do: GenServer.call(server, {:materialize, table, manifest}, 60_000)

  @doc "Atomically point `active` (a view) at `table`, so readers see the new snapshot at once."
  @spec swap(GenServer.server(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def swap(server, active, table), do: GenServer.call(server, {:swap, active, table})

  @doc "Run a compiled SQL string with bound value params. Returns {:ok, %{columns, rows}}."
  @spec execute(GenServer.server(), String.t(), [term()]) :: {:ok, map()} | {:error, Error.t()}
  def execute(server, sql, params \\ []), do: GenServer.call(server, {:execute, sql, params})

  @doc "List a materialized table's column names in order."
  @spec known_columns(GenServer.server(), String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def known_columns(server, table), do: GenServer.call(server, {:known_columns, table})

  @doc "Drop a snapshot table (cleanup after a swap or in tests)."
  @spec drop(GenServer.server(), String.t()) :: :ok | {:error, Error.t()}
  def drop(server, table), do: GenServer.call(server, {:drop, table})

  def stop(server), do: GenServer.stop(server)

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    cache_dir = Keyword.fetch!(opts, :cache_dir)
    File.mkdir_p!(cache_dir)
    db_path = Path.join(cache_dir, "offloader.duckdb")

    with {:ok, db} <- Duckdbex.open(db_path),
         {:ok, conn} <- Duckdbex.connection(db),
         :ok <- enable_aggregates(conn) do
      {:ok, %__MODULE__{db: db, conn: conn, cache_dir: cache_dir}}
    else
      {:error, reason} -> {:stop, {:engine_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:materialize, table, manifest}, _from, state) do
    ident = quote_ident(table)
    sql = "CREATE OR REPLACE TABLE #{ident} AS #{read_expr(manifest)}"

    with {:ok, _} <- run(state.conn, sql, [], :materialize_failed),
         {:ok, count} <- table_count(state.conn, ident) do
      {:reply, {:ok, %{table: table, row_count: count}}, state}
    else
      {:error, %Error{}} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:swap, active, table}, _from, state) do
    sql = "CREATE OR REPLACE VIEW #{quote_ident(active)} AS SELECT * FROM #{quote_ident(table)}"

    case run(state.conn, sql, [], :swap_failed) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, %Error{}} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:execute, sql, params}, _from, state) do
    case run(state.conn, sql, params, :query_failed) do
      {:ok, result} ->
        columns = Duckdbex.columns(result)
        rows = result |> Duckdbex.fetch_all() |> Enum.map(&Enum.map(&1, fn v -> normalize(v) end))
        {:reply, {:ok, %{columns: columns, rows: rows}}, state}

      {:error, %Error{}} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:known_columns, table}, _from, state) do
    case run(state.conn, "SELECT * FROM #{quote_ident(table)} LIMIT 0", [], :unknown_table) do
      {:ok, result} -> {:reply, {:ok, Duckdbex.columns(result)}, state}
      {:error, %Error{}} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:drop, table}, _from, state) do
    case run(state.conn, "DROP TABLE IF EXISTS #{quote_ident(table)}", [], :drop_failed) do
      {:ok, _} -> {:reply, :ok, state}
      {:error, %Error{}} = err -> {:reply, err, state}
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────────

  defp enable_aggregates(conn) do
    with {:ok, _} <- Duckdbex.query(conn, "SET autoinstall_known_extensions=true;"),
         {:ok, _} <- Duckdbex.query(conn, "SET autoload_known_extensions=true;") do
      :ok
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

  # Normalize duckdbex value encodings to JSON-friendly terms.
  # DATE -> {y,m,d} -> "YYYY-MM-DD"; HUGEINT -> {hi,lo} -> integer; else passthrough.
  defp normalize({y, m, d}) when is_integer(y) and is_integer(m) and is_integer(d) do
    case Date.new(y, m, d) do
      {:ok, date} -> Date.to_iso8601(date)
      _ -> {y, m, d}
    end
  end

  defp normalize({hi, lo}) when is_integer(hi) and is_integer(lo), do: hi * @hugeint_base + lo
  defp normalize(value), do: value
end

defmodule Offloader.Engine.Error do
  @moduledoc "A wrapped engine error with a stable reason atom and the underlying message."
  @enforce_keys [:reason, :message]
  defstruct [:reason, :message]

  @type t :: %__MODULE__{reason: atom(), message: String.t()}

  def new(reason, message), do: %__MODULE__{reason: reason, message: message}
end
