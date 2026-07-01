defmodule OffloaderWeb.AdminRouter do
  @moduledoc """
  Routes for the admin/metrics port: health, readiness, and status today; metrics,
  diagnostics, and generated docs/schema are added by G07/G09. These must never be
  reachable from the API port.
  """

  use OffloaderWeb, :router

  pipeline :admin do
    plug :accepts, ["json"]
  end

  scope "/", OffloaderWeb do
    pipe_through :admin

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
    get "/status", HealthController, :status
  end
end
