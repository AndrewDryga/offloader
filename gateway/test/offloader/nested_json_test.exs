defmodule Offloader.NestedJsonTest do
  # A dataset column declared `JSON` (a nested STRUCT/MAP/LIST in the snapshot) is
  # served whole: the compiler projects it via to_json and the engine decodes it into
  # a nested term. This is what lets Offloader serve upstream_serving_api-shaped payloads.
  use ExUnit.Case, async: true

  alias Offloader.{Catalog, Compiler}
  alias Offloader.Catalog.{Dataset, Endpoint}

  defp dataset(json_col_type \\ "JSON") do
    {:ok, ds} =
      Dataset.parse(
        %{
          "id" => "champion",
          "manifest" => "m.json",
          "tenant_column" => "tenant",
          "schema" => [
            %{"name" => "tenant", "type" => "VARCHAR"},
            %{"name" => "champion_id", "type" => "VARCHAR"},
            %{"name" => "data", "type" => json_col_type}
          ]
        },
        "datasets/champion.yml"
      )

    ds
  end

  defp endpoint(dataset, select) do
    Endpoint.parse(
      %{
        "name" => "champion",
        "version" => 1,
        "owner" => "team@example.com",
        "dataset" => "champion",
        "tenant" => %{"column" => "tenant"},
        "params" => [%{"name" => "champion_id", "type" => "string", "required" => true}],
        "query" => %{
          "select" => select,
          "filters" => [%{"column" => "champion_id", "op" => "eq", "param" => "champion_id"}]
        },
        "columns" => Enum.map(select, & &1["as"])
      },
      "endpoints/champion.yml",
      dataset
    )
  end

  test "a JSON column is accepted in the dataset schema" do
    assert %Dataset{} = dataset("JSON")
    assert Enum.any?(dataset("JSON").schema, &(&1.name == "data" and &1.type == "JSON"))
  end

  test "a JSON select is marked json? and compiles to a decoded to_json projection" do
    {:ok, ep} =
      endpoint(dataset(), [
        %{"as" => "champion_id", "column" => "champion_id"},
        %{"as" => "data", "column" => "data"}
      ])

    assert Enum.find(ep.select, &(&1.as == "data")).json?
    refute Enum.find(ep.select, &(&1.as == "champion_id")).json?

    {:ok, plan} = Compiler.compile(ep, %{"champion_id" => "1"}, "upstream", {:table, "champion"})

    # the nested column is projected via to_json (not raw) and flagged for decode
    assert plan.sql =~ ~s|to_json("data")::VARCHAR AS "data"|
    assert plan.json_columns == ["data"]
    # a scalar column is projected as-is
    assert plan.sql =~ ~s("champion_id" AS "champion_id")
  end

  test "aggregating a JSON column is rejected at config load" do
    assert {:error, errors} =
             endpoint(dataset(), [
               %{"as" => "champion_id", "column" => "champion_id"},
               %{"as" => "data", "column" => "data", "agg" => "max"}
             ])

    assert Enum.any?(errors, &(&1.code == :invalid_agg_on_json))
  end

  test "the example project still loads (no regression from the JSON type)" do
    project = Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)
    assert {:ok, %Catalog{}} = Catalog.load(project)
  end
end
