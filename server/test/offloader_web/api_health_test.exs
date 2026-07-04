defmodule OffloaderWeb.ApiHealthTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest

  @endpoint OffloaderWeb.ApiEndpoint

  test "GET /healthz returns 200 ok" do
    conn = get(build_conn(), "/healthz")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "admin-only routes are NOT reachable on the API port" do
    # Port separation guardrail (hardened further in I03): operator surfaces must
    # never answer on the product port — an unknown route 404s here.
    for path <- ["/live", "/ready", "/status", "/metrics", "/diagnostics"] do
      conn = get(build_conn(), path)
      assert conn.status == 404, "#{path} must 404 on the API port, got #{conn.status}"
    end
  end
end
