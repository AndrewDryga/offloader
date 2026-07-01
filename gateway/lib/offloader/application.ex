defmodule Offloader.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Offloader.Telemetry,
      # Product traffic (endpoint API keys, tenant enforcement — added by later tasks).
      OffloaderWeb.ApiEndpoint,
      # Operator surface (health/metrics/diagnostics/docs). Keep it off the API port.
      OffloaderWeb.AdminEndpoint
    ]

    opts = [strategy: :one_for_one, name: Offloader.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Phoenix calls this on a hot config change so each endpoint re-reads its config.
  @impl true
  def config_change(changed, _new, removed) do
    OffloaderWeb.ApiEndpoint.config_change(changed, removed)
    OffloaderWeb.AdminEndpoint.config_change(changed, removed)
    :ok
  end
end
