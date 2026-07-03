defmodule Offloader.EnginePoolTest do
  # The load-shed contract under REAL saturation (not just the error mapping): with
  # every read connection busy, execute returns :pool_busy instead of queueing.
  # async: false — DuckDB NIF work stays serialized across the suite.
  use ExUnit.Case, async: false

  alias Offloader.Engine
  alias Offloader.Engine.Error

  # Forces row-by-row evaluation so the single slot stays busy for real seconds
  # (a bare count over range() can shortcut on known cardinality).
  @slow_sql "SELECT sum(a.range + b.range) FROM range(3000000) a, range(300) b"

  test "a saturated read pool sheds with :pool_busy instead of queueing" do
    dir = Path.join(System.tmp_dir!(), "offl_pool_#{System.unique_integer([:positive])}")
    {:ok, eng} = Engine.start_link(cache_dir: dir, pool_size: 1)

    on_exit(fn ->
      if Process.alive?(eng), do: Engine.stop(eng)
      File.rm_rf!(dir)
    end)

    # Sanity: the single slot works when free.
    assert {:ok, _} = Engine.execute(eng, "SELECT 1")

    # Hold the only slot with a multi-second query, give it a head start to acquire,
    # then a concurrent read must be shed — not queued.
    blocker = Task.async(fn -> Engine.execute(eng, @slow_sql) end)
    Process.sleep(300)

    assert {:error, %Error{reason: :pool_busy}} = Engine.execute(eng, "SELECT 1")

    assert {:ok, _} = Task.await(blocker, 60_000)
    # …and the slot frees again once the blocker finishes.
    assert {:ok, _} = Engine.execute(eng, "SELECT 1")
  end
end
