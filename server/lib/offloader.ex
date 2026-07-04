defmodule Offloader do
  @moduledoc """
  Offloader server: the customer-run data plane.

  Serves bounded production analytics endpoints over a governed REST contract,
  backed by approved object-storage snapshots materialized into DuckDB. This
  module holds only process-wide helpers; the runtime is two Phoenix endpoints
  (`OffloaderWeb.ApiEndpoint` for product traffic, `OffloaderWeb.AdminEndpoint`
  for health/metrics/diagnostics/docs) supervised by `Offloader.Application`.
  """

  @doc "The running build version, read from the OTP application spec (release-safe)."
  @spec version() :: String.t()
  def version do
    case :application.get_key(:offloader, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "unknown"
    end
  end
end
