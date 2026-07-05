defmodule Offloader.CatalogTest do
  use ExUnit.Case, async: true

  alias Offloader.Catalog

  @example Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)

  describe "loading the real example project" do
    test "loads datasets, endpoints, and keys" do
      assert {:ok, cat} = Catalog.load(@example)
      assert Map.keys(cat.datasets) == ["customer_usage"]

      assert Enum.sort(Map.keys(cat.endpoints)) ==
               ["customer_usage_daily", "customer_usage_summary", "top_accounts_by_usage"]

      assert Enum.map(cat.keys, & &1.id) == ["demo_acme", "demo_globex", "demo_revoked"]
    end

    test "endpoints reference a real dataset and bind the dataset's tenant column" do
      {:ok, cat} = Catalog.load(@example)

      for {_name, ep} <- cat.endpoints do
        assert Map.has_key?(cat.datasets, ep.dataset)
        assert ep.tenant_column == cat.datasets[ep.dataset].tenant_column
      end
    end

    test "derives sort_columns per dataset: tenant column first, then endpoint filter columns" do
      {:ok, cat} = Catalog.load(@example)
      sort = cat.datasets["customer_usage"].sort_columns

      # tenant column leads (every tenant query filters it) so the table's zone maps prune by tenant
      assert List.first(sort) == "tenant_id"
      # the endpoints' filter columns are included — materialize ORDER BYs them for pruning
      assert "usage_date" in sort
      assert "account_id" in sort
    end
  end

  describe "loader-level validation" do
    test "reports an endpoint that references an unknown dataset" do
      project =
        write_project(%{
          "offloader.yml" => "version: 1\ndatasets_dir: datasets\nendpoints_dir: endpoints\n",
          "datasets/customer_usage.yml" => dataset_yaml(),
          "endpoints/e.yml" =>
            endpoint_yaml() |> String.replace("dataset: customer_usage", "dataset: nope")
        })

      assert {:error, errors} = Catalog.load(project)
      assert :unknown_dataset in Enum.map(errors, & &1.code)
    end

    test "reports duplicate endpoint names across files" do
      project =
        write_project(%{
          "offloader.yml" => "version: 1\ndatasets_dir: datasets\nendpoints_dir: endpoints\n",
          "datasets/customer_usage.yml" => dataset_yaml(),
          "endpoints/a.yml" => endpoint_yaml(),
          "endpoints/b.yml" => endpoint_yaml()
        })

      assert {:error, errors} = Catalog.load(project)
      assert :duplicate_endpoint in Enum.map(errors, & &1.code)
    end

    test "auth: none is rejected while any endpoint is tenant-scoped" do
      # THE public-mode gate: the one validation standing between `auth: none` and
      # serving multi-tenant data unauthenticated. ApiAuth's docs lean on it by name.
      project =
        write_project(%{
          "offloader.yml" =>
            "version: 1\nauth: none\ndatasets_dir: datasets\nendpoints_dir: endpoints\n",
          "datasets/customer_usage.yml" => dataset_yaml(),
          "endpoints/e.yml" => endpoint_yaml()
        })

      assert {:error, errors} = Catalog.load(project)
      assert :public_tenant_endpoint in Enum.map(errors, & &1.code)
    end

    test "reports a key that grants an unknown endpoint" do
      project =
        write_project(%{
          "offloader.yml" =>
            "version: 1\ndatasets_dir: datasets\nendpoints_dir: endpoints\nkeys: keys/keys.yml\n",
          "datasets/customer_usage.yml" => dataset_yaml(),
          "endpoints/e.yml" => endpoint_yaml(),
          "keys/keys.yml" => """
          keys:
            - id: k1
              hash: "#{String.duplicate("a", 64)}"
              tenant: tenant_acme
              endpoints: [does_not_exist]
              status: active
          """
        })

      assert {:error, errors} = Catalog.load(project)
      assert :unknown_endpoint in Enum.map(errors, & &1.code)
    end

    test "reports a malformed manifest reference as a YAML/parse error, not a crash" do
      project =
        write_project(%{
          "offloader.yml" => "version: 1\ndatasets_dir: datasets\nendpoints_dir: endpoints\n",
          "datasets/bad.yml" => "id: [this, is, not, a, dataset\n"
        })

      assert {:error, errors} = Catalog.load(project)
      assert :yaml_error in Enum.map(errors, & &1.code)
    end

    test "rejects an unknown top-level field in offloader.yml" do
      project = write_project(%{"offloader.yml" => "version: 1\nsurprise: true\n"})
      assert {:error, [%{code: :unknown_field}]} = Catalog.load(project)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────────

  defp write_project(files) do
    root = Path.join(System.tmp_dir!(), "offl_cat_#{System.unique_integer([:positive])}")

    Enum.each(files, fn {rel, content} ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    on_exit(fn -> File.rm_rf!(root) end)
    Path.join(root, "offloader.yml")
  end

  defp dataset_yaml do
    """
    id: customer_usage
    manifest: data/customer_usage/manifest.json
    tenant_column: tenant_id
    schema:
      - { name: tenant_id, type: VARCHAR }
      - { name: account_id, type: VARCHAR }
      - { name: usage_date, type: DATE }
      - { name: api_calls, type: BIGINT }
    """
  end

  defp endpoint_yaml do
    """
    name: usage_summary
    version: 1
    owner: team@example.com
    dataset: customer_usage
    tenant:
      column: tenant_id
    params:
      - { name: from, type: date, required: true }
      - { name: to, type: date, required: true }
    query:
      group_by: [account_id]
      select:
        - { as: account_id, column: account_id }
        - { as: api_calls_total, column: api_calls, agg: sum }
      filters:
        - { column: usage_date, op: gte, param: from }
        - { column: usage_date, op: lte, param: to }
      order_by:
        - { column: api_calls_total, dir: desc }
    columns: [account_id, api_calls_total]
    pagination:
      default_limit: 50
      max_limit: 100
    cache:
      policy: snapshot
    """
  end
end
