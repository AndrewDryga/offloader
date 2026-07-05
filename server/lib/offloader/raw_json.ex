defmodule Offloader.RawJSON do
  @moduledoc """
  A pre-encoded JSON document — the result of a DuckDB `to_json(col)` projection, which is already
  valid JSON. Wrapping it lets the response encoder splice it in **verbatim** instead of decoding it
  to an Elixir term and re-encoding it. Nested columns dominate serialization cost, and the response
  cache stores the response *term* (re-encoded on every serve, hit or miss), so passing the fragment
  through raw saves that work on every request.
  """
  @enforce_keys [:json]
  defstruct [:json]

  @type t :: %__MODULE__{json: binary()}

  @spec new(binary()) :: t()
  def new(json) when is_binary(json), do: %__MODULE__{json: json}
end

defimpl JSON.Encoder, for: Offloader.RawJSON do
  # The wrapped binary is already a valid JSON document — emit it verbatim, no re-encoding.
  def encode(%Offloader.RawJSON{json: json}, _encoder), do: json
end
