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
  A `SELECT * FROM read_...('f')` expression over a manifest's files (each path
  resolved from `dir`), joined `UNION ALL BY NAME`. Used both to materialize a table
  and to scan the source directly (remote_scan).
  """
  @spec read_files_expr([map()], String.t()) :: String.t()
  def read_files_expr(files, dir) do
    files
    |> Enum.map_join(" UNION ALL BY NAME ", fn f ->
      path = Path.expand(f["path"], dir)
      "SELECT * FROM #{reader(f["format"])}('#{escape(path)}')"
    end)
  end

  defp reader("parquet"), do: "read_parquet"
  defp reader(_), do: "read_csv_auto"
end
