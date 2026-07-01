defmodule OffloaderWeb.EndpointController do
  @moduledoc """
  The product API-port handler for named endpoints (`GET /v1/endpoints/:name`).
  Authentication and endpoint authorization already ran in
  `OffloaderWeb.Plugs.ApiAuth`, which assigned `:tenant` and `:request_id`; this
  action only compiles + serves. Every error is a named family; nothing here echoes
  a raw param, secret, or SQL.
  """

  use OffloaderWeb, :controller

  alias Offloader.{ApiError, Runtime}
  alias OffloaderWeb.Response

  def show(conn, %{"name" => name} = params) do
    request_id = conn.assigns.request_id
    request = Map.drop(params, ["name"])

    case Runtime.serve(name, conn.assigns.tenant, request, request_id) do
      {:ok, response} ->
        conn
        |> put_resp_header("x-request-id", request_id)
        |> json(response)

      {:error, %ApiError{} = error} ->
        Response.send_error(conn, error, request_id)
    end
  end
end
