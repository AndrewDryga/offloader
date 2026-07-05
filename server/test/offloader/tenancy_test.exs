defmodule Offloader.TenancyTest do
  # Optional tenancy + optional auth. A dataset without tenant_column is public: its
  # endpoints bind no tenant and the compiler emits no tenant filter. `auth: none` is
  # accepted only when no endpoint is tenant-scoped.
  use ExUnit.Case, async: true

  alias Offloader.{Catalog, Compiler}
  alias Offloader.Catalog.{Dataset, Endpoint}

  defp tenant_dataset do
    {:ok, ds} =
      Dataset.parse(
        %{
          "id" => "usage",
          "manifest" => "m.json",
          "tenant_column" => "tenant_id",
          "schema" => [
            %{"name" => "tenant_id", "type" => "VARCHAR"},
            %{"name" => "account_id", "type" => "VARCHAR"}
          ]
        },
        "datasets/usage.yml"
      )

    ds
  end

  defp public_dataset do
    {:ok, ds} =
      Dataset.parse(
        %{
          "id" => "champ",
          "manifest" => "m.json",
          "schema" => [
            %{"name" => "champion_id", "type" => "VARCHAR"},
            %{"name" => "patch", "type" => "VARCHAR"}
          ]
        },
        "datasets/champ.yml"
      )

    ds
  end

  defp public_endpoint(overrides \\ %{}) do
    base = %{
      "name" => "champ",
      "version" => 1,
      "owner" => "team@example.com",
      "dataset" => "champ",
      "params" => [%{"name" => "champion_id", "type" => "string", "required" => true}],
      "query" => %{
        "select" => [
          %{"as" => "champion_id", "column" => "champion_id"},
          %{"as" => "patch", "column" => "patch"}
        ],
        "filters" => [%{"column" => "patch", "op" => "eq", "param" => "champion_id"}]
      },
      "columns" => ["champion_id", "patch"]
    }

    Endpoint.parse(Map.merge(base, overrides), "endpoints/champ.yml", public_dataset())
  end

  describe "dataset" do
    test "tenant_column is optional; absent => non-tenant dataset" do
      assert public_dataset().tenant_column == nil
      assert tenant_dataset().tenant_column == "tenant_id"
    end
  end

  describe "endpoint tenant binding" do
    test "a non-tenant dataset endpoint needs no tenant binding" do
      assert {:ok, ep} = public_endpoint()
      assert ep.tenant_column == nil
    end

    test "binding a tenant on a non-tenant dataset is rejected" do
      assert {:error, errors} = public_endpoint(%{"tenant" => %{"column" => "champion_id"}})
      assert Enum.any?(errors, &(&1.code == :tenant_forbidden))
    end

    test "a tenant dataset endpoint still requires its binding" do
      raw = %{
        "name" => "usage",
        "version" => 1,
        "owner" => "t@example.com",
        "dataset" => "usage",
        "params" => [],
        "query" => %{"select" => [%{"as" => "account_id", "column" => "account_id"}]},
        "columns" => ["account_id"]
      }

      assert {:error, errors} = Endpoint.parse(raw, "endpoints/usage.yml", tenant_dataset())
      assert Enum.any?(errors, &(&1.code == :missing))
    end
  end

  describe "compiler (non-tenant)" do
    test "emits no tenant filter and starts filters at $1" do
      {:ok, ep} = public_endpoint()
      {:ok, plan} = Compiler.compile(ep, %{"champion_id" => "16.13"}, nil, {:table, "champ"})

      refute plan.sql =~ "tenant"
      # the one request filter is $1 (not $2), and there is no tenant param.
      # Filters compare the raw column (no CAST) so DuckDB zone maps prune.
      assert plan.sql =~ ~s|"patch" = $1|
      assert hd(plan.params) == "16.13"
    end

    test "a non-tenant endpoint with no active filters emits no WHERE clause" do
      # optional param, absent => its filter is not applied => no WHERE at all
      {:ok, ep} =
        public_endpoint(%{
          "params" => [%{"name" => "champion_id", "type" => "string", "required" => false}]
        })

      {:ok, plan} = Compiler.compile(ep, %{}, nil, {:table, "champ"})
      refute plan.sql =~ "WHERE"
      assert plan.sql =~ "LIMIT"
    end
  end

  describe "catalog auth mode" do
    test "the public example loads with auth_mode none and a non-tenant dataset" do
      project = Path.expand("../../../examples/public-metrics/offloader.yml", __DIR__)
      assert {:ok, cat} = Catalog.load(project)
      assert cat.auth_mode == "none"
      assert cat.datasets["champion_stats"].tenant_column == nil
    end

    test "the tenant example still defaults to auth_mode required" do
      project = Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)
      assert {:ok, cat} = Catalog.load(project)
      assert cat.auth_mode == "required"
    end
  end
end
