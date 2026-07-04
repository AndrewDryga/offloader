defmodule Offloader.Catalog.Identifier do
  @moduledoc """
  Validates config-supplied identifiers. These are the *only* strings the endpoint
  compiler (G05) is ever allowed to place into SQL as identifiers, so the rules are
  strict and boring — but there are two, because there are two kinds of name:

    * `valid?/1` — names WE mint (dataset ids, endpoint names, param names): they
      surface in URLs and file names, so lowercase letter, then lowercase
      letters/digits/underscores.
    * `valid_column?/1` — COLUMN names, which are shaped by the producer's data:
      real-world parquet uses camelCase (`situationalItems`) and digit-leading
      (`5_cost_offset`) names. Letters/digits/underscores only (no quotes, spaces,
      dots, or dashes), so they are still safe to quote into SQL.

  Both cap at 63 chars (the Postgres/DuckDB identifier limit). Anything else is
  rejected here, long before it reaches a query.
  """

  @name_pattern ~r/^[a-z][a-z0-9_]{0,62}$/
  @column_pattern ~r/^[A-Za-z0-9_]{1,63}$/

  @doc "True if `name` is a safe Offloader-minted identifier (dataset/endpoint/param)."
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name), do: Regex.match?(@name_pattern, name)
  def valid?(_), do: false

  @doc "True if `name` is a safe column name (producer-shaped; still quotable-safe)."
  @spec valid_column?(term()) :: boolean()
  def valid_column?(name) when is_binary(name), do: Regex.match?(@column_pattern, name)
  def valid_column?(_), do: false
end
