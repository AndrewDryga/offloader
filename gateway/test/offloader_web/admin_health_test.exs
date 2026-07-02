defmodule OffloaderWeb.AdminHealthTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest

  @endpoint OffloaderWeb.AdminEndpoint

  test "GET /live returns 200 ok" do
    assert json_response(get(build_conn(), "/live"), 200)["status"] == "ok"
  end

  test "GET /ready is 503 not-ready when no runtime/snapshots are loaded" do
    # With no Offloader.Runtime running (this test boots none), readiness is honest:
    # the instance cannot serve, so /ready fails closed. The ready path is covered by
    # the diagnostics HTTP test, which boots a runtime.
    conn = get(build_conn(), "/ready")
    assert conn.status == 503
    assert json_response(conn, 503)["ready"] == false
  end

  test "GET /status reports service identity and build version" do
    body = json_response(get(build_conn(), "/status"), 200)
    assert body["service"] == "offloader"
    assert is_binary(body["version"])
  end

  test "the public API liveness route is NOT reachable on the admin port" do
    conn = get(build_conn(), "/healthz")
    assert conn.status == 404
  end
end
