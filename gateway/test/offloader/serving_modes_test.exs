defmodule Offloader.ServingModesTest do
  use ExUnit.Case, async: false

  alias Offloader.{Catalog, Compiler, Engine, Manifest, Runtime}

  @dir Path.expand("../../../examples/customer-analytics", __DIR__)
  @project Path.join(@dir, "offloader.yml")
  @manifest Path.join(@dir, "data/customer_usage/manifest.json")
  @params %{"from" => "2026-05-30", "to" => "2026-06-01"}

  describe "serving modes (local_table vs remote_scan)" do
    setup do
      {:ok, cat} = Catalog.load(@project)
      {:ok, m} = Manifest.load(@manifest)
      dir = Path.join(System.tmp_dir!(), "offl_modes_#{System.unique_integer([:positive])}")
      {:ok, eng} = Engine.start_link(cache_dir: dir)
      {:ok, _} = Engine.materialize(eng, "snap", m)
      :ok = Engine.swap(eng, "customer_usage", "snap")

      on_exit(fn ->
        if Process.alive?(eng), do: Engine.stop(eng)
        File.rm_rf!(dir)
      end)

      %{cat: cat, m: m, eng: eng}
    end

    test "both modes return identical rows for the same request", %{cat: cat, m: m, eng: eng} do
      ep = cat.endpoints["customer_usage_summary"]

      {:ok, table_plan} = Compiler.compile(ep, @params, "tenant_acme", {:table, "customer_usage"})
      {:ok, scan_plan} = Compiler.compile(ep, @params, "tenant_acme", {:scan, m.files, m.dir})

      # local_table reads the materialized view; remote_scan reads the file directly
      refute table_plan.sql =~ "read_csv_auto"
      assert scan_plan.sql =~ "read_csv_auto"

      {:ok, from_table} = Engine.execute(eng, table_plan.sql, table_plan.params)
      {:ok, from_scan} = Engine.execute(eng, scan_plan.sql, scan_plan.params)
      assert from_table.rows == from_scan.rows
      assert from_table.rows != []
    end
  end

  describe "response cache" do
    setup do
      dir = Path.join(System.tmp_dir!(), "offl_cache_#{System.unique_integer([:positive])}")
      {:ok, rt} = Runtime.start_link(name: nil, config_path: @project, cache_dir: dir)

      on_exit(fn ->
        if Process.alive?(rt), do: GenServer.stop(rt)
        File.rm_rf!(dir)
      end)

      %{rt: rt}
    end

    defp serve(rt, params) do
      {:ok, resp} = Runtime.serve(rt, "customer_usage_summary", "tenant_acme", params, "r")
      resp
    end

    test "first read is a miss, an identical repeat is a hit with the same data", %{rt: rt} do
      first = serve(rt, @params)
      assert first.meta.cache == "miss"
      assert first.meta.serving_mode == "local_table"

      second = serve(rt, @params)
      assert second.meta.cache == "hit"
      assert second.data == first.data
    end

    test "a different tenant or params is a separate cache entry (a miss)", %{rt: rt} do
      _ = serve(rt, @params)
      assert serve(rt, Map.put(@params, "account_id", "acct_apollo")).meta.cache == "miss"

      # different tenant, same params -> miss (tenant is part of the key)
      {:ok, other} = Runtime.serve(rt, "customer_usage_summary", "tenant_globex", @params, "r")
      assert other.meta.cache == "miss"
    end

    test "a refresh invalidates the cache (snapshot-based)", %{rt: rt} do
      assert serve(rt, @params).meta.cache == "miss"
      assert serve(rt, @params).meta.cache == "hit"

      {:ok, _} = Runtime.refresh(rt, "customer_usage")
      # cache cleared -> next identical read recomputes
      assert serve(rt, @params).meta.cache == "miss"
    end
  end
end
