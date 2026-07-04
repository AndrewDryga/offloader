defmodule OffloaderWeb.ApiRouter do
  @moduledoc """
  Routes for the product (API) port. Product endpoints are added by G05; the only
  route here today is a public liveness check for load balancers. Auth for every
  non-public route is enforced by G06.
  """

  use OffloaderWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Consumer traffic: authenticate + authorize before any controller runs.
  pipeline :authenticated do
    plug OffloaderWeb.Plugs.ApiAuth
  end

  scope "/", OffloaderWeb do
    pipe_through :api

    # Explicitly public: an unauthenticated liveness probe for load balancers.
    get "/healthz", HealthController, :healthz
  end

  scope "/v1", OffloaderWeb do
    pipe_through [:api, :authenticated]

    # Named product endpoints. Auth/tenant enforcement is guaranteed by the pipeline.
    get "/endpoints/:name", EndpointController, :show
  end
end
