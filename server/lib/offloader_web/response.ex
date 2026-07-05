defmodule OffloaderWeb.Response do
  @moduledoc """
  Shared JSON rendering for the API port, so the auth plug and the controller emit
  identical, stable envelopes. Error bodies carry only the named family and a safe
  message — never a raw param, secret, or SQL.
  """

  import Plug.Conn
  alias Offloader.ApiError

  @doc "The request id (set by Plug.RequestId), or a fresh one if absent."
  @spec request_id(Plug.Conn.t()) :: String.t()
  def request_id(conn) do
    case get_resp_header(conn, "x-request-id") do
      [id | _] when is_binary(id) and id != "" -> id
      _ -> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    end
  end

  @doc "Send a stable JSON error with the family's HTTP status."
  @spec send_error(Plug.Conn.t(), ApiError.t(), String.t()) :: Plug.Conn.t()
  def send_error(conn, %ApiError{} = error, request_id) do
    body = %{
      error: %{family: error.family, message: error.message},
      meta: %{request_id: request_id}
    }

    conn
    |> put_resp_header("x-request-id", request_id)
    |> put_resp_content_type("application/json")
    |> send_resp(ApiError.status(error), JSON.encode!(body))
  end
end
