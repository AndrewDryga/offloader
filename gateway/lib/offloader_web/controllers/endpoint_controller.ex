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
          |> serve_ok(response, name, request)

        {:error, %ApiError{} = error} ->
          Response.send_error(conn, error, request_id)
      end

    record(name, conn.status, start)
    conn
  end

  # Cache behaviour splits on auth mode. A PUBLIC (auth: none) response is immutable for its
  # `snapshot_id`, so it's safe to cache at a CDN/browser: emit an ETag + Cache-Control and
  # answer `If-None-Match` with a cheap 304. An AUTHED response is per-tenant, so it must never
  # sit in a shared cache: `private, no-store`.
  defp serve_ok(conn, response, name, request) do
    if Runtime.public?() do
      etag = etag_for(name, request, response)

      conn =
        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header(
          "cache-control",
          "public, max-age=#{cache_ttl(response)}, stale-while-revalidate=60"
        )

      if etag_matches?(conn, etag) do
        send_resp(conn, 304, "")
      else
        json(conn, response)
      end
    else
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> json(response)
    end
  end

  # Strong ETag over exactly what determines the bytes: endpoint, params, and the snapshot.
  defp etag_for(name, request, response) do
    sid = get_in(response, [:meta, :snapshot_id]) || ""
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({name, request, sid}))
    "\"" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 20)) <> "\""
  end

  defp etag_matches?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [inm | _] -> inm == "*" or String.contains?(inm, etag)
      _ -> false
    end
  end

  # A safe max-age from the endpoint's freshness window (capped); ETag revalidation covers the rest.
  defp cache_ttl(response) do
    case get_in(response, [:meta, :freshness, :max_staleness_minutes]) do
      m when is_integer(m) and m > 0 -> min(m * 60, 3600)
      _ -> 60
    end
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
