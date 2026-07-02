defmodule OffloaderWeb.DiagnosticsHTTPTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Offloader.Runtime

  @endpoint OffloaderWeb.AdminEndpoint
  @project Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)
  @admin_token "admin-secret-token"

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_diag_#{System.unique_integer([:positive])}")
    {:ok, rt} = Runtime.start_link(name: Runtime, config_path: @project, cache_dir: dir)

    prev = Application.get_env(:offloader, :admin_token)
    Application.put_env(:offloader, :admin_token, @admin_token)

    on_exit(fn ->
      if Process.alive?(rt), do: GenServer.stop(rt)
      Application.put_env(:offloader, :admin_token, prev)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp get_admin(path, token \\ nil) do
    conn = build_conn()
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    get(conn, path)
  end

  test "/ready is 200 ready once the runtime has an active snapshot" do
    assert json_response(get_admin("/ready"), 200)["ready"] == true
  end

  test "/status reports identity, version, and readiness" do
    body = json_response(get_admin("/status"), 200)
    assert body["service"] == "offloader"
    assert body["ready"] == true
  end

  test "/diagnostics requires the admin token" do
    assert json_response(get_admin("/diagnostics"), 401)["error"]["family"] == "unauthorized"
    assert json_response(get_admin("/diagnostics", "wrong"), 401)
  end

  test "/diagnostics with the admin token returns the full operator view" do
    body = json_response(get_admin("/diagnostics", @admin_token), 200)
    assert body["build_version"]
    assert body["duckdb_status"] == "ok"
    assert body["config_version"] == 1
    assert is_integer(get_in(body, ["disk", "cache_dir_free_bytes"]))

    [ds | _] = body["datasets"]
    assert ds["dataset"] == "customer_usage"
    assert ds["active_snapshot"]["snapshot_id"] == "2026-06-01T00:00:00Z_r0007"
    assert ds["last_attempted"]["status"] == "ok"
    assert ds["source_reachable"] == true
  end

  test "/diagnostics fails closed (503) when no admin token is configured" do
    Application.put_env(:offloader, :admin_token, nil)
    assert json_response(get_admin("/diagnostics", @admin_token), 503)
  end

  test "/metrics returns Prometheus text with the operator gauges" do
    conn = get_admin("/metrics")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    body = conn.resp_body
    assert body =~ "offloader_up 1"
    assert body =~ "offloader_ready 1"
    assert body =~ ~s(offloader_snapshot_age_seconds{dataset="customer_usage"})
    assert body =~ ~s(offloader_refresh_ok{dataset="customer_usage"} 1)
    # the DuckDB read-pool gauges
    assert body =~ "offloader_pool_connections "
    assert body =~ "offloader_pool_busy "
  end

  test "/metrics includes per-endpoint request counters + latency histogram" do
    Offloader.Metrics.Requests.reset()

    :telemetry.execute([:offloader, :request, :stop], %{duration_ms: 8}, %{
      endpoint: "customer_usage_summary",
      status: :ok
    })

    body = get_admin("/metrics").resp_body
    assert body =~ ~s(offloader_requests_total{endpoint="customer_usage_summary",status="ok"} 1)
    assert body =~ ~s(offloader_request_duration_ms_count{endpoint="customer_usage_summary"} 1)
  end

  test "diagnostics and metrics never emit API keys or hashes (redaction)" do
    diag = json_response(get_admin("/diagnostics", @admin_token), 200) |> Jason.encode!()
    metrics = get_admin("/metrics").resp_body

    for body <- [diag, metrics] do
      refute body =~ "offl_demo"
      # a demo key hash from examples/.../keys.yml must never appear
      refute body =~ "745ce437a64ab1f020c303be50aa3785e742b72e61533d692f7aa024ff16b121"
      refute body =~ @admin_token
    end
  end
end
