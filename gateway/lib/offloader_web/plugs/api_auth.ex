defmodule OffloaderWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates a consumer bearer token and authorizes it for the requested
  endpoint, then assigns `:tenant` and `:request_id`. Runs in the API pipeline so
  every `/v1` route is protected by default — a new route is auth-gated the moment
  it is added, not when someone remembers to check. On failure it renders a stable
  error and halts, so the controller only ever runs for an authorized caller.
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

    with {:ok, token} <- bearer(conn),
         :ok <- runtime_up(),
         {:ok, tenant} <- Runtime.authorize(token, name) do
      conn
      |> assign(:tenant, tenant)
      |> assign(:request_id, request_id)
    else
      {:error, %ApiError{} = error} ->
        conn |> Response.send_error(error, request_id) |> halt()
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, ApiError.new(:unauthorized, "missing or malformed bearer token")}
    end
  end

  defp runtime_up do
    if is_pid(Process.whereis(Runtime)),
      do: :ok,
      else: {:error, ApiError.new(:not_ready, "service is starting")}
  end
end
