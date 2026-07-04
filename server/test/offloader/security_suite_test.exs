defmodule Offloader.SecuritySuiteTest do
  @moduledoc """
  The adversarial security proof (docs/security-model.md → "Required tests"). Runs at
  the HTTP boundary against a live runtime. Every case here is an invariant a pilot
  depends on; a fixed bypass gets a regression test here. Support-bundle redaction is
  the tools' concern and is proven in C04.
  """
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Offloader.Runtime

  @project Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)
  @admin_token "admin-secret"
  @acme "offl_demo_acme_key"
  @globex "offl_demo_globex_key"
  @revoked "offl_demo_revoked_key"
  @range %{"from" => "2026-05-30", "to" => "2026-06-01"}

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_sec_#{System.unique_integer([:positive])}")
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

  defp req(endpoint, path, token) do
    conn = build_conn()
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    dispatch(conn, endpoint, :get, path)
  end

  defp api(name, query, token),
    do: req(OffloaderWeb.ApiEndpoint, "/v1/endpoints/#{name}?" <> URI.encode_query(query), token)

  defp admin(path, token \\ nil), do: req(OffloaderWeb.AdminEndpoint, path, token)

  # ── authentication ──────────────────────────────────────────────────────────────

  test "API key bypass: no key is 401" do
    assert json_response(api("customer_usage_summary", @range, nil), 401)["error"]["family"] ==
             "unauthorized"
  end

  test "revoked key is 401" do
    assert json_response(api("customer_usage_summary", @range, @revoked), 401)
  end

  test "garbage key is 401 (never a 500)" do
    assert json_response(api("customer_usage_summary", @range, "../etc/passwd"), 401)
  end

  # ── authorization / existence non-disclosure ──────────────────────────────────────

  test "wrong endpoint scope and unknown endpoint are BYTE-IDENTICAL 404s (no existence leak)" do
    out_of_scope =
      json_response(
        api("customer_usage_daily", Map.put(@range, "account_id", "acct_orion"), @globex),
        404
      )

    unknown = json_response(api("does_not_exist", @range, @globex), 404)
    # the error is indistinguishable (only the per-request request_id differs)
    assert out_of_scope["error"] == unknown["error"]
    assert out_of_scope["error"]["family"] == "not_found"
  end

  # ── tenant isolation ──────────────────────────────────────────────────────────────

  test "tenant param override is rejected (422), never applied" do
    assert json_response(
             api("customer_usage_summary", Map.put(@range, "tenant_id", "tenant_acme"), @globex),
             422
           )["error"]["family"] == "invalid_param"
  end

  test "a key sees only its own tenant's rows" do
    globex = json_response(api("customer_usage_summary", @range, @globex), 200)
    ids = MapSet.new(globex["data"], & &1["account_id"])
    # acme's accounts must never appear for a globex key
    refute MapSet.member?(ids, "acct_apollo")
    refute MapSet.member?(ids, "acct_zephyr")
  end

  # ── column allowlist ──────────────────────────────────────────────────────────────

  test "projection outside the allowlist is impossible (no plan/storage_gb leak)" do
    body =
      json_response(
        api("customer_usage_daily", Map.put(@range, "account_id", "acct_apollo"), @acme),
        200
      )

    for row <- body["data"] do
      refute Map.has_key?(row, "plan")
      refute Map.has_key?(row, "storage_gb")
    end
  end

  # ── injection ─────────────────────────────────────────────────────────────────────

  test "filter injection via a param value is bound as data, not SQL" do
    # A classic SQL-injection payload in a filter value must match nothing, not OR past
    # the tenant filter or error out.
    query = Map.put(@range, "account_id", "acct_apollo' OR '1'='1")
    body = json_response(api("customer_usage_summary", query, @acme), 200)
    assert body["data"] == []
  end

  test "injection via a typed param is rejected at validation" do
    # enum and date params can't carry a payload at all
    assert json_response(
             api(
               "customer_usage_daily",
               Map.merge(@range, %{
                 "account_id" => "a",
                 "product_area" => "api'; DROP TABLE snap;--"
               }),
               @acme
             ),
             422
           )

    assert json_response(
             api(
               "customer_usage_summary",
               %{"from" => "2026'; DROP", "to" => "2026-06-01"},
               @acme
             ),
             422
           )
  end

  # ── pagination abuse ──────────────────────────────────────────────────────────────

  test "pagination abuse is bounded" do
    assert json_response(
             api("top_accounts_by_usage", Map.put(@range, "limit", "100000"), @acme),
             422
           )

    assert json_response(api("top_accounts_by_usage", Map.put(@range, "limit", "0"), @acme), 422)

    assert json_response(
             api("top_accounts_by_usage", Map.put(@range, "offset", "-1"), @acme),
             422
           )
  end

  # ── docs / diagnostics privacy ────────────────────────────────────────────────────

  test "docs, schema, diagnostics, and metrics are NOT on the API port" do
    for path <- ["/docs", "/openapi.json", "/diagnostics", "/metrics", "/schema"] do
      assert req(OffloaderWeb.ApiEndpoint, path, @acme).status == 404
    end
  end

  test "admin diagnostics require the admin token" do
    assert json_response(admin("/diagnostics"), 401)
    assert json_response(admin("/diagnostics", "wrong"), 401)
    assert json_response(admin("/diagnostics", @admin_token), 200)
  end

  # ── redaction ─────────────────────────────────────────────────────────────────────

  test "diagnostics and metrics never emit keys, hashes, or the admin token" do
    diag = admin("/diagnostics", @admin_token).resp_body
    metrics = admin("/metrics").resp_body

    for body <- [diag, metrics] do
      refute body =~ "offl_demo"
      refute body =~ "745ce437a64ab1f020c303be50aa3785e742b72e61533d692f7aa024ff16b121"
      refute body =~ @admin_token
    end
  end

  test "an error body never echoes the raw offending param value" do
    secret_looking = "SUPERSECRETVALUE123"

    body =
      json_response(
        api(
          "customer_usage_daily",
          Map.merge(@range, %{"account_id" => "a", "product_area" => secret_looking}),
          @acme
        ),
        422
      )

    refute Jason.encode!(body) =~ secret_looking
  end
end
