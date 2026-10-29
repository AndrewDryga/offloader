defmodule Offloader.ServingGenerationTest do
  # A request reads ONE published context: the endpoint contract, the snapshot it reports and
  # the table it queries all come from the same publish. Each test pauses the Runtime or the
  # engine's writer at the point where a refresh or a schema cutover is half applied, then
  # serves a request in that state.
  use ExUnit.Case, async: false

  alias Offloader.Runtime
  alias Offloader.Catalog.Endpoint.Select

  @example Path.expand("../../../examples/customer-analytics", __DIR__)
  @params %{"from" => "2026-05-30", "to" => "2026-06-01"}

  setup do
    project = Path.join(System.tmp_dir!(), "offl_gen_#{System.unique_integer([:positive])}")
    cache = project <> "_cache"
    File.cp_r!(@example, project)
    config = Path.join(project, "offloader.yml")
    {:ok, rt} = Runtime.start_link(name: nil, config_path: config, cache_dir: cache)

    on_exit(fn ->
      Offloader.TestSupport.stop_if_alive(rt)
      Offloader.TestSupport.rm_rf!(project)
      Offloader.TestSupport.rm_rf!(cache)
    end)

    %{rt: rt, project: project, engine: Runtime.__test_context__(rt).engine}
  end

  defp serve(rt, name), do: Runtime.serve(rt, name, "tenant_acme", @params, "r")

  # The snapshot a response reports, and the total of the data it carries. The response cache
  # is cleared first, so the read always queries a table.
  defp read(rt) do
    :ets.delete_all_objects(Runtime.__test_context__(rt).cache_table)
    {:ok, resp} = serve(rt, "customer_usage_summary")
    total = resp.data.json |> JSON.decode!() |> Enum.map(& &1["api_calls_total"]) |> Enum.sum()
    {resp.meta.snapshot_id, total}
  end

  # Write a new snapshot of the example rows into `dir`: api_calls x1000, and with `region`
  # an extra column the contract does not have yet.
  defp write_snapshot(project, dir, snapshot_id, region? \\ false) do
    src = Path.join(project, "data/customer_usage")
    dst = Path.join(project, dir)
    File.mkdir_p!(dst)

    [header | rows] =
      src
      |> Path.join("customer_usage.csv")
      |> File.read!()
      |> String.split(~r/\r?\n/, trim: true)

    rows =
      for row <- rows do
        cols = String.split(row, ",")
        cols = List.update_at(cols, 5, &Integer.to_string(String.to_integer(&1) * 1000))
        Enum.join(cols ++ if(region?, do: ["eu"], else: []), ",")
      end

    header = if region?, do: header <> ",region", else: header
    csv = Enum.join([header | rows], "\n") <> "\n"

    manifest = src |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()

    schema =
      manifest["schema"] ++
        if(region?, do: [%{"name" => "region", "type" => "VARCHAR"}], else: [])

    manifest = %{manifest | "snapshot_id" => snapshot_id, "schema" => schema}

    File.write!(Path.join(dst, "customer_usage.csv"), csv)
    File.write!(Path.join(dst, "manifest.json"), JSON.encode!(manifest))
  end

  defp queued?(pid),
    do: match?({:message_queue_len, n} when n > 0, Process.info(pid, :message_queue_len))

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(10) && eventually(fun, deadline)
    end
  end

  test "mid-refresh, a response reports the snapshot whose data it carries", %{
    rt: rt,
    project: project
  } do
    {s1, total} = read(rt)
    write_snapshot(project, "data/customer_usage", "2026-06-05T00:00:00Z_r0099")

    # The refresh builds the new table, then waits on the paused Runtime to apply it.
    :ok = :sys.suspend(rt)
    refresh = Task.async(fn -> Runtime.refresh(rt, "customer_usage") end)
    assert eventually(fn -> queued?(rt) end)

    assert read(rt) == {s1, total}

    :ok = :sys.resume(rt)
    assert {:ok, s2} = Task.await(refresh)
    assert read(rt) == {s2, total * 1000}
  end

  test "mid-cutover, a new endpoint never reads the old table", %{
    rt: rt,
    project: project,
    engine: engine
  } do
    write_snapshot(project, "data/customer_usage_v2", "2026-06-05T00:00:00Z_r0100", true)
    base = Runtime.catalog(rt)
    dataset = base.datasets["customer_usage"]
    summary = base.endpoints["customer_usage_summary"]

    by_region = %{
      summary
      | name: "usage_by_region",
        group_by: summary.group_by ++ ["region"],
        select: summary.select ++ [%Select{as: "region", column: "region", type: "VARCHAR"}],
        columns: summary.columns ++ ["region"]
    }

    v2 = %{
      dataset
      | manifest: "data/customer_usage_v2/manifest.json",
        schema: dataset.schema ++ [%{name: "region", type: "VARCHAR"}]
    }

    new = %{
      base
      | datasets: %{base.datasets | "customer_usage" => v2},
        endpoints: Map.put(base.endpoints, "usage_by_region", by_region)
    }

    # Let the staged build finish while the Runtime is paused, then pause the writer so any
    # engine call the cutover makes blocks it partway through.
    :ok = :sys.suspend(engine)
    :ok = Runtime.reload(rt, new)
    :ok = :sys.suspend(rt)
    :ok = :sys.resume(engine)
    assert eventually(fn -> queued?(rt) end)
    :ok = :sys.suspend(engine)
    :ok = :sys.resume(rt)

    assert eventually(fn -> Map.has_key?(Runtime.catalog(rt).endpoints, "usage_by_region") end)
    assert {:ok, resp} = serve(rt, "usage_by_region")
    assert resp.meta.snapshot_id == "2026-06-05T00:00:00Z_r0100"
    assert Enum.all?(JSON.decode!(resp.data.json), &(&1["region"] == "eu"))

    :ok = :sys.resume(engine)
  end
end
