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

  # Sensitive diagnostics require the admin token; health/status/metrics stay open
  # for orchestrator probes and Prometheus scraping on the (private) admin port.
  pipeline :admin_authenticated do
    plug OffloaderWeb.Plugs.AdminAuth
  end

  scope "/", OffloaderWeb do
    pipe_through :admin

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
    get "/status", HealthController, :status

    # Generated product-API docs (no secrets; admin-port only, never the API port).
    get "/docs", DocsController, :catalog
    get "/schema", DocsController, :schema
    get "/openapi.json", DocsController, :openapi
  end

  # /metrics returns Prometheus text — no JSON accepts constraint, so any scraper works.
  scope "/", OffloaderWeb do
    get "/metrics", DiagnosticsController, :metrics
  end

  scope "/", OffloaderWeb do
    pipe_through [:admin, :admin_authenticated]

    get "/diagnostics", DiagnosticsController, :diagnostics
  end
end
