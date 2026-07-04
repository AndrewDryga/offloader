defmodule Offloader.DocsTest do
  use ExUnit.Case, async: true

  alias Offloader.{Catalog, Docs}

  @public Path.expand("../../../examples/public-metrics/offloader.yml", __DIR__)
  @tenant Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)

  test "schema/1 reflects a public project: auth none and a public endpoint" do
    {:ok, cat} = Catalog.load(@public)
    schema = Docs.schema(cat)

    assert schema.auth.mode == "none"
    champion = Enum.find(schema.endpoints, &(&1.name == "champion"))
    assert champion.public == true
    assert champion.tenant_scoped == false

    # the nested `data` column is flagged nested; scalars are not
    data_col = Enum.find(champion.response_columns, &(&1.name == "data"))
    assert data_col.nested == true
    assert Enum.find(champion.response_columns, &(&1.name == "champion_id")).nested == false
  end

  test "schema/1 reflects a tenant project: auth required and tenant-scoped endpoints" do
    {:ok, cat} = Catalog.load(@tenant)
    schema = Docs.schema(cat)

    assert schema.auth.mode == "required"
    assert schema.auth.scheme == "bearer"
    assert Enum.all?(schema.endpoints, & &1.tenant_scoped)
  end

  test "catalog/1 auth note matches the mode" do
    {:ok, public} = Catalog.load(@public)
    {:ok, tenant} = Catalog.load(@tenant)

    assert Docs.catalog(public).auth.mode == "none"
    assert Docs.catalog(public).auth.note =~ "public"
    assert Docs.catalog(tenant).auth.scheme == "bearer"
  end
end
