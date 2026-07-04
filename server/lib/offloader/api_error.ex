defmodule Offloader.ApiError do
  @moduledoc """
  A named error family for the API surface. Families are stable and deliberately
  coarse so an error never reveals whether a forbidden endpoint/dataset exists
  (`docs/security-model.md`): an unknown endpoint and an endpoint you may not use
  both render as `not_found`. The `message` is safe to return to the caller — it
  must never echo a raw param value, secret, or internal identifier.
  """

  @enforce_keys [:family, :message]
  defstruct [:family, :message]

  @type family :: :invalid_param | :unauthorized | :not_found | :not_ready | :internal
  @type t :: %__MODULE__{family: family(), message: String.t()}

  @statuses %{
    invalid_param: 422,
    unauthorized: 401,
    not_found: 404,
    not_ready: 503,
    internal: 500
  }

  @spec new(family(), String.t()) :: t()
  def new(family, message) when is_map_key(@statuses, family),
    do: %__MODULE__{family: family, message: message}

  @doc "HTTP status for a family."
  @spec status(t() | family()) :: pos_integer()
  def status(%__MODULE__{family: family}), do: @statuses[family]
  def status(family) when is_atom(family), do: @statuses[family]
end
