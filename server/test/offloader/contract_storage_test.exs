defmodule Offloader.ContractStorageTest do
  # A snapshot is stored as its contract types, so a filter param binds against the contract
  # type in both serving modes. duckdbex binds a param by the column's stored type and silently
  # wraps a value too big for a SMALLINT, so SMALLINT data under an INTEGER contract filtered
  # with 40000 used to match nothing.
  use ExUnit.Case, async: false

  alias Offloader.{ApiError, Compiler, Engine, Refresh}
  alias Offloader.Catalog.{Dataset, Endpoint}

  @example_manifest Path.expand(
                      "../../../examples/customer-analytics/data/customer_usage/manifest.json",
                      __DIR__
                    )

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_contract_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, db} = Duckdbex.open()
    {:ok, conn} = Duckdbex.connection(db)

    snapshot = fn name, select ->
      {:ok, _} =
        Duckdbex.query(conn, "COPY (#{select}) TO '#{dir}/#{name}.parquet' (FORMAT parquet)")

      manifest =
        @example_manifest
        |> File.read!()
        |> JSON.decode!()
        |> Map.merge(%{
          "dataset_id" => "nums",
          "snapshot_id" => "s_#{name}",
          "schema" => [
            %{"name" => "id", "type" => "VARCHAR"},
            %{"name" => "n", "type" => "INTEGER"}
          ],
          "files" => [%{"path" => "#{name}.parquet", "format" => "parquet"}],
          "sort_columns" => []
        })

      path = Path.join(dir, "#{name}.json")
      File.write!(path, JSON.encode!(manifest))
      {:static, path}
    end

    narrow =
      snapshot.("narrow", """
      SELECT * FROM (VALUES ('a', 1::SMALLINT), ('b', 300::SMALLINT), ('c', 30000::SMALLINT))
        t(id, n)
      """)

    wide = snapshot.("wide", "SELECT 'a' AS id, 3000000000::BIGINT AS n")

    {:ok, eng} = Engine.start_link(cache_dir: Path.join(dir, "cache"), pool_size: 1)

    on_exit(fn ->
      if Process.alive?(eng), do: Engine.stop(eng)
      Offloader.TestSupport.rm_rf!(dir)
    end)

    %{eng: eng, ds: dataset("INTEGER"), narrow: narrow, wide: wide}
  end

  defp dataset(type) do
    {:ok, ds} =
      Dataset.parse(
        %{
          "id" => "nums",
          "manifest" => "m.json",
          "schema" => [%{"name" => "id", "type" => "VARCHAR"}, %{"name" => "n", "type" => type}]
        },
        "datasets/nums.yml"
      )

    ds
  end

  defp endpoint(ds, param \\ %{}) do
    Endpoint.parse(
      %{
        "name" => "nums",
        "version" => 1,
        "owner" => "t@example.com",
        "dataset" => "nums",
        "params" => [Map.merge(%{"name" => "max", "type" => "integer"}, param)],
        "query" => %{
          "select" => [%{"as" => "id", "column" => "id"}, %{"as" => "n", "column" => "n"}],
          "filters" => [%{"column" => "n", "op" => "lte", "param" => "max"}],
          "order_by" => [%{"column" => "id", "dir" => "asc"}]
        },
        "columns" => ["id", "n"]
      },
      "endpoints/nums.yml",
      ds
    )
  end

  defp ids(eng, ep, params, source) do
    {:ok, plan} = Compiler.compile(ep, params, nil, source)
    {:ok, %{rows: rows}} = Engine.execute(eng, plan.sql, plan.params, [], types: plan.types)
    Enum.map(rows, &hd/1)
  end

  test "SMALLINT data under an INTEGER contract filters by the whole INTEGER range", %{
    eng: eng,
    ds: ds,
    narrow: narrow
  } do
    {:swapped, snap, _} = Refresh.perform(eng, ds, nil, narrow, force: true)
    {:ok, ep} = endpoint(ds)

    for source <- [{:table, snap.table}, {:scan, snap.files, snap.dir}] do
      assert ids(eng, ep, %{"max" => "40000"}, source) == ["a", "b", "c"]
      assert ids(eng, ep, %{"max" => "299"}, source) == ["a"]
    end
  end

  test "data that doesn't fit its contract type fails to load", %{eng: eng, ds: ds, wide: wide} do
    assert {:failed, attempt} = Refresh.perform(eng, ds, nil, wide, force: true)
    assert attempt.error =~ "out of range"
  end

  test "an integer param outside its column's range is a 422", %{ds: ds} do
    {:ok, ep} = endpoint(ds)

    assert Compiler.compile(ep, %{"max" => "2147483648"}, nil, {:table, "t"}) ==
             {:error,
              ApiError.new(
                :invalid_param,
                ~s(param "max" must be between -2147483648 and 2147483647)
              )}

    {:ok, ep} = endpoint(dataset("BIGINT"))
    assert {:ok, _} = Compiler.compile(ep, %{"max" => "2147483648"}, nil, {:table, "t"})

    assert {:error, %ApiError{family: :invalid_param}} =
             Compiler.compile(ep, %{"max" => "9223372036854775808"}, nil, {:table, "t"})
  end

  test "schemas publish a 32-bit range, and leave 64-bit bounds out", %{ds: ds} do
    {:ok, ep} = endpoint(ds, %{"max" => 500})
    [tool] = Offloader.MCP.tools([ep])

    assert tool.inputSchema.properties["max"] == %{
             type: "integer",
             minimum: -2_147_483_648,
             maximum: 500
           }

    {:ok, ep} = endpoint(dataset("BIGINT"))
    [tool] = Offloader.MCP.tools([ep])
    assert tool.inputSchema.properties["max"] == %{type: "integer"}
  end

  test "an integer default outside its column's range is a config error", %{ds: ds} do
    assert {:error, [error]} = endpoint(ds, %{"default" => 3_000_000_000})
    assert {error.code, error.path} == {:invalid_default, "params[0].default"}
  end
end
