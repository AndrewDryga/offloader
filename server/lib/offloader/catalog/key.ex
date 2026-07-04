defmodule Offloader.Catalog.Key do
  @moduledoc """
  An API key entry as it appears in config: an id, the SHA-256 hash of the bearer
  token (never the token itself), the single tenant it is bound to, its endpoint
  allowlist, and status. This module validates the *shape*; the auth pipeline
  (hash lookup, constant-time compare, scope enforcement) is G06.
  """

  alias Offloader.Catalog.{Error, Identifier, Parse}

  @enforce_keys [:id, :hash, :tenant, :endpoints, :status]
  defstruct [:id, :hash, :tenant, :endpoints, :status]

  @statuses ~w(active revoked)
  @top_keys ~w(id hash tenant endpoints status)
  @hash_re ~r/^[a-f0-9]{64}$/

  @type t :: %__MODULE__{
          id: String.t(),
          hash: String.t(),
          tenant: String.t(),
          endpoints: [String.t()],
          status: String.t()
        }

  @doc "Parse/validate one key map. `known_endpoints` is used to reject dangling scopes."
  @spec parse(term(), String.t(), String.t(), MapSet.t()) :: {:ok, t()} | {:error, [Error.t()]}
  def parse(raw, file, path, known_endpoints) when is_map(raw) do
    errors =
      Parse.unknown_keys(raw, @top_keys, file, path) ++
        id_err(raw["id"], path, file) ++
        hash_err(raw["hash"], path, file) ++
        tenant_err(raw["tenant"], path, file) ++
        status_err(raw["status"], path, file) ++
        endpoints_err(raw["endpoints"], path, file, known_endpoints)

    if errors == [], do: {:ok, build(raw)}, else: {:error, errors}
  end

  def parse(_raw, file, path, _known),
    do: {:error, [Error.new(file, path, :invalid_type, "key must be a mapping")]}

  defp id_err(id, path, file) do
    if is_binary(id) and Identifier.valid?(id),
      do: [],
      else: [
        Error.new(
          file,
          Parse.join(path, "id"),
          :unsafe_identifier,
          "key id #{inspect(id)} is missing or not a safe identifier"
        )
      ]
  end

  defp hash_err(hash, path, file) do
    if is_binary(hash) and Regex.match?(@hash_re, hash),
      do: [],
      else: [
        Error.new(
          file,
          Parse.join(path, "hash"),
          :invalid_value,
          "hash must be a 64-char lowercase SHA-256 hex string",
          "store sha256(token), never the token"
        )
      ]
  end

  defp tenant_err(tenant, path, file) do
    if is_binary(tenant) and tenant != "",
      do: [],
      else: [
        Error.new(file, Parse.join(path, "tenant"), :missing, "key must be bound to a tenant")
      ]
  end

  defp status_err(status, path, file) do
    if status in @statuses,
      do: [],
      else: [
        Error.new(
          file,
          Parse.join(path, "status"),
          :invalid_value,
          "status #{inspect(status)} is invalid",
          "one of: #{Enum.join(@statuses, ", ")}"
        )
      ]
  end

  defp endpoints_err(endpoints, path, file, known) do
    case endpoints do
      list when is_list(list) and list != [] ->
        for ep <- list, not MapSet.member?(known, ep) do
          Error.new(
            file,
            Parse.join(path, "endpoints"),
            :unknown_endpoint,
            "key grants unknown endpoint #{inspect(ep)}"
          )
        end

      _ ->
        [
          Error.new(
            file,
            Parse.join(path, "endpoints"),
            :missing,
            "key must grant at least one endpoint"
          )
        ]
    end
  end

  defp build(raw) do
    %__MODULE__{
      id: raw["id"],
      hash: raw["hash"],
      tenant: raw["tenant"],
      endpoints: raw["endpoints"],
      status: raw["status"]
    }
  end
end
