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

  scope "/", OffloaderWeb do
    pipe_through :api

    # Explicitly public: an unauthenticated liveness probe for load balancers.
    get "/healthz", HealthController, :healthz
  end

  scope "/v1", OffloaderWeb do
    pipe_through :api

    # Named product endpoints. Auth + tenant enforcement live in the controller/runtime.
    get "/endpoints/:name", EndpointController, :show
  end
end
