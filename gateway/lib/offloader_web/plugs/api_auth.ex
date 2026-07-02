defmodule OffloaderWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates a consumer bearer token and authorizes it for the requested
  endpoint, then assigns `:tenant` and `:request_id`. Runs in the API pipeline so
  every `/v1` route is protected by default — a new route is auth-gated the moment
  it is added, not when someone remembers to check. On failure it renders a stable
  error and halts, so the controller only ever runs for an authorized caller.

  When the project is configured `auth: none`, the API is public: no bearer is
  required and the request runs with no tenant (`nil`). This is only reachable for a
  catalog whose endpoints are all non-tenant — enforced at config load — so it can
  never expose tenant-scoped data unauthenticated.
  """

  @behaviour Plug

  import Plug.Conn
  alias Offloader.{ApiError, Runtime}
  alias OffloaderWeb.Response

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    request_id = Response.request_id(conn)
    name = conn.path_params["name"]

    case resolve_tenant(conn, name) do
      {:ok, tenant} ->
        conn
        |> assign(:tenant, tenant)
        |> assign(:request_id, request_id)

      {:error, %ApiError{} = error} ->
        conn |> Response.send_error(error, request_id) |> halt()
    end
  end

  defp resolve_tenant(conn, name) do
    cond do
      not runtime_up() ->
        {:error, ApiError.new(:not_ready, "service is starting")}

      Runtime.public?() ->
        {:ok, nil}

      true ->
        with {:ok, token} <- bearer(conn), do: Runtime.authorize(token, name)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, ApiError.new(:unauthorized, "missing or malformed bearer token")}
    end
  end

  defp runtime_up, do: is_pid(Process.whereis(Runtime))
end
