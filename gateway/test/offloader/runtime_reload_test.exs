defmodule Offloader.RuntimeReloadTest do
  # Runtime.reload/2: hot config reconcile with ZERO downtime, including a blue-green
  # cutover on a dataset schema change. Each test asserts the live endpoint answers 200
  # throughout the change. async: false — a real Runtime + DuckDB engine.
  use ExUnit.Case, async: false

  alias Offloader.{ApiError, Runtime}

  @example Path.expand("../../../examples/customer-analytics", __DIR__)
  @params %{"from" => "2026-05-30", "to" => "2026-06-01"}

  setup do
    # Boot from an isolated copy so config_dir is writable and per-test.
    project = Path.join(System.tmp_dir!(), "offl_reload_#{System.unique_integer([:positive])}")
    File.cp_r!(@example, project)

    cache =
      Path.join(System.tmp_dir!(), "offl_reload_cache_#{System.unique_integer([:positive])}")

    {:ok, rt} =
      Runtime.start_link(
        name: nil,
        config_path: Path.join(project, "offloader.yml"),
        cache_dir: cache
      )

    on_exit(fn ->
      if Process.alive?(rt), do: GenServer.stop(rt)
      File.rm_rf!(project)
      File.rm_rf!(cache)
    end)

    assert Runtime.ready?(rt)
    base = Runtime.catalog(rt)
    %{rt: rt, base: base}
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp serve(rt, name), do: Runtime.serve(rt, name, "tenant_acme", @params, "r")

  # clone an existing endpoint under a new name (a valid endpoint on the same dataset)
  defp clone_endpoint(catalog, from, new_name) do
    ep = %{catalog.endpoints[from] | name: new_name}
    put_in(catalog.endpoints[new_name], ep)
  end

  defp put_schema(catalog, dataset_id, schema) do
    put_in(catalog.datasets[dataset_id].schema, schema)
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop_until(fun, deadline)
  end

  defp loop_until(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("condition not met before timeout")
      true -> Process.sleep(25) && loop_until(fun, deadline)
    end
  end

  # ── endpoint-only changes (unchanged dataset → applied at once) ────────────────

  test "adding an endpoint over an unchanged dataset serves it at once; the original never breaks",
       %{rt: rt, base: base} do
    assert {:ok, _} = serve(rt, "customer_usage_summary")

    new = clone_endpoint(base, "customer_usage_summary", "customer_usage_summary_2")
    :ok = Runtime.reload(rt, new)

    assert {:ok, _} = serve(rt, "customer_usage_summary_2")
    assert {:ok, _} = serve(rt, "customer_usage_summary")
  end

  test "adding a dataset materializes it; its endpoint serves and the existing ones never break",
       %{rt: rt, base: base} do
    # a second dataset over the SAME manifest/data, with its own endpoint
    ds2 = %{base.datasets["customer_usage"] | id: "customer_usage_2"}

    ep2 = %{
      base.endpoints["customer_usage_summary"]
      | name: "cu2_summary",
        dataset: "customer_usage_2"
    }

    new = %{
      base
      | datasets: Map.put(base.datasets, "customer_usage_2", ds2),
        endpoints: Map.put(base.endpoints, "cu2_summary", ep2)
    }

    :ok = Runtime.reload(rt, new)

    # the new dataset's endpoint becomes ready once it materializes; the existing one never breaks
    eventually(fn ->
      assert {:ok, _} = serve(rt, "customer_usage_summary")
      match?({:ok, _}, serve(rt, "cu2_summary"))
    end)

    assert {:ok, _} = serve(rt, "cu2_summary")
  end

  test "removing an endpoint takes it out of service; the rest keep serving", %{
    rt: rt,
    base: base
  } do
    assert {:ok, _} = serve(rt, "top_accounts_by_usage")

    new = update_in(base.endpoints, &Map.delete(&1, "top_accounts_by_usage"))
    :ok = Runtime.reload(rt, new)

    assert {:error, %ApiError{}} = serve(rt, "top_accounts_by_usage")
    assert {:ok, _} = serve(rt, "customer_usage_summary")
  end

  test "a reload flushes the response cache", %{rt: rt, base: base} do
    {:ok, _} = serve(rt, "customer_usage_summary")
    {:ok, hit} = serve(rt, "customer_usage_summary")
    assert hit.meta.cache == "hit"

    :ok = Runtime.reload(rt, base)

    {:ok, after_reload} = serve(rt, "customer_usage_summary")
    assert after_reload.meta.cache == "miss"
  end

  # ── schema change → blue-green staged cutover (zero downtime) ───────────────────

  test "schema change: the old endpoints serve throughout; a new endpoint appears only after cutover",
       %{rt: rt, base: base} do
    reordered = Enum.reverse(base.datasets["customer_usage"].schema)

    new =
      base
      |> put_schema("customer_usage", reordered)
      |> clone_endpoint("customer_usage_summary", "customer_usage_summary_v2")

    :ok = Runtime.reload(rt, new)

    # the existing endpoint must answer 200 on every poll; the new one appears only once the
    # staged (new-schema) table has been built and cut over.
    eventually(fn ->
      assert {:ok, _} = serve(rt, "customer_usage_summary")
      match?({:ok, _}, serve(rt, "customer_usage_summary_v2"))
    end)

    assert {:ok, _} = serve(rt, "customer_usage_summary")
    assert {:ok, _} = serve(rt, "customer_usage_summary_v2")
  end

  test "a failed staged build keeps the old version serving (no downtime)", %{rt: rt, base: base} do
    # a contract column the snapshot lacks makes the staged build incompatible → it can never
    # cut over, so the old snapshot must keep serving indefinitely.
    ghost = base.datasets["customer_usage"].schema ++ [%{name: "ghost_col", type: "VARCHAR"}]

    new =
      base
      |> put_schema("customer_usage", ghost)
      |> clone_endpoint("customer_usage_summary", "customer_usage_summary_v2")

    :ok = Runtime.reload(rt, new)

    # across the staging attempt + failure window, the old endpoint never breaks and the new
    # one (which needs the never-ready table) never goes live.
    for _ <- 1..40 do
      assert {:ok, _} = serve(rt, "customer_usage_summary")
      assert {:error, %ApiError{}} = serve(rt, "customer_usage_summary_v2")
      Process.sleep(10)
    end
  end

  test "a second schema reload supersedes the first — the latest target wins", %{
    rt: rt,
    base: base
  } do
    schema = base.datasets["customer_usage"].schema
    reversed = Enum.reverse(schema)
    rotated = tl(schema) ++ [hd(schema)]

    new_a =
      base
      |> put_schema("customer_usage", reversed)
      |> clone_endpoint("customer_usage_summary", "customer_usage_summary_v2")

    new_b =
      base
      |> put_schema("customer_usage", rotated)
      |> clone_endpoint("customer_usage_summary", "customer_usage_summary_v3")

    :ok = Runtime.reload(rt, new_a)
    :ok = Runtime.reload(rt, new_b)

    eventually(fn ->
      assert {:ok, _} = serve(rt, "customer_usage_summary")
      match?({:ok, _}, serve(rt, "customer_usage_summary_v3"))
    end)

    # B won: v3 is live; v2 from the superseded A reload never became live.
    assert {:ok, _} = serve(rt, "customer_usage_summary_v3")
    assert {:error, %ApiError{}} = serve(rt, "customer_usage_summary_v2")
  end
end
