defmodule Offloader.ManifestTest do
  use ExUnit.Case, async: true

  alias Offloader.{Catalog, Manifest}

  @dir Path.expand("../../../examples/customer-analytics", __DIR__)
  @valid Path.join(@dir, "data/customer_usage/manifest.json")
  @fl Path.join(@dir, "failure-lab")
  @project Path.join(@dir, "offloader.yml")

  defp codes({:error, errors}), do: MapSet.new(errors, & &1.code)

  defp dataset do
    {:ok, cat} = Catalog.load(@project)
    cat.datasets["customer_usage"]
  end

  describe "load/1" do
    test "accepts the valid fixture and fills the struct" do
      assert {:ok, m} = Manifest.load(@valid)
      assert m.dataset_id == "customer_usage"
      assert m.row_count == 36
      assert m.compatibility_policy == "additive_only"
      assert MapSet.member?(m.columns, "api_calls")
    end

    test "rejects a thoroughly bad manifest with one error per defect" do
      cs = codes(Manifest.load(Path.join(@fl, "bad-manifest/manifest.json")))
      assert :invalid_snapshot_id in cs
      assert :duplicate_column in cs
      assert :unsupported_type in cs
      # missing `producer`
      assert :missing in cs
    end

    test "rejects a manifest that references a file that does not exist" do
      assert :missing_file in codes(Manifest.load(Path.join(@fl, "missing-file/manifest.json")))
    end

    test "a remote file URL is trusted (not stat'd), so no missing_file error" do
      manifest = %{
        "dataset_id" => "customer_usage",
        "snapshot_id" => "remote_r1",
        "created_at" => "2026-07-01T00:00:00Z",
        "watermark" => "2026-07-01T00:00:00Z",
        "schema" => [%{"name" => "tenant_id", "type" => "VARCHAR"}],
        "files" => [%{"path" => "s3://bucket/customer_usage.parquet", "format" => "parquet"}],
        "partition_columns" => [],
        "sort_columns" => [],
        "row_count" => 1,
        "size_bytes" => 1,
        "producer" => "p",
        "upstream_run_id" => "r1",
        "schema_version" => 1,
        "data_quality_status" => "passed",
        "compatibility_policy" => "additive_only"
      }

      path =
        Path.join(System.tmp_dir!(), "remote_manifest_#{System.unique_integer([:positive])}.json")

      File.write!(path, Jason.encode!(manifest))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, m} = Manifest.load(path)
      assert hd(m.files)["path"] == "s3://bucket/customer_usage.parquet"
    end

    test "a stale but well-formed manifest is structurally VALID (staleness is a freshness concern)" do
      assert {:ok, _} = Manifest.load(Path.join(@fl, "stale-dataset/manifest.json"))
    end

    test "every error carries a file and a field path" do
      {:error, [err | _]} = Manifest.load(Path.join(@fl, "bad-manifest/manifest.json"))
      assert is_binary(err.file)
      assert is_binary(err.path)
      assert is_atom(err.code)
    end

    test "rejects invalid JSON, not a crash" do
      assert :invalid_json in codes(Manifest.load(write_tmp("{not json", "m.json")))
    end

    test "rejects a bad compatibility_policy" do
      raw = valid_map() |> Map.put("compatibility_policy", "yolo")
      assert :invalid_compatibility_policy in codes(load_map(raw))
    end

    test "rejects a CSV whose header does not match the declared schema" do
      root = tmp_root()
      File.mkdir_p!(root)
      File.write!(Path.join(root, "data.csv"), "a,b,c\n1,2,3\n")

      raw =
        valid_map()
        |> Map.put("files", [%{"path" => "data.csv", "format" => "csv"}])

      path = Path.join(root, "m.json")
      File.write!(path, Jason.encode!(raw))
      on_exit(fn -> File.rm_rf!(root) end)

      assert :schema_data_mismatch in codes(Manifest.load(path))
    end
  end

  describe "load/1 — field validation" do
    test "a manifest whose top-level JSON is not an object is rejected, not crashed" do
      assert MapSet.member?(codes(Manifest.load(write_tmp("[1,2,3]", "m.json"))), :invalid_type)
    end

    test "wrong-typed top-level fields each become a stable error, not a crash" do
      raw =
        valid_map()
        |> Map.merge(%{
          "snapshot_id" => 123,
          "created_at" => "not-a-timestamp",
          "row_count" => -1,
          "schema_version" => 0,
          "producer" => 123,
          "partition_columns" => "not-a-list"
        })

      c = codes(load_map(raw))
      assert MapSet.member?(c, :invalid_snapshot_id)
      assert MapSet.member?(c, :invalid_timestamp)
      assert MapSet.member?(c, :invalid_value)
      assert MapSet.member?(c, :invalid_type)
    end

    test "a schema entry that is not an object is rejected" do
      assert MapSet.member?(codes(load_map(Map.put(valid_map(), "schema", [123]))), :invalid_type)
    end

    test "a files entry that is not an object, or missing its path, is rejected" do
      assert MapSet.member?(codes(load_map(Map.put(valid_map(), "files", ["x"]))), :invalid_type)

      no_path = Map.put(valid_map(), "files", [%{"format" => "csv"}])
      assert MapSet.member?(codes(load_map(no_path)), :missing)
    end

    test "partition_columns referencing a column not in the schema is rejected" do
      raw = Map.put(valid_map(), "partition_columns", ["ghost_column"])
      assert MapSet.member?(codes(load_map(raw)), :unknown_column)
    end
  end

  describe "compatibility/2" do
    test "the valid snapshot is compatible with the dataset contract" do
      {:ok, m} = Manifest.load(@valid)
      assert :ok = Manifest.compatibility(m, dataset())
    end

    test "a narrowed column (BIGINT -> INTEGER) is a breaking, incompatible change" do
      {:ok, m} = Manifest.load(Path.join(@fl, "unsupported-schema-change/manifest.json"))
      assert {:error, errors} = Manifest.compatibility(m, dataset())
      assert :incompatible_schema in Enum.map(errors, & &1.code)
    end

    test "a dropped/renamed contract column is incompatible" do
      # compatibility/2 is pure — build a snapshot that is missing a contract column.
      m = %Manifest{
        dataset_id: "customer_usage",
        snapshot_id: "s1",
        created_at: "2026-06-01T00:00:00Z",
        watermark: "2026-06-01T00:00:00Z",
        schema: [%{name: "tenant_id", type: "VARCHAR"}],
        files: [],
        compatibility_policy: "additive_only",
        columns: MapSet.new(["tenant_id"])
      }

      assert {:error, errors} = Manifest.compatibility(m, dataset())
      assert :incompatible_schema in Enum.map(errors, & &1.code)
    end

    test "the exact compatibility policy rejects an extra snapshot column" do
      ds = dataset()

      m = %Manifest{
        dataset_id: "customer_usage",
        snapshot_id: "s1",
        created_at: "2026-06-01T00:00:00Z",
        watermark: "2026-06-01T00:00:00Z",
        schema: ds.schema ++ [%{name: "surprise", type: "VARCHAR"}],
        files: [],
        compatibility_policy: "exact",
        columns: MapSet.new(Enum.map(ds.schema, & &1.name) ++ ["surprise"])
      }

      assert {:error, errors} = Manifest.compatibility(m, ds)
      assert :incompatible_schema in Enum.map(errors, & &1.code)
    end

    test "a non-numeric type change (a DATE contract column shipped as VARCHAR) is incompatible" do
      ds = dataset()

      retyped =
        Enum.map(ds.schema, fn c -> if c.type == "DATE", do: %{c | type: "VARCHAR"}, else: c end)

      m = %Manifest{
        dataset_id: "customer_usage",
        snapshot_id: "s1",
        created_at: "2026-06-01T00:00:00Z",
        watermark: "2026-06-01T00:00:00Z",
        schema: retyped,
        files: [],
        compatibility_policy: "additive_only",
        columns: MapSet.new(Enum.map(retyped, & &1.name))
      }

      assert {:error, errors} = Manifest.compatibility(m, ds)
      assert :incompatible_schema in Enum.map(errors, & &1.code)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────────

  defp valid_map, do: Jason.decode!(File.read!(@valid))

  # Write a manifest map into a self-contained temp dir (with a copy of the real CSV so
  # file/schema checks pass), load it, and clean up — never touches the committed tree.
  defp load_map(raw) do
    root = tmp_root()
    File.mkdir_p!(root)

    File.cp!(
      Path.join(Path.dirname(@valid), "customer_usage.csv"),
      Path.join(root, "customer_usage.csv")
    )

    path = Path.join(root, "manifest.json")
    File.write!(path, Jason.encode!(raw))
    on_exit(fn -> File.rm_rf!(root) end)
    Manifest.load(path)
  end

  defp tmp_root,
    do: Path.join(System.tmp_dir!(), "offl_man_#{System.unique_integer([:positive])}")

  defp write_tmp(body, name) do
    root = tmp_root()
    File.mkdir_p!(root)
    path = Path.join(root, name)
    File.write!(path, body)
    on_exit(fn -> File.rm_rf!(root) end)
    path
  end
end
