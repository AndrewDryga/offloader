defmodule Offloader.Catalog.EndpointTest do
  use ExUnit.Case, async: true

  alias Offloader.Catalog.{Dataset, Endpoint}

  setup do
    {:ok, dataset} =
      Dataset.parse(
        %{
          "id" => "customer_usage",
          "manifest" => "m.json",
          "tenant_column" => "tenant_id",
          "schema" => [
            %{"name" => "tenant_id", "type" => "VARCHAR"},
            %{"name" => "account_id", "type" => "VARCHAR"},
            %{"name" => "usage_date", "type" => "DATE"},
            %{"name" => "api_calls", "type" => "BIGINT"}
          ]
        },
        "datasets/customer_usage.yml"
      )

    %{dataset: dataset}
  end

  defp valid do
    %{
      "name" => "usage_summary",
      "version" => 1,
      "owner" => "team@example.com",
      "dataset" => "customer_usage",
      "tenant" => %{"column" => "tenant_id"},
      "params" => [
        %{"name" => "account_id", "type" => "string", "required" => false},
        %{"name" => "from", "type" => "date", "required" => true},
        %{"name" => "to", "type" => "date", "required" => true}
      ],
      "query" => %{
        "group_by" => ["account_id"],
        "select" => [
          %{"as" => "account_id", "column" => "account_id"},
          %{"as" => "api_calls_total", "column" => "api_calls", "agg" => "sum"}
        ],
        "filters" => [
          %{"column" => "account_id", "op" => "eq", "param" => "account_id"},
          %{"column" => "usage_date", "op" => "gte", "param" => "from"},
          %{"column" => "usage_date", "op" => "lte", "param" => "to"}
        ],
        "order_by" => [%{"column" => "api_calls_total", "dir" => "desc"}]
      },
      "columns" => ["account_id", "api_calls_total"],
      "pagination" => %{"default_limit" => 50, "max_limit" => 100},
      "cache" => %{"policy" => "snapshot"}
    }
  end

  defp codes(raw, dataset) do
    {:error, errors} = Endpoint.parse(raw, "endpoints/e.yml", dataset)
    MapSet.new(errors, & &1.code)
  end

  test "the happy path validates into a typed struct", %{dataset: dataset} do
    assert {:ok, ep} = Endpoint.parse(valid(), "endpoints/e.yml", dataset)
    assert ep.name == "usage_summary"
    assert ep.serving_mode == "local_table"
    assert ep.tenant_column == "tenant_id"
    assert ep.columns == ["account_id", "api_calls_total"]
    assert Enum.map(ep.params, & &1.name) == ["account_id", "from", "to"]
    assert [%{column: "api_calls_total", dir: "desc"}] = ep.order_by
  end

  test "every error carries a file and a field path", %{dataset: dataset} do
    raw = Map.put(valid(), "surprise", true)
    {:error, [err | _]} = Endpoint.parse(raw, "endpoints/e.yml", dataset)
    assert err.file == "endpoints/e.yml"
    assert is_binary(err.path)
    assert is_atom(err.code)
  end

  test "rejects unknown top-level fields", %{dataset: dataset} do
    assert :unknown_field in codes(Map.put(valid(), "wat", 1), dataset)
  end

  test "rejects an unsafe endpoint name", %{dataset: dataset} do
    assert :unsafe_identifier in codes(Map.put(valid(), "name", "Drop Table"), dataset)
  end

  test "rejects a projection over a column not in the dataset", %{dataset: dataset} do
    raw = put_in(valid(), ["query", "select"], [%{"as" => "x", "column" => "ssn"}])
    assert :unknown_column in codes(raw, dataset)
  end

  test "rejects tenant.column that is not the dataset tenant column", %{dataset: dataset} do
    raw = put_in(valid(), ["tenant", "column"], "account_id")
    assert :tenant_mismatch in codes(raw, dataset)
  end

  test "rejects a filter bound to an undeclared param", %{dataset: dataset} do
    raw =
      put_in(valid(), ["query", "filters"], [
        %{"column" => "usage_date", "op" => "gte", "param" => "nope"}
      ])

    assert :unknown_param in codes(raw, dataset)
  end

  test "rejects a filter that targets the tenant column (no request-side tenant control)", %{
    dataset: dataset
  } do
    raw =
      put_in(valid(), ["query", "filters"], [
        %{"column" => "tenant_id", "op" => "eq", "param" => "from"}
      ])

    assert :tenant_filter_forbidden in codes(raw, dataset)
  end

  test "rejects an output column outside the allowlist", %{dataset: dataset} do
    raw = Map.put(valid(), "columns", ["account_id"])
    assert :column_not_allowlisted in codes(raw, dataset)
  end

  test "rejects an allowlist column the select never produces", %{dataset: dataset} do
    raw = Map.put(valid(), "columns", ["account_id", "api_calls_total", "ghost"])
    assert :column_not_selected in codes(raw, dataset)
  end

  test "rejects aggregation without group_by", %{dataset: dataset} do
    raw = put_in(valid(), ["query", "group_by"], [])
    assert :missing_group_by in codes(raw, dataset)
  end

  test "rejects a non-aggregated select column that is not grouped", %{dataset: dataset} do
    raw =
      valid()
      |> put_in(["query", "select"], [
        %{"as" => "account_id", "column" => "account_id"},
        %{"as" => "usage_date", "column" => "usage_date"},
        %{"as" => "api_calls_total", "column" => "api_calls", "agg" => "sum"}
      ])
      |> Map.put("columns", ["account_id", "usage_date", "api_calls_total"])

    assert :ungrouped_column in codes(raw, dataset)
  end

  test "rejects default_limit greater than max_limit", %{dataset: dataset} do
    raw = Map.put(valid(), "pagination", %{"default_limit" => 200, "max_limit" => 100})
    assert :invalid_value in codes(raw, dataset)
  end

  test "rejects an invalid serving_mode and cache policy", %{dataset: dataset} do
    raw = valid() |> Map.put("serving_mode", "warp") |> put_in(["cache", "policy"], "forever")
    cs = codes(raw, dataset)
    assert :invalid_value in cs
  end

  test "rejects an enum param with no values", %{dataset: dataset} do
    raw = update_in(valid(), ["params"], &[%{"name" => "area", "type" => "enum"} | &1])
    assert :missing in codes(raw, dataset)
  end

  test "collects multiple errors in one pass", %{dataset: dataset} do
    raw =
      valid()
      |> Map.put("name", "BAD NAME")
      |> Map.put("wat", 1)
      |> put_in(["tenant", "column"], "account_id")

    {:error, errors} = Endpoint.parse(raw, "endpoints/e.yml", dataset)
    assert length(errors) >= 3
  end
end
