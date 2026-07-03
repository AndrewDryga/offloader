defmodule Offloader.EngineTest do
  # async: false — each test uses its own DuckDB file, but keep NIF work serialized.
  use ExUnit.Case, async: false

  alias Offloader.{Engine, Manifest}
  alias Offloader.Engine.Error

  @manifest_path Path.expand(
                   "../../../examples/customer-analytics/data/customer_usage/manifest.json",
                   __DIR__
                 )

  defp manifest do
    {:ok, m} = Manifest.load(@manifest_path)
    m
  end

  defp start_engine do
    dir = Path.join(System.tmp_dir!(), "offl_eng_#{System.unique_integer([:positive])}")
    {:ok, eng} = Engine.start_link(cache_dir: dir)

    on_exit(fn ->
      if Process.alive?(eng), do: Engine.stop(eng)
      File.rm_rf!(dir)
    end)

    {eng, dir}
  end

  setup do
    {eng, dir} = start_engine()
    {:ok, %{row_count: 36}} = Engine.materialize(eng, "snap", manifest())
    %{eng: eng, dir: dir}
  end

  test "materialize loads the snapshot and reports the row count", %{eng: eng} do
    assert {:ok, %{table: "snap", row_count: 36}} = Engine.materialize(eng, "snap", manifest())
  end

  test "known_columns lists the materialized schema", %{eng: eng} do
    assert {:ok, cols} = Engine.known_columns(eng, "snap")
    assert "tenant_id" in cols
    assert "api_calls" in cols
    assert length(cols) == 8
  end

  test "execute binds only values as params and normalizes dates/hugeints", %{eng: eng} do
    sql =
      "SELECT account_id, usage_date, sum(api_calls)::BIGINT AS calls " <>
        "FROM snap WHERE tenant_id = $1 GROUP BY 1, 2 ORDER BY calls DESC LIMIT $2"

    assert {:ok, %{columns: cols, rows: rows}} = Engine.execute(eng, sql, ["tenant_acme", 3])
    assert cols == ["account_id", "usage_date", "calls"]
    assert length(rows) == 3
    # date normalized to an ISO string, sum normalized to a plain integer
    assert [[account, date, calls] | _] = rows
    assert is_binary(account)
    assert date =~ ~r/^\d{4}-\d{2}-\d{2}$/
    assert is_integer(calls)
  end

  test "TIMESTAMP and TIME columns serialize to JSON-safe ISO strings, not raw tuples", %{
    eng: eng
  } do
    # duckdbex hands these back as nested calendar tuples that Jason cannot encode;
    # without normalization every response selecting one would 500. (TIMESTAMP and
    # TIME are documented, allowlisted column types.)
    sql =
      "SELECT TIMESTAMP '2026-06-01 12:34:56' AS ts, " <>
        "CAST('2026-06-01 12:34:56+00' AS TIMESTAMPTZ) AS tsz, TIME '01:02:03' AS tm"

    assert {:ok, %{rows: [[ts, tsz, tm]]}} = Engine.execute(eng, sql)
    assert ts =~ ~r/^2026-06-01T12:34:56/
    assert tsz =~ ~r/^2026-06-01T12:34:56/
    assert tm =~ ~r/^01:02:03/
    # The whole point: the row must round-trip through JSON without raising.
    assert {:ok, _} = Jason.encode(%{ts: ts, tsz: tsz, tm: tm})
  end

  test "a tenant-scoped query returns only that tenant's rows", %{eng: eng} do
    {:ok, %{rows: [[acme]]}} =
      Engine.execute(eng, "SELECT count(*)::BIGINT FROM snap WHERE tenant_id = $1", [
        "tenant_acme"
      ])

    {:ok, %{rows: [[globex]]}} =
      Engine.execute(eng, "SELECT count(*)::BIGINT FROM snap WHERE tenant_id = $1", [
        "tenant_globex"
      ])

    assert acme > 0 and globex > 0
    assert acme + globex < 36
  end

  test "swap points an active view at the snapshot", %{eng: eng} do
    assert :ok = Engine.swap(eng, "customer_usage", "snap")

    assert {:ok, %{rows: [[36]]}} =
             Engine.execute(eng, "SELECT count(*)::BIGINT FROM customer_usage")
  end

  test "a bad query is wrapped as a stable engine error, not a crash", %{eng: eng} do
    assert {:error, %Error{reason: :query_failed}} =
             Engine.execute(eng, "SELECT * FROM does_not_exist")
  end

  test "materializing from a missing file is wrapped as :materialize_failed", %{eng: eng} do
    bad = %Manifest{
      dataset_id: "customer_usage",
      snapshot_id: "s1",
      created_at: "2026-06-01T00:00:00Z",
      watermark: "2026-06-01T00:00:00Z",
      schema: [],
      files: [%{"path" => "definitely_missing.csv", "format" => "csv"}],
      dir: System.tmp_dir!()
    }

    assert {:error, %Error{reason: :materialize_failed}} = Engine.materialize(eng, "broken", bad)
  end

  test "drop removes a table", %{eng: eng} do
    assert :ok = Engine.drop(eng, "snap")
    assert {:error, %Error{reason: :unknown_table}} = Engine.known_columns(eng, "snap")
  end

  test "a writer call on a stopped engine returns an error, never raises (crash-safe boot)" do
    {eng, _dir} = start_engine()
    Engine.stop(eng)

    # A slow/failed writer must surface as {:error, ...} so one bad dataset can't crash
    # the caller (boot / a refresh worker) with an unhandled exit.
    assert {:error, %Error{reason: :engine_unavailable}} = Engine.swap(eng, "a", "b")
    assert {:error, %Error{reason: :engine_unavailable}} = Engine.drop(eng, "x")

    manifest = %Manifest{
      dataset_id: "customer_usage",
      snapshot_id: "s1",
      created_at: "2026-01-01T00:00:00Z",
      watermark: "2026-01-01T00:00:00Z",
      schema: [],
      files: [%{"path" => "x.csv", "format" => "csv"}],
      dir: System.tmp_dir!()
    }

    assert {:error, %Error{reason: :engine_unavailable}} = Engine.materialize(eng, "t", manifest)
  end

  test "materialized snapshots survive a restart (warm cache)" do
    {eng, dir} = start_engine()
    {:ok, _} = Engine.materialize(eng, "warm", manifest())
    Engine.stop(eng)

    {:ok, eng2} = Engine.start_link(cache_dir: dir)
    on_exit(fn -> if Process.alive?(eng2), do: Engine.stop(eng2) end)
    assert {:ok, %{rows: [[36]]}} = Engine.execute(eng2, "SELECT count(*)::BIGINT FROM warm")
  end

  test "pool_stats reports the configured connection count", %{eng: eng} do
    assert %{connections: n, busy: 0, saturated: false} = Engine.pool_stats(eng)
    assert n > 0
  end

  test "applies OFFLOADER_DUCKDB_THREADS as a global DuckDB cap" do
    prev = Application.get_env(:offloader, :duckdb_threads)
    Application.put_env(:offloader, :duckdb_threads, 2)
    on_exit(fn -> Application.put_env(:offloader, :duckdb_threads, prev) end)

    dir = Path.join(System.tmp_dir!(), "offl_threads_#{System.unique_integer([:positive])}")
    {:ok, eng} = Engine.start_link(cache_dir: dir)
    on_exit(fn -> if Process.alive?(eng), do: Engine.stop(eng) end)

    assert {:ok, %{rows: [[2]]}} = Engine.execute(eng, "SELECT current_setting('threads')")
  end

  test "reads run concurrently across the pool and stay correct", %{eng: eng} do
    # Many concurrent reads on one engine must each get the right answer — proving
    # execute/3 runs in the caller (pooled), not serialized through one connection.
    results =
      1..200
      |> Task.async_stream(
        fn _ -> Engine.execute(eng, "SELECT count(*)::BIGINT FROM snap") end,
        max_concurrency: 50,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, res} -> res end)

    assert Enum.all?(results, &match?({:ok, %{rows: [[36]]}}, &1))
  end

  test "execute decodes json_columns into nested terms", %{eng: eng} do
    sql = ~s|SELECT to_json({a: 1, b: [10, 20]})::VARCHAR AS payload|

    assert {:ok, %{columns: ["payload"], rows: [[decoded]]}} =
             Engine.execute(eng, sql, [], ["payload"])

    assert decoded == %{"a" => 1, "b" => [10, 20]}
  end
end
