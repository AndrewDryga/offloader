defmodule OffloaderWeb.EndpointController do
  @moduledoc """
  The product API-port handler for named endpoints (`GET /v1/endpoints/:name`).
  It authenticates the bearer token, delegates to `Offloader.Runtime`, and renders
  stable JSON. Every error is a named family; nothing here echoes a raw param,
  secret, or SQL. If the runtime is not started (no config yet), it answers
  `not_ready` instead of crashing.
  """

  use OffloaderWeb, :controller

  alias Offloader.{ApiError, Runtime}

  def show(conn, %{"name" => name} = params) do
    request_id = request_id(conn)
    request = Map.drop(params, ["name"])

    with {:ok, token} <- bearer(conn),
         :ok <- runtime_up(),
         {:ok, tenant} <- Runtime.authorize(token, name),
         {:ok, response} <- Runtime.serve(name, tenant, request, request_id) do
      conn
      |> put_resp_header("x-request-id", request_id)
      |> json(response)
    else
      {:error, %ApiError{} = error} -> send_error(conn, error, request_id)
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

  defp send_error(conn, %ApiError{} = error, request_id) do
    conn
    |> put_resp_header("x-request-id", request_id)
    |> put_status(ApiError.status(error))
    |> json(%{
      error: %{family: error.family, message: error.message},
      meta: %{request_id: request_id}
    })
  end

  # Reuse the endpoint's Plug.RequestId value; generate one only if it is absent.
  defp request_id(conn) do
    case get_resp_header(conn, "x-request-id") do
      [id | _] when is_binary(id) and id != "" -> id
      _ -> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    end
  end
end
