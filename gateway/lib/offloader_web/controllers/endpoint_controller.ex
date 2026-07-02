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
  alias Offloader.Metrics.Requests
  alias OffloaderWeb.Response

  def show(conn, %{"name" => name} = params) do
    request_id = conn.assigns.request_id
    request = Map.drop(params, ["name"])
    start = System.monotonic_time()

    conn =
      case Runtime.serve(name, conn.assigns.tenant, request, request_id) do
        {:ok, response} ->
          conn
          |> put_resp_header("x-request-id", request_id)
          |> json(response)

        {:error, %ApiError{} = error} ->
          Response.send_error(conn, error, request_id)
      end

    record(name, conn.status, start)
    conn
  end

  # Emit a bounded-cardinality request metric: endpoint name + status CLASS + latency.
  defp record(name, status, start) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond) / 1000

    :telemetry.execute(
      [:offloader, :request, :stop],
      %{duration_ms: duration_ms},
      %{endpoint: name, status: Requests.status_class(status || 500)}
    )
  end
end
