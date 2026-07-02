defmodule Offloader.CompilerTest do
  use ExUnit.Case, async: true

  alias Offloader.{ApiError, Catalog, Compiler}

  @project Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)

  setup do
    {:ok, cat} = Catalog.load(@project)
    %{cat: cat}
  end

  defp compile(cat, name, params, tenant \\ "tenant_acme") do
    Compiler.compile(cat.endpoints[name], params, tenant, {:table, "customer_usage"})
  end

  test "compiles a valid request into a parameterized plan with the tenant as $1", %{cat: cat} do
    assert {:ok, plan} =
             compile(cat, "customer_usage_summary", %{
               "from" => "2026-05-30",
               "to" => "2026-06-01"
             })

    assert plan.sql =~ ~s("tenant_id" = $1)
    assert hd(plan.params) == "tenant_acme"
    assert plan.sql =~ "GROUP BY"
    assert plan.sql =~ "LIMIT"

    assert plan.columns == [
             "account_id",
             "active_users_total",
             "api_calls_total",
             "storage_gb_avg"
           ]

    # the tenant value never appears as a literal in the SQL
    refute plan.sql =~ "tenant_acme"
  end

  test "aggregates are cast so responses are plain integers/floats, not hugeints", %{cat: cat} do
    {:ok, plan} =
      compile(cat, "customer_usage_summary", %{"from" => "2026-05-30", "to" => "2026-06-01"})

    assert plan.sql =~ "sum(\"api_calls\")::BIGINT"
    assert plan.sql =~ "avg(\"storage_gb\")::DOUBLE"
  end

  test "rejects an unknown param (blocks tenant smuggling)", %{cat: cat} do
    assert {:error, %ApiError{family: :invalid_param}} =
             compile(cat, "customer_usage_summary", %{
               "from" => "2026-05-30",
               "to" => "2026-06-01",
               "tenant_id" => "x"
             })
  end

  test "rejects a missing required param", %{cat: cat} do
    assert {:error, %ApiError{family: :invalid_param}} =
             compile(cat, "customer_usage_summary", %{"from" => "2026-05-30"})
  end

  test "rejects a non-date value for a date param", %{cat: cat} do
    assert {:error, %ApiError{family: :invalid_param}} =
             compile(cat, "customer_usage_summary", %{"from" => "yesterday", "to" => "2026-06-01"})
  end

  test "rejects an enum value outside the allowed set", %{cat: cat} do
    params = %{
      "account_id" => "a",
      "from" => "2026-05-30",
      "to" => "2026-06-01",
      "product_area" => "billing"
    }

    assert {:error, %ApiError{family: :invalid_param}} =
             compile(cat, "customer_usage_daily", params)
  end

  test "rejects a limit over the endpoint max", %{cat: cat} do
    params = %{"from" => "2026-05-30", "to" => "2026-06-01", "limit" => "999"}

    assert {:error, %ApiError{family: :invalid_param}} =
             compile(cat, "top_accounts_by_usage", params)
  end

  test "an omitted optional filter is simply not applied", %{cat: cat} do
    # customer_usage_summary's account_id filter is optional; omitting it must still compile.
    assert {:ok, plan} =
             compile(cat, "customer_usage_summary", %{
               "from" => "2026-05-30",
               "to" => "2026-06-01"
             })

    refute plan.sql =~ ~s("account_id" =)
  end
end
