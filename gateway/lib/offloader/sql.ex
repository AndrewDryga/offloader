defmodule Offloader.Sql do
  @moduledoc """
  Shared SQL-fragment builders used by the engine (materialization) and the compiler
  (remote-scan FROM clauses). Every input here comes from validated config or a
  validated manifest — never a consumer — but identifiers are still quoted and paths
  single-quote-escaped as defense in depth.
  """

  @doc ~S(Quote a DuckDB identifier: `"name"`, doubling any embedded quote.)
  @spec quote_ident(String.t()) :: String.t()
  def quote_ident(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")

  @doc "Escape a value for a single-quoted SQL string literal."
  @spec escape(String.t()) :: String.t()
  def escape(str), do: String.replace(str, "'", "''")

  @doc """
  A `SELECT * FROM read_...('f')` expression over a manifest's files, joined
  `UNION ALL BY NAME`. Used both to materialize a table and to scan the source
  directly (remote_scan). A local path is resolved from `dir`; a remote URL
  (`s3://`, `gs://`, `https://`, …) is passed through verbatim so DuckDB's httpfs
  reads it directly (credentials come from `Offloader.ObjectStore`).
  """
  @spec read_files_expr([map()], String.t()) :: String.t()
  def read_files_expr(files, dir) do
    files
    |> Enum.map_join(" UNION ALL BY NAME ", fn f ->
      path = resolve_path(f["path"], dir)
      "SELECT * FROM #{reader(f["format"])}('#{escape(path)}')"
    end)
  end

  @doc "Resolve a manifest file path: remote URLs pass through, local paths expand from `dir`."
  @spec resolve_path(String.t(), String.t()) :: String.t()
  def resolve_path(path, dir) do
    if Offloader.ObjectStore.remote_path?(path), do: path, else: Path.expand(path, dir)
  end

  defp reader("parquet"), do: "read_parquet"
  defp reader(_), do: "read_csv_auto"
end
