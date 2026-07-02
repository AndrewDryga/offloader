defmodule Offloader.RefreshStageTest do
  # Refresh.stage/3 is the blue-green BUILD step: materialize a new table WITHOUT swapping
  # the live view, so the old snapshot keeps serving until the Runtime cuts over.
  # async: false — DuckDB NIF work is serialized.
  use ExUnit.Case, async: false

  alias Offloader.{Catalog, Engine, Refresh}

  @project Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)
  @manifest Path.expand(
              "../../../examples/customer-analytics/data/customer_usage/manifest.json",
              __DIR__
            )

  defp dataset do
    {:ok, catalog} = Catalog.load(@project)
    catalog.datasets["customer_usage"]
  end

  defp start_engine do
    dir = Path.join(System.tmp_dir!(), "offl_stage_#{System.unique_integer([:positive])}")
    {:ok, eng} = Engine.start_link(cache_dir: dir)

    on_exit(fn ->
      if Process.alive?(eng), do: Engine.stop(eng)
      File.rm_rf!(dir)
    end)

    eng
  end

  test "materializes into the given table WITHOUT swapping the live view" do
    eng = start_engine()
    ds = dataset()

    assert {:staged, snap} = Refresh.stage(eng, ds, {:static, @manifest}, "stg_customer_usage")
    # it built exactly the staging table it was told to, distinct from the live table
    assert snap.table == "stg_customer_usage"
    assert {:ok, _cols} = Engine.known_columns(eng, "stg_customer_usage")
    # but the dataset's live view was NOT created — no swap happened yet
    assert {:error, _} = Engine.execute(eng, "SELECT * FROM #{ds.id} LIMIT 1", [])
  end

  test "an incompatible contract is rejected — nothing goes live" do
    eng = start_engine()
    ds = dataset()
    # a contract column the snapshot doesn't have makes the manifest incompatible
    bad = %{ds | schema: ds.schema ++ [%{name: "nonexistent_col", type: "VARCHAR"}]}

    assert {:rejected, attempt} = Refresh.stage(eng, bad, {:static, @manifest}, "stg_bad")
    assert attempt.status == :rejected
  end
end
