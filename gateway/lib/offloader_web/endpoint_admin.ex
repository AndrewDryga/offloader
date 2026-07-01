defmodule OffloaderWeb.AdminEndpoint do
  @moduledoc """
  The admin/metrics endpoint: health, readiness, status, and (via later tasks)
  Prometheus metrics, diagnostics, and generated docs/schema. Not an identity
  product — operators keep this port private with their own network, proxy, IAM,
  or firewall controls (see `docs/security-model.md`). Never serve product data
  or generated docs from the API port.
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
  plug OffloaderWeb.AdminRouter
end
