defmodule OffloaderWeb.DocsHTTPTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest

  alias Offloader.Runtime

  @endpoint OffloaderWeb.AdminEndpoint
  @project Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_docs_#{System.unique_integer([:positive])}")
    {:ok, rt} = Runtime.start_link(name: Runtime, config_path: @project, cache_dir: dir)

    on_exit(fn ->
      if Process.alive?(rt), do: GenServer.stop(rt)
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "GET /openapi.json returns an OpenAPI spec for every endpoint" do
    spec = json_response(get(build_conn(), "/openapi.json"), 200)
    assert spec["openapi"] == "3.0.3"
    assert get_in(spec, ["components", "securitySchemes", "bearerAuth", "scheme"]) == "bearer"

    for name <- ["customer_usage_summary", "customer_usage_daily", "top_accounts_by_usage"] do
      assert Map.has_key?(spec["paths"], "/v1/endpoints/#{name}")
    end

    # enum param surfaces in the spec
    params = get_in(spec, ["paths", "/v1/endpoints/customer_usage_daily", "get", "parameters"])
    product_area = Enum.find(params, &(&1["name"] == "product_area"))
    assert product_area["schema"]["enum"] == ["dashboards", "api", "exports"]
  end

  test "GET /docs returns a catalog with contract-accurate details and snippets" do
    catalog = json_response(get(build_conn(), "/docs"), 200)
    assert catalog["auth"]["scheme"] == "bearer"

    summary = Enum.find(catalog["endpoints"], &(&1["name"] == "customer_usage_summary"))
    assert summary["method"] == "GET"
    assert summary["path"] == "/v1/endpoints/customer_usage_summary"
    assert summary["auth"]["tenant"] =~ "bound to the API key"
    assert summary["pagination"]["max_limit"] == 100

    assert summary["response"]["columns"] == [
             "account_id",
             "active_users_total",
             "api_calls_total",
             "storage_gb_avg"
           ]

    assert summary["freshness_minutes"] == 120

    # error families are documented
    families = Enum.map(summary["errors"], & &1["family"])
    assert "invalid_param" in families and "not_found" in families

    # snippets for all three languages, with the endpoint path and bearer auth
    assert summary["snippets"]["curl"] =~ "Authorization: Bearer"
    assert summary["snippets"]["curl"] =~ "/v1/endpoints/customer_usage_summary"
    assert summary["snippets"]["typescript"] =~ "fetch("
    assert summary["snippets"]["python"] =~ "requests.get"
  end

  test "docs describe params exactly as the endpoint declares them" do
    catalog = json_response(get(build_conn(), "/docs"), 200)
    daily = Enum.find(catalog["endpoints"], &(&1["name"] == "customer_usage_daily"))
    area = Enum.find(daily["params"], &(&1["name"] == "product_area"))
    assert area["type"] == "enum"
    assert area["enum"] == ["dashboards", "api", "exports"]
    # the built-in pagination params are documented too
    assert Enum.any?(daily["params"], &(&1["name"] == "limit"))
  end

  test "GET /schema returns a compact client schema of every endpoint" do
    schema = json_response(get(build_conn(), "/schema"), 200)
    assert schema["service"] == "offloader"
    assert schema["auth"]["mode"] == "required"
    assert schema["count"] == length(schema["endpoints"])

    summary = Enum.find(schema["endpoints"], &(&1["name"] == "customer_usage_summary"))
    assert summary["path"] == "/v1/endpoints/customer_usage_summary"
    assert summary["method"] == "GET"
    assert summary["tenant_scoped"] == true
    assert summary["public"] == false
    assert summary["pagination"]["max_limit"] == 100

    # response columns are listed with a nested flag; these are all scalar
    names = Enum.map(summary["response_columns"], & &1["name"])
    assert "api_calls_total" in names
    assert Enum.all?(summary["response_columns"], &(&1["nested"] == false))

    # filters are exposed so a client knows what it can filter on
    assert Enum.any?(summary["filters"], &(&1["column"] == "usage_date"))
  end
end
