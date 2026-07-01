defmodule OffloaderWeb.EndpointHTTPTest do
  # Boots a named Offloader.Runtime (the controller calls it by module name) and
  # dispatches real requests through the API endpoint. async: false (singleton + DuckDB).
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Offloader.Runtime

  @endpoint OffloaderWeb.ApiEndpoint
  @project Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_http_#{System.unique_integer([:positive])}")
    {:ok, rt} = Runtime.start_link(name: Runtime, config_path: @project, cache_dir: dir)

    on_exit(fn ->
      if Process.alive?(rt), do: GenServer.stop(rt)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp get_endpoint(name, query, token) do
    conn = build_conn()
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    get(conn, "/v1/endpoints/#{name}?" <> URI.encode_query(query))
  end

  test "a valid request returns 200 with data and freshness metadata" do
    conn =
      get_endpoint(
        "customer_usage_summary",
        %{"from" => "2026-05-30", "to" => "2026-06-01"},
        "offl_demo_acme_key"
      )

    body = json_response(conn, 200)
    assert is_list(body["data"])
    assert body["meta"]["snapshot_id"] == "2026-06-01T00:00:00Z_r0007"
    assert body["meta"]["request_id"]
    assert body["meta"]["freshness"]["watermark"]
    assert get_resp_header(conn, "x-request-id") != []
  end

  test "a missing bearer token is 401" do
    conn =
      get_endpoint("customer_usage_summary", %{"from" => "2026-05-30", "to" => "2026-06-01"}, nil)

    assert json_response(conn, 401)["error"]["family"] == "unauthorized"
  end

  test "a revoked key is 401" do
    conn =
      get_endpoint(
        "customer_usage_summary",
        %{"from" => "2026-05-30", "to" => "2026-06-01"},
        "offl_demo_revoked_key"
      )

    assert json_response(conn, 401)
  end

  test "an unknown endpoint is 404 (same as out-of-scope — no existence leak)" do
    conn = get_endpoint("no_such_endpoint", %{}, "offl_demo_acme_key")
    assert json_response(conn, 404)["error"]["family"] == "not_found"
  end

  test "an endpoint outside the key's scope is 404, indistinguishable from unknown" do
    # demo_globex may only use customer_usage_summary.
    conn =
      get_endpoint(
        "customer_usage_daily",
        %{"account_id" => "acct_orion", "from" => "2026-05-30", "to" => "2026-06-01"},
        "offl_demo_globex_key"
      )

    assert json_response(conn, 404)["error"]["family"] == "not_found"
  end

  test "an invalid enum param is 422" do
    query = %{
      "account_id" => "acct_apollo",
      "from" => "2026-05-30",
      "to" => "2026-06-01",
      "product_area" => "billing"
    }

    conn = get_endpoint("customer_usage_daily", query, "offl_demo_acme_key")
    assert json_response(conn, 422)["error"]["family"] == "invalid_param"
  end

  test "a smuggled tenant_id param is rejected 422, never applied" do
    query = %{"from" => "2026-05-30", "to" => "2026-06-01", "tenant_id" => "tenant_acme"}
    conn = get_endpoint("customer_usage_summary", query, "offl_demo_globex_key")
    assert json_response(conn, 422)["error"]["family"] == "invalid_param"
  end

  test "tenant scoping: globex sees only its own accounts over HTTP" do
    query = %{"from" => "2026-05-30", "to" => "2026-06-01"}
    acme = json_response(get_endpoint("customer_usage_summary", query, "offl_demo_acme_key"), 200)

    globex =
      json_response(get_endpoint("customer_usage_summary", query, "offl_demo_globex_key"), 200)

    acme_ids = MapSet.new(acme["data"], & &1["account_id"])
    globex_ids = MapSet.new(globex["data"], & &1["account_id"])
    assert MapSet.disjoint?(acme_ids, globex_ids)
    refute MapSet.member?(globex_ids, "acct_apollo")
  end
end
