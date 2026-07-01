defmodule Offloader.Catalog.Identifier do
  @moduledoc """
  Validates config-supplied identifiers (column names, param names, endpoint names,
  dataset ids). These are the *only* strings the endpoint compiler (G05) is ever
  allowed to place into SQL as identifiers, so the rule is strict and boring:
  lowercase letter, then letters/digits/underscores, max 63 chars (Postgres/DuckDB
  identifier limit). Anything else is rejected here, long before it reaches a query.
  """

  @pattern ~r/^[a-z][a-z0-9_]{0,62}$/

  @doc "True if `name` is a safe identifier."
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name), do: Regex.match?(@pattern, name)
  def valid?(_), do: false
end
