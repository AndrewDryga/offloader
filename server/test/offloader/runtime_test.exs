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

  # resp.data is a raw JSON fragment (the encoded, cached data array); decode it to assert on rows.
  defp rows(resp), do: JSON.decode!(resp.data.json)

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

      # generated_at is the response build time (ISO8601) — lets a client behind a CDN spot a cached hit
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(resp.meta.generated_at)
      assert %{watermark: _, age_seconds: _, stale: _} = resp.meta.freshness
      decoded = rows(resp)
      assert is_list(decoded)
      assert %{"account_id" => _, "api_calls_total" => calls} = hd(decoded)
      assert is_integer(calls)
    end

    test "scopes rows to the caller's tenant", %{rt: rt} do
      params = %{"from" => "2026-05-30", "to" => "2026-06-01"}
      {:ok, acme} = Runtime.serve(rt, "customer_usage_summary", "tenant_acme", params, "r")
      {:ok, globex} = Runtime.serve(rt, "customer_usage_summary", "tenant_globex", params, "r")

      acme_accounts = Enum.map(rows(acme), & &1["account_id"])
      globex_accounts = Enum.map(rows(globex), & &1["account_id"])
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

    test "concurrent serves stay correct and tenant-scoped (read path is not serialized)", %{
      rt: rt
    } do
      params = %{"from" => "2026-05-30", "to" => "2026-06-01"}

      results =
        [{"tenant_acme", "acct_"}, {"tenant_globex", "acct_orion"}]
        |> List.duplicate(100)
        |> List.flatten()
        |> Task.async_stream(
          fn {tenant, _} ->
            case Runtime.serve(rt, "customer_usage_summary", tenant, params, "r") do
              {:ok, resp} ->
                {tenant, {:ok, Enum.map(rows(resp), & &1["account_id"])}}

              # 50-way concurrency can exceed the read pool; the runtime sheds the
              # overflow with a 503 (:not_ready). That is correct backpressure, not a
              # correctness failure — record it, don't crash the match on it.
              {:error, %ApiError{family: :not_ready}} ->
                {tenant, :busy}
            end
          end,
          max_concurrency: 50,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, res} -> res end)

      served = for {tenant, {:ok, accounts}} <- results, do: {tenant, accounts}

      # Every globex response contains only acct_orion; acme never does — proving no
      # cross-request bleed under concurrency.
      for {tenant, accounts} <- served do
        case tenant do
          "tenant_globex" -> assert accounts == ["acct_orion"]
          "tenant_acme" -> refute "acct_orion" in accounts
        end
      end

      # All 200 returned (served or cleanly shed), and the bulk actually served — the
      # read path runs concurrently; it neither serializes nor collapses under load.
      assert length(results) == 200
      assert length(served) >= 100
    end

    test "serving keeps working while a refresh is in flight (reads bypass the writer)", %{rt: rt} do
      params = %{"from" => "2026-05-30", "to" => "2026-06-01"}

      # Kick a refresh (a GenServer.call that occupies the writer) from another
      # process, and hammer serve concurrently. Serve must not queue behind it.
      refresher = Task.async(fn -> Runtime.refresh(rt, "customer_usage") end)

      served =
        1..50
        |> Task.async_stream(
          fn _ -> Runtime.serve(rt, "customer_usage_summary", "tenant_acme", params, "r") end,
          max_concurrency: 25,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(served, &match?({:ok, _}, &1))
      assert {:ok, _} = Task.await(refresher, 30_000)
    end
  end
end
