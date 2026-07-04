defmodule OffloaderWeb.ApiEndpoint do
  @moduledoc """
  The product (API) endpoint: customer-facing analytics traffic, behind consumer
  API keys, endpoint allowlists, and tenant enforcement (`Plugs.ApiAuth`). This is
  the only port that should be exposed to product callers; operator surfaces live
  on `OffloaderWeb.AdminEndpoint`.
  """

  use Phoenix.Endpoint, otp_app: :offloader

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    # A GET-only API has no business parsing large bodies; don't be a memory amplifier.
    length: 1_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug :nosniff
  # CORS before the router so a preflight OPTIONS is answered without hitting auth.
  plug OffloaderWeb.Plugs.Cors
  plug OffloaderWeb.ApiRouter

  defp nosniff(conn, _opts),
    do: Plug.Conn.put_resp_header(conn, "x-content-type-options", "nosniff")
end
