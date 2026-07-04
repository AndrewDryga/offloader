defmodule Offloader.Auth do
  @moduledoc """
  Consumer API-key authentication and authorization for the product port.

  Keys are matched by the SHA-256 hash of the bearer token — the plaintext token is
  never stored (`docs/security-model.md`). Matching is constant-time
  (`Plug.Crypto.secure_compare`) and scans every active key without short-circuiting,
  so response timing does not leak which key (if any) matched. Revoked keys never
  match. Authorization is a two-step check the caller cannot influence: the key must
  grant the endpoint, and the tenant is taken from the key — never from a request.

  This is the whole identity model for V1: no RBAC, SSO, users, or teams. Operators
  secure the admin port with their own controls (`docs/architecture.md`).
  """

  alias Offloader.ApiError
  alias Offloader.Catalog.Key

  @doc """
  Authenticate a bearer token against the configured keys. Returns the matching
  active `%Key{}` or `{:error, %ApiError{unauthorized}}`. Constant-time.
  """
  @spec authenticate([Key.t()], String.t()) :: {:ok, Key.t()} | {:error, ApiError.t()}
  def authenticate(keys, token) when is_binary(token) do
    hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

    # Fold over ALL keys (no early return) so timing is independent of match position.
    match =
      Enum.reduce(keys, nil, fn key, acc ->
        if key.status == "active" and secure_equal?(key.hash, hash), do: key, else: acc
      end)

    case match do
      nil -> {:error, ApiError.new(:unauthorized, "invalid or revoked API key")}
      key -> {:ok, key}
    end
  end

  def authenticate(_keys, _token),
    do: {:error, ApiError.new(:unauthorized, "invalid or revoked API key")}

  @doc """
  Authorize an authenticated key for an endpoint. Returns {:ok, tenant} or a stable
  `not_found` (never revealing whether the endpoint exists but is out of scope).
  """
  @spec authorize(Key.t(), String.t()) :: {:ok, String.t()} | {:error, ApiError.t()}
  def authorize(%Key{} = key, endpoint_name) do
    if Enum.member?(key.endpoints, endpoint_name),
      do: {:ok, key.tenant},
      else: {:error, ApiError.new(:not_found, "endpoint not found")}
  end

  # secure_compare requires equal-length inputs; both are 64-char sha256 hex here,
  # but guard anyway so a malformed config hash can't raise.
  defp secure_equal?(a, b) when byte_size(a) == byte_size(b), do: Plug.Crypto.secure_compare(a, b)
  defp secure_equal?(_a, _b), do: false
end
