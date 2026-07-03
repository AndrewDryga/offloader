defmodule OffloaderWeb.ApiEndpoint do
  @moduledoc """
  The product (API) endpoint: customer-facing analytics traffic. Consumer API
  keys, endpoint allowlists, and tenant enforcement are added by G05/G06. This is
  the only port that should be exposed to product callers; operator surfaces live
  on `OffloaderWeb.AdminEndpoint`.
  """

  use Phoenix.Endpoint, otp_app: :offloader

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  # CORS before the router so a preflight OPTIONS is answered without hitting auth.
  plug OffloaderWeb.Plugs.Cors
  plug OffloaderWeb.ApiRouter
end
