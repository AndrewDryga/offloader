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
  alias OffloaderWeb.{CachePolicy, Response}

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

    Requests.record(name, conn.status || 500, start)
    conn
  end

  # Cache behaviour splits on auth mode. A PUBLIC (auth: none) response is immutable for its
  # `snapshot_id`, so it's safe to cache at a CDN/browser: emit an ETag + Cache-Control and
  # answer `If-None-Match` with a cheap 304. An AUTHED response is per-tenant, so it must never
  # sit in a shared cache: `private, no-store`. `CachePolicy` owns that decision (and the
  # reasoning behind its tenant guard) so the MCP surface advertises the same one.
  defp serve_ok(conn, response, name, request) do
    if CachePolicy.shared?(conn.assigns.tenant) do
      etag = etag_for(name, request, response)

      conn =
        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header(
          "cache-control",
          "public, max-age=#{CachePolicy.ttl_seconds(response)}, stale-while-revalidate=60"
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

  # Strong ETag over exactly what determines the bytes: endpoint (name AND contract version —
  # a hot reload can change the projection without a new snapshot), params, and the snapshot.
  defp etag_for(name, request, response) do
    sid = get_in(response, [:meta, :snapshot_id]) || ""
    version = get_in(response, [:meta, :version]) || 0
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({name, version, request, sid}))
    "\"" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 20)) <> "\""
  end

  # Parse the If-None-Match list properly: exact entries only (a weak `W/` prefix still
  # matches — bytes-equal is stronger than weak equality), never a substring scan.
  defp etag_matches?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 == "*" or &1 == etag or &1 == "W/" <> etag))
  end
end
