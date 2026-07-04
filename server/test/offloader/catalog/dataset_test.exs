defmodule Offloader.Catalog.DatasetTest do
  # Dataset.parse/2 is pure (map in, {:error, [%Error{}]} out). The happy path is exercised
  # elsewhere; here we pin every validation branch — an unsafe id, a bad origin, a bogus
  # source, an off-schema tenant column, and each schema defect — because these are the gate
  # that keeps malformed config out of the compiler.
  use ExUnit.Case, async: true

  alias Offloader.Catalog.Dataset

  defp codes({:error, errors}), do: MapSet.new(errors, & &1.code)
  defp has?(result, code), do: MapSet.member?(codes(result), code)

  defp valid(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "customer_usage",
        "manifest" => "data/customer_usage/manifest.json",
        "tenant_column" => "tenant_id",
        "schema" => [
          %{"name" => "tenant_id", "type" => "VARCHAR"},
          %{"name" => "day", "type" => "DATE"},
          %{"name" => "revenue", "type" => "DOUBLE"}
        ]
      },
      overrides
    )
  end

  describe "parse/2 — happy paths" do
    test "a valid static-manifest dataset parses and fills the struct" do
      assert {:ok, ds} = Dataset.parse(valid(), "datasets/x.yml")
      assert ds.id == "customer_usage"
      assert ds.manifest == "data/customer_usage/manifest.json"
      assert ds.tenant_column == "tenant_id"
      assert MapSet.equal?(ds.columns, MapSet.new(["tenant_id", "day", "revenue"]))
    end

    test "a valid databricks source parses and normalizes the prefix to a trailing slash" do
      raw =
        valid()
        |> Map.delete("manifest")
        |> Map.put("source", %{
          "type" => "databricks",
          "bucket" => "warehouse",
          "prefix" => "exports/customer_usage",
          "interval_seconds" => 3600
        })

      assert {:ok, ds} = Dataset.parse(raw, "x.yml")
      assert ds.manifest == nil

      assert ds.source == %{
               type: "databricks",
               bucket: "warehouse",
               prefix: "exports/customer_usage/",
               interval_seconds: 3600
             }
    end

    test "a dataset without a tenant_column is accepted (public / non-tenant)" do
      assert {:ok, ds} = Dataset.parse(Map.delete(valid(), "tenant_column"), "x.yml")
      assert ds.tenant_column == nil
    end
  end

  describe "parse/2 — id and origin" do
    test "non-map config is rejected without crashing" do
      assert has?(Dataset.parse("nope", "x.yml"), :not_a_map)
    end

    test "a missing or non-binary id is reported" do
      assert has?(Dataset.parse(Map.delete(valid(), "id"), "x.yml"), :missing)
      assert has?(Dataset.parse(valid(%{"id" => 123}), "x.yml"), :missing)
    end

    test "an unsafe id is rejected" do
      assert has?(Dataset.parse(valid(%{"id" => "Bad-Id"}), "x.yml"), :unsafe_identifier)
    end

    test "manifest and source are mutually exclusive" do
      raw = valid(%{"source" => %{"type" => "databricks", "bucket" => "b", "prefix" => "p"}})
      assert has?(Dataset.parse(raw, "x.yml"), :conflicting_origin)
    end

    test "a dataset with neither a manifest nor a source is rejected" do
      raw = valid() |> Map.delete("manifest") |> Map.delete("source")
      assert has?(Dataset.parse(raw, "x.yml"), :missing)
    end

    test "an empty or non-string manifest is an invalid type" do
      assert has?(Dataset.parse(valid(%{"manifest" => ""}), "x.yml"), :invalid_type)
      assert has?(Dataset.parse(valid(%{"manifest" => 123}), "x.yml"), :invalid_type)
    end
  end

  describe "parse/2 — source" do
    defp with_source(source), do: valid() |> Map.delete("manifest") |> Map.put("source", source)

    test "an unknown source.type is rejected" do
      raw = with_source(%{"type" => "redshift", "bucket" => "b", "prefix" => "p"})
      assert has?(Dataset.parse(raw, "x.yml"), :invalid_value)
    end

    test "a source without a bucket or prefix is rejected" do
      raw = with_source(%{"type" => "databricks"})
      assert has?(Dataset.parse(raw, "x.yml"), :missing)
    end

    test "a non-positive interval_seconds is rejected" do
      raw =
        with_source(%{
          "type" => "databricks",
          "bucket" => "b",
          "prefix" => "p",
          "interval_seconds" => -1
        })

      assert has?(Dataset.parse(raw, "x.yml"), :invalid_value)
    end
  end

  describe "parse/2 — tenant_column" do
    test "an unsafe tenant_column identifier is rejected" do
      assert has?(
               Dataset.parse(valid(%{"tenant_column" => "bad-name"}), "x.yml"),
               :unsafe_identifier
             )
    end

    test "a tenant_column not present in the schema is rejected" do
      assert has?(Dataset.parse(valid(%{"tenant_column" => "ghost"}), "x.yml"), :unknown_column)
    end

    test "a non-string tenant_column is an invalid type" do
      assert has?(Dataset.parse(valid(%{"tenant_column" => 123}), "x.yml"), :invalid_type)
    end
  end

  describe "parse/2 — schema" do
    defp schema_only(cols), do: valid() |> Map.delete("tenant_column") |> Map.put("schema", cols)

    test "a missing, empty, or non-list schema is rejected" do
      assert has?(Dataset.parse(Map.delete(valid(), "schema"), "x.yml"), :missing)
      assert has?(Dataset.parse(schema_only([]), "x.yml"), :missing)
      assert has?(Dataset.parse(schema_only("nope"), "x.yml"), :missing)
    end

    test "a schema column without a safe name is rejected" do
      assert has?(
               Dataset.parse(schema_only([%{"type" => "VARCHAR"}]), "x.yml"),
               :unsafe_identifier
             )
    end

    test "a schema column with an unsupported type is rejected" do
      assert has?(
               Dataset.parse(schema_only([%{"name" => "x", "type" => "BLOB"}]), "x.yml"),
               :unsupported_type
             )
    end

    test "duplicate column names are rejected" do
      cols = [%{"name" => "day", "type" => "DATE"}, %{"name" => "day", "type" => "DATE"}]
      assert has?(Dataset.parse(schema_only(cols), "x.yml"), :duplicate_column)
    end
  end
end
