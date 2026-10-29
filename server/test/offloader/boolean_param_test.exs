defmodule Offloader.BooleanParamTest do
  # A `boolean` param filters a BOOLEAN column: it accepts exactly `true` and `false`, binds as a
  # boolean, and compares with `eq` only.
  use ExUnit.Case, async: false

  alias Offloader.{ApiError, Catalog, Compiler, Docs, Engine, Manifest, MCP}
  alias Offloader.Catalog.{Dataset, Endpoint}

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_bool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, db} = Duckdbex.open()
    {:ok, conn} = Duckdbex.connection(db)

    {:ok, _} =
      Duckdbex.query(conn, """
      COPY (SELECT * FROM (VALUES ('a', true), ('b', false), ('c', NULL)) t(id, active))
      TO '#{dir}/items.parquet' (FORMAT parquet)
      """)

    {:ok, eng} = Engine.start_link(cache_dir: Path.join(dir, "cache"), pool_size: 1)

    manifest = %Manifest{
      dataset_id: "items",
      snapshot_id: "s1",
      created_at: "2026-10-28T00:00:00Z",
      watermark: "2026-10-28T00:00:00Z",
      schema: [],
      files: [%{"path" => "items.parquet", "format" => "parquet"}],
      dir: dir
    }

    {:ok, _} = Engine.materialize(eng, "items", manifest)

    on_exit(fn ->
      if Process.alive?(eng), do: Engine.stop(eng)
      File.rm_rf!(dir)
    end)

    {:ok, ds} =
      Dataset.parse(
        %{
          "id" => "items",
          "manifest" => "m.json",
          "schema" => [
            %{"name" => "id", "type" => "VARCHAR"},
            %{"name" => "active", "type" => "BOOLEAN"}
          ]
        },
        "datasets/items.yml"
      )

    %{eng: eng, ds: ds}
  end

  defp endpoint(ds, param \\ %{}, filter \\ %{}) do
    Endpoint.parse(
      %{
        "name" => "items",
        "version" => 1,
        "owner" => "t@example.com",
        "dataset" => "items",
        "params" => [Map.merge(%{"name" => "active", "type" => "boolean"}, param)],
        "query" => %{
          "select" => [%{"as" => "id", "column" => "id"}],
          "filters" => [
            Map.merge(%{"column" => "active", "op" => "eq", "param" => "active"}, filter)
          ],
          "order_by" => [%{"column" => "id", "dir" => "asc"}]
        },
        "columns" => ["id"]
      },
      "endpoints/items.yml",
      ds
    )
  end

  defp ids(eng, ep, params) do
    with {:ok, plan} <- Compiler.compile(ep, params, nil, {:table, "items"}),
         {:ok, %{rows: rows}} <- Engine.execute(eng, plan.sql, plan.params) do
      {:ok, List.flatten(rows)}
    end
  end

  test "true and false filter a BOOLEAN column", %{eng: eng, ds: ds} do
    {:ok, ep} = endpoint(ds)
    assert ids(eng, ep, %{"active" => "true"}) == {:ok, ["a"]}
    assert ids(eng, ep, %{"active" => "false"}) == {:ok, ["b"]}
    assert ids(eng, ep, %{}) == {:ok, ["a", "b", "c"]}
  end

  test "any other value is a 422 that names the accepted values", %{eng: eng, ds: ds} do
    {:ok, ep} = endpoint(ds)

    for bad <- ["TRUE", "1", "yes", ""] do
      assert {:error, %ApiError{} = error} = ids(eng, ep, %{"active" => bad})
      assert error == ApiError.new(:invalid_param, ~s(param "active" must be true or false))
    end
  end

  test "a default must be a YAML boolean, and applies when the param is omitted", %{
    eng: eng,
    ds: ds
  } do
    {:ok, ep} = endpoint(ds, %{"default" => false})
    assert ids(eng, ep, %{}) == {:ok, ["b"]}

    assert {:error, [error]} = endpoint(ds, %{"default" => "false"})
    assert {error.code, error.path} == {:invalid_default, "params[0].default"}
  end

  test "a boolean param compares with eq only", %{ds: ds} do
    assert {:error, [error]} = endpoint(ds, %{}, %{"op" => "gte"})
    assert {error.code, error.path} == {:incompatible_filter, "query.filters[0].op"}
    assert error.hint == "boolean params filter with op: eq"
  end

  test "MCP and OpenAPI describe the param as a boolean", %{ds: ds} do
    {:ok, ep} = endpoint(ds)

    [tool] = MCP.tools([ep])
    assert tool.inputSchema.properties["active"] == %{type: "boolean"}

    catalog = %Catalog{
      config_dir: ".",
      datasets: %{"items" => ds},
      endpoints: %{"items" => ep},
      keys: [],
      auth_mode: "none"
    }

    params = get_in(Docs.openapi(catalog), [:paths, "/v1/endpoints/items", :get, :parameters])
    assert %{schema: %{type: "boolean"}} = Enum.find(params, &(&1.name == "active"))
  end
end
