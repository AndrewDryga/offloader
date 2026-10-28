defmodule Offloader.ColumnTypesTest do
  # Responses are typed by the dataset CONTRACT, never by duckdbex's tuple shapes: a parquet
  # DECIMAL declared DOUBLE must serve as a number (not "0125-10-02"), at every width.
  use ExUnit.Case, async: false

  alias Offloader.{Compiler, Engine, Manifest}
  alias Offloader.Catalog.{Dataset, Endpoint}

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_types_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, db} = Duckdbex.open()
    {:ok, conn} = Duckdbex.connection(db)

    {:ok, _} =
      Duckdbex.query(conn, """
      COPY (SELECT * FROM (VALUES
        ('eu', 1.25::DECIMAL(4,2), 1.25::DECIMAL(10,2), 21474836.48::DECIMAL(18,2),
         1.25::DECIMAL(38,2), '2024-03-15 01:02:03.123'::TIMESTAMP_MS),
        ('eu', 2.50::DECIMAL(4,2), 2.50::DECIMAL(10,2), 99999999.99::DECIMAL(18,2),
         2.50::DECIMAL(38,2), '2024-03-16 00:00:00'::TIMESTAMP_MS))
        t(region, small, amount, balance, total, booked_at))
      TO '#{dir}/ledger.parquet' (FORMAT parquet)
      """)

    {:ok, eng} = Engine.start_link(cache_dir: Path.join(dir, "cache"), pool_size: 1)

    manifest = %Manifest{
      dataset_id: "ledger",
      snapshot_id: "s1",
      created_at: "2026-10-28T00:00:00Z",
      watermark: "2026-10-28T00:00:00Z",
      schema: [],
      files: [%{"path" => "ledger.parquet", "format" => "parquet"}],
      dir: dir
    }

    {:ok, _} = Engine.materialize(eng, "ledger", manifest)

    on_exit(fn ->
      if Process.alive?(eng), do: Engine.stop(eng)
      File.rm_rf!(dir)
    end)

    {:ok, ds} =
      Dataset.parse(
        %{
          "id" => "ledger",
          "manifest" => "m.json",
          "schema" =>
            [
              %{"name" => "region", "type" => "VARCHAR"},
              %{"name" => "booked_at", "type" => "TIMESTAMP"}
            ] ++
              for(c <- ~w(small amount balance total), do: %{"name" => c, "type" => "DOUBLE"})
        },
        "datasets/ledger.yml"
      )

    %{eng: eng, ds: ds}
  end

  defp serve(eng, ds, select, query) do
    raw = %{
      "name" => "ledger",
      "version" => 1,
      "owner" => "t@example.com",
      "dataset" => "ledger",
      "query" => Map.put(query, "select", select),
      "columns" => Enum.map(select, & &1["as"])
    }

    {:ok, ep} = Endpoint.parse(raw, "endpoints/ledger.yml", ds)

    {:ok, plan} = Compiler.compile(ep, %{}, nil, {:table, "ledger"})

    {:ok, %{columns: cols, rows: rows}} =
      Engine.execute(eng, plan.sql, plan.params, plan.json_columns, types: plan.types)

    data = Enum.map(rows, &Map.new(Enum.zip(cols, &1)))
    # the whole point: the response encodes, and round-trips to the same numbers
    assert data == data |> JSON.encode!() |> JSON.decode!()
    data
  end

  test "DECIMAL of every width serves as the declared DOUBLE, untruncated", %{eng: eng, ds: ds} do
    select = for c <- ~w(small amount balance total booked_at), do: %{"as" => c, "column" => c}

    assert [first, second] =
             serve(eng, ds, select, %{"order_by" => [%{"column" => "amount", "dir" => "asc"}]})

    assert first == %{
             "small" => 1.25,
             "amount" => 1.25,
             "balance" => 21_474_836.48,
             "total" => 1.25,
             "booked_at" => "2024-03-15T01:02:03.123000"
           }

    assert second["balance"] == 99_999_999.99
  end

  test "aggregates keep fractions: sum over a DOUBLE column is not rounded", %{eng: eng, ds: ds} do
    select = [
      %{"as" => "region", "column" => "region"},
      %{"as" => "amount_sum", "column" => "amount", "agg" => "sum"},
      %{"as" => "amount_min", "column" => "amount", "agg" => "min"},
      %{"as" => "amount_avg", "column" => "amount", "agg" => "avg"}
    ]

    assert [%{"amount_sum" => 3.75, "amount_min" => 1.25, "amount_avg" => 1.875}] =
             serve(eng, ds, select, %{"group_by" => ["region"]})
  end
end
