defmodule Offloader.WarmStartTest do
  # What survives a restart, and what must not. "Restart" stops the Runtime AND its engine (so
  # the DuckDB file closes) and starts a new Runtime on the same cache_dir. Each test works on
  # its own copy of the example project so it can edit config and data freely.
  use ExUnit.Case, async: false

  alias Offloader.{Catalog, Refresh, Runtime}

  @example Path.expand("../../../examples/customer-analytics", __DIR__)
  @params %{"from" => "2026-05-30", "to" => "2026-06-01"}

  defp tmp(name) do
    dir = Path.join(System.tmp_dir!(), "offl_warm_#{name}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp project do
    dir = tmp("project")
    File.cp_r!(@example, dir)
    dir
  end

  defp start(project, cache) do
    config = Path.join(project, "offloader.yml")
    {:ok, rt} = Runtime.start_link(name: nil, config_path: config, cache_dir: cache)
    on_exit(fn -> Offloader.TestSupport.stop_if_alive(rt) end)
    rt
  end

  defp stop(rt) do
    engine = Runtime.__test_context__(rt).engine
    GenServer.stop(rt)
    Offloader.TestSupport.stop_if_alive(engine)
  end

  defp restart(rt, project, cache) do
    stop(rt)
    start(project, cache)
  end

  defp total(rt) do
    {:ok, resp} = Runtime.serve(rt, "customer_usage_summary", "tenant_acme", @params, "r")
    resp.data.json |> JSON.decode!() |> Enum.map(& &1["api_calls_total"]) |> Enum.sum()
  end

  defp status(rt), do: Runtime.snapshot_state(rt, "customer_usage").last_attempted.status

  defp edit(path, fun), do: File.write!(path, fun.(File.read!(path)))

  defp dataset_yml(project), do: Path.join(project, "datasets/customer_usage.yml")

  # data/customer_usage_b: the same rows with api_calls x1000, under the SAME snapshot id.
  defp add_same_id_other_data(project) do
    src = Path.join(project, "data/customer_usage")
    dst = Path.join(project, "data/customer_usage_b")
    File.mkdir_p!(dst)
    File.cp!(Path.join(src, "manifest.json"), Path.join(dst, "manifest.json"))

    [header | rows] =
      src |> Path.join("customer_usage.csv") |> File.read!() |> String.split("\n", trim: true)

    rows =
      for row <- rows do
        cols = String.split(row, ",")
        api_calls = String.to_integer(Enum.at(cols, 5)) * 1000
        cols |> List.replace_at(5, Integer.to_string(api_calls)) |> Enum.join(",")
      end

    File.write!(Path.join(dst, "customer_usage.csv"), Enum.join([header | rows], "\n") <> "\n")
  end

  defp point_at_b(project),
    do:
      edit(
        dataset_yml(project),
        &String.replace(
          &1,
          "data/customer_usage/manifest.json",
          "data/customer_usage_b/manifest.json"
        )
      )

  describe "a stored table is reused only while its source and contract match the config" do
    test "a manifest moved to other data under the same snapshot id is rebuilt after a restart" do
      {project, cache} = {project(), tmp("cache")}
      add_same_id_other_data(project)
      rt = start(project, cache)
      before = total(rt)

      point_at_b(project)
      rt = restart(rt, project, cache)

      assert status(rt) == :ok
      assert total(rt) == before * 1000
    end

    test "the same move applied by a hot reload is rebuilt too" do
      project = project()
      add_same_id_other_data(project)
      rt = start(project, tmp("cache"))
      before = total(rt)

      point_at_b(project)
      {:ok, catalog} = Catalog.load(Path.join(project, "offloader.yml"))
      :ok = Runtime.reload(rt, catalog)

      assert eventually(fn -> total(rt) == before * 1000 end)
    end

    test "a contract column the data does not have is rejected after a restart" do
      {project, cache} = {project(), tmp("cache")}
      rt = start(project, cache)

      edit(
        dataset_yml(project),
        &String.replace(&1, "schema:\n", "schema:\n  - { name: region, type: VARCHAR }\n")
      )

      rt = restart(rt, project, cache)

      assert status(rt) == :rejected
      refute Runtime.ready?(rt)
    end

    test "a sidecar in the old format is ignored: the dataset boots cold and rewrites it" do
      {project, cache} = {project(), tmp("cache")}
      rt = start(project, cache)
      active = Runtime.snapshot_active(rt, "customer_usage")
      old_format = %{"customer_usage" => Map.delete(active, :fingerprint)}

      stop(rt)
      File.write!(Path.join(cache, "snapshots.json"), JSON.encode!(old_format))
      rt = start(project, cache)

      assert status(rt) == :ok
      assert Runtime.ready?(rt)

      assert %{"version" => 2} =
               cache |> Path.join("snapshots.json") |> File.read!() |> JSON.decode!()
    end
  end

  # The configured manifest now names a newer snapshot, as a producer publishing would.
  defp publish_new_snapshot(project) do
    path = Path.join(project, "data/customer_usage/manifest.json")
    sid = "2026-06-05T00:00:00Z_r0099"
    manifest = path |> File.read!() |> JSON.decode!() |> Map.put("snapshot_id", sid)
    File.write!(path, JSON.encode!(manifest))
    sid
  end

  defp served(rt) do
    {:ok, resp} = Runtime.serve(rt, "customer_usage_summary", "tenant_acme", @params, "r")
    resp.meta.snapshot_id
  end

  describe "rollback state survives a restart" do
    test "a rollback holds: the snapshot rolled back from stays quarantined" do
      {project, cache} = {project(), tmp("cache")}
      rt = start(project, cache)
      s1 = Runtime.snapshot_active(rt, "customer_usage").snapshot_id
      s2 = publish_new_snapshot(project)
      assert {:ok, ^s2} = Runtime.refresh(rt, "customer_usage")
      assert {:ok, ^s1} = Runtime.rollback(rt, "customer_usage")

      # The config still names s2, so without the quarantine the boot refresh re-pulls it.
      rt = restart(rt, project, cache)
      state = Runtime.snapshot_state(rt, "customer_usage")
      assert state.active.snapshot_id == s1
      assert state.quarantined == s2
      assert served(rt) == s1
    end

    test "the previous snapshot is kept, so rollback still works after a restart" do
      {project, cache} = {project(), tmp("cache")}
      rt = start(project, cache)
      s1 = Runtime.snapshot_active(rt, "customer_usage").snapshot_id
      s2 = publish_new_snapshot(project)
      assert {:ok, ^s2} = Runtime.refresh(rt, "customer_usage")

      rt = restart(rt, project, cache)
      assert {:ok, ^s1} = Runtime.rollback(rt, "customer_usage")
      assert served(rt) == s1
    end
  end

  test "the fingerprint changes with the source and with every part of the contract" do
    {:ok, catalog} = Catalog.load(Path.join(@example, "offloader.yml"))
    dataset = catalog.datasets["customer_usage"]
    static = {:static, "/data/manifest.json"}
    source = {:source, %{type: "databricks", bucket: "b", prefix: "p/"}}
    base = Refresh.fingerprint(dataset, static)

    assert base == Refresh.fingerprint(dataset, static)
    refute base == Refresh.fingerprint(dataset, {:static, "/other/manifest.json"})

    refute Refresh.fingerprint(dataset, source) ==
             Refresh.fingerprint(dataset, put_elem(source, 1, %{elem(source, 1) | prefix: "q/"}))

    refute base == Refresh.fingerprint(%{dataset | schema: tl(dataset.schema)}, static)
    refute base == Refresh.fingerprint(%{dataset | tenant_column: nil}, static)
    refute base == Refresh.fingerprint(%{dataset | sort_columns: ["usage_date"]}, static)
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(25) && eventually(fun, deadline)
    end
  end
end
