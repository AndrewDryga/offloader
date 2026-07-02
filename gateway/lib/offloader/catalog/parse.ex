defmodule Offloader.Catalog.Parse do
  @moduledoc """
  Small helpers shared by the catalog parsers: strict unknown-field detection and
  field-path building. Parsers collect ALL errors (not fail-fast) so an operator
  sees every problem in one pass.
  """

  alias Offloader.Catalog.Error

  @doc "Errors for any key in `map` that is not in `allowed` — catches typos and misconfig."
  @spec unknown_keys(term(), [String.t()], String.t(), String.t()) :: [Error.t()]
  def unknown_keys(map, allowed, file, path) when is_map(map) do
    for {k, _v} <- map, not Enum.member?(allowed, k) do
      Error.new(
        file,
        join(path, k),
        :unknown_field,
        "unknown field #{inspect(k)}",
        "allowed: #{Enum.join(allowed, ", ")}"
      )
    end
  end

  def unknown_keys(_not_a_map, _allowed, _file, _path), do: []

  @doc "Extend a dotted field path with a child key."
  @spec join(String.t(), term()) :: String.t()
  def join("", key), do: to_string(key)
  def join(path, key), do: "#{path}.#{key}"

  @doc "Extend a field path with a list index."
  @spec index(String.t(), non_neg_integer()) :: String.t()
  def index(path, i), do: "#{path}[#{i}]"

  @doc "Duplicate values in `list`, in first-seen order."
  @spec duplicates([term()]) :: [term()]
  def duplicates(list) do
    list
    |> Enum.frequencies()
    |> Enum.filter(fn {_v, n} -> n > 1 end)
    |> Enum.map(&elem(&1, 0))
  end
end
