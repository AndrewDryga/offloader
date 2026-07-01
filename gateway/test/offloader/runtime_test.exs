defmodule Offloader.RuntimeTest do
  use ExUnit.Case, async: false

  alias Offloader.{ApiError, Runtime}

  @project Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_rt_#{System.unique_integer([:positive])}")
    {:ok, rt} = Runtime.start_link(name: nil, config_path: @project, cache_dir: dir)

    on_exit(fn ->
      if Process.alive?(rt), do: GenServer.stop(rt)
      File.rm_rf!(dir)
    end)

    %{rt: rt}
  end

  describe "authorize/3" do
    test "returns the bound tenant for a valid key + granted endpoint", %{rt: rt} do
      assert {:ok, "tenant_acme"} =
               Runtime.authorize(rt, "offl_demo_acme_key", "customer_usage_summary")
    end

    test "rejects an unknown token as unauthorized", %{rt: rt} do
      assert {:error, %ApiError{family: :unauthorized}} =
               Runtime.authorize(rt, "nope", "customer_usage_summary")
    end

    test "rejects a revoked key as unauthorized", %{rt: rt} do
      assert {:error, %ApiError{family: :unauthorized}} =
               Runtime.authorize(rt, "offl_demo_revoked_key", "customer_usage_summary")
    end

    test "an endpoint outside the key's scope is not_found (no existence leak)", %{rt: rt} do
      # demo_globex is granted only customer_usage_summary.
      assert {:error, %ApiError{family: :not_found}} =
               Runtime.authorize(rt, "offl_demo_globex_key", "customer_usage_daily")
    end
  end

  describe "serve/5" do
    test "returns data plus request_id, snapshot_id, and freshness metadata", %{rt: rt} do
      params = %{"from" => "2026-05-30", "to" => "2026-06-01"}

      assert {:ok, resp} =
               Runtime.serve(rt, "customer_usage_summary", "tenant_acme", params, "req-1")

      assert resp.meta.request_id == "req-1"
      assert resp.meta.endpoint == "customer_usage_summary"
      assert resp.meta.snapshot_id == "2026-06-01T00:00:00Z_r0007"
      assert %{watermark: _, age_seconds: _, stale: _} = resp.meta.freshness
      assert is_list(resp.data)
      assert %{"account_id" => _, "api_calls_total" => calls} = hd(resp.data)
      assert is_integer(calls)
    end

    test "scopes rows to the caller's tenant", %{rt: rt} do
      params = %{"from" => "2026-05-30", "to" => "2026-06-01"}
      {:ok, acme} = Runtime.serve(rt, "customer_usage_summary", "tenant_acme", params, "r")
      {:ok, globex} = Runtime.serve(rt, "customer_usage_summary", "tenant_globex", params, "r")

      acme_accounts = Enum.map(acme.data, & &1["account_id"])
      globex_accounts = Enum.map(globex.data, & &1["account_id"])
      # acme has acct_apollo/acct_zephyr; globex has acct_orion — no overlap.
      assert MapSet.disjoint?(MapSet.new(acme_accounts), MapSet.new(globex_accounts))
    end

    test "an unknown endpoint is not_found", %{rt: rt} do
      assert {:error, %ApiError{family: :not_found}} =
               Runtime.serve(rt, "no_such_endpoint", "tenant_acme", %{}, "r")
    end

    test "an invalid param is surfaced as invalid_param", %{rt: rt} do
      assert {:error, %ApiError{family: :invalid_param}} =
               Runtime.serve(
                 rt,
                 "customer_usage_summary",
                 "tenant_acme",
                 %{"from" => "2026-05-30"},
                 "r"
               )
    end
  end
end
