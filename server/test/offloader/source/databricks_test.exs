defmodule Offloader.Source.DatabricksTest do
  # Fixture-driven: the fake GcsClient mirrors the REAL production bucket layout
  # (verified live): _committed_<tid> JSON with "added"/"removed", _committed_vacuum*
  # markers, and stale parts from older tids still present in the directory.
  # async: false — one test swaps the global :object_store app env.
  use ExUnit.Case, async: false

  alias Offloader.Manifest
  alias Offloader.Source.Databricks

  defmodule FakeGcs do
    @behaviour Offloader.Source.GcsClient

    # The test process seeds :objects (listing) and :bodies (name => body | {:error, _}).
    @impl true
    def list_objects(_bucket, prefix) do
      case Process.get(:objects) do
        {:error, _} = err -> err
        objects -> {:ok, Enum.filter(objects, &String.starts_with?(&1["name"], prefix))}
      end
    end

    @impl true
    def get_object(_bucket, name) do
      case Process.get(:bodies)[name] do
        nil -> {:error, {:not_found, name}}
        {:error, _} = err -> err
        body -> {:ok, body}
      end
    end
  end

  @prefix "prod/lol/live_aram/"

  defp dataset do
    {:ok, ds} =
      Offloader.Catalog.Dataset.parse(
        %{
          "id" => "aram",
          "manifest" => "unused.json",
          "schema" => [
            %{"name" => "champion_id", "type" => "VARCHAR"},
            %{"name" => "data", "type" => "JSON"}
          ]
        },
        "datasets/aram.yml"
      )

    ds
  end

  defp config, do: %{bucket: "b", prefix: @prefix, dataset: dataset(), client: FakeGcs}

  defp commit(tid, updated),
    do: %{"name" => "#{@prefix}_committed_#{tid}", "updated" => updated}

  defp seed(objects, bodies \\ %{}) do
    Process.put(:objects, objects)
    Process.put(:bodies, bodies)
  end

  test "resolves the newest data commit's added list into a gs:// manifest" do
    seed(
      [
        commit("111", "2026-07-01T01:00:00Z"),
        commit("222", "2026-07-02T01:00:00Z"),
        %{"name" => "#{@prefix}_committed_vacuum999", "updated" => "2026-07-03T01:00:00Z"}
      ],
      %{
        "#{@prefix}_committed_222" =>
          ~s({"added":["part-1-tid-222.parquet","part-2-tid-222.parquet"],"removed":["part-1-tid-111.parquet"]})
      }
    )

    assert {:ok, %Manifest{} = m} = Databricks.resolve(config())
    assert m.snapshot_id == "tid_222"
    assert m.dataset_id == "aram"
    assert m.watermark == "2026-07-02T01:00:00Z"
    assert m.upstream_run_id == "222"

    # no HMAC configured in tests → the bearer-covered HTTPS form
    assert Enum.map(m.files, & &1["path"]) == [
             "https://storage.googleapis.com/b/#{@prefix}part-1-tid-222.parquet",
             "https://storage.googleapis.com/b/#{@prefix}part-2-tid-222.parquet"
           ]

    assert Enum.all?(m.files, &(&1["format"] == "parquet"))
    # the dataset contract is the declared schema
    assert Enum.map(m.schema, & &1.name) == ["champion_id", "data"]
  end

  test "a newer vacuum commit never wins over an older data commit" do
    seed(
      [
        commit("111", "2026-07-01T01:00:00Z"),
        %{"name" => "#{@prefix}_committed_vacuum999", "updated" => "2026-07-05T01:00:00Z"}
      ],
      %{"#{@prefix}_committed_111" => ~s({"added":["part-1-tid-111.parquet"],"removed":[]})}
    )

    assert {:ok, %Manifest{snapshot_id: "tid_111"}} = Databricks.resolve(config())
  end

  test "no committed data yet resolves to :none" do
    seed([])
    assert {:ok, :none} = Databricks.resolve(config())

    seed([%{"name" => "#{@prefix}_committed_vacuum1", "updated" => "2026-07-01T00:00:00Z"}])
    assert {:ok, :none} = Databricks.resolve(config())
  end

  test "an empty added list resolves to :none (nothing to serve)" do
    seed(
      [commit("333", "2026-07-01T00:00:00Z")],
      %{"#{@prefix}_committed_333" => ~s({"added":[],"removed":[]})}
    )

    assert {:ok, :none} = Databricks.resolve(config())
  end

  test "a malformed commit is a clear error, not a crash" do
    seed(
      [commit("444", "2026-07-01T00:00:00Z")],
      %{"#{@prefix}_committed_444" => "not json"}
    )

    assert {:error, {:invalid_commit, _, _}} = Databricks.resolve(config())

    seed(
      [commit("444", "2026-07-01T00:00:00Z")],
      %{"#{@prefix}_committed_444" => ~s({"removed":[]})}
    )

    assert {:error, {:invalid_commit, _, _}} = Databricks.resolve(config())
  end

  test "listing and download errors propagate" do
    Process.put(:objects, {:error, {:gcs_api_error, 503}})
    assert {:error, {:gcs_api_error, 503}} = Databricks.resolve(config())

    seed(
      [commit("555", "2026-07-01T00:00:00Z")],
      %{"#{@prefix}_committed_555" => {:error, :timeout}}
    )

    assert {:error, :timeout} = Databricks.resolve(config())
  end

  test "the resolved manifest wires straight into the engine's read SQL" do
    seed(
      [commit("777", "2026-07-01T00:00:00Z")],
      %{"#{@prefix}_committed_777" => ~s({"added":["part-1-tid-777.parquet"],"removed":[]})}
    )

    {:ok, m} = Databricks.resolve(config())
    sql = Offloader.Sql.read_files_expr(m.files, m.dir)

    assert sql ==
             "SELECT * FROM read_parquet('https://storage.googleapis.com/b/#{@prefix}part-1-tid-777.parquet')"
  end

  test "object URLs switch to gs:// when HMAC credentials are configured" do
    prev = Application.get_env(:offloader, :object_store)
    Application.put_env(:offloader, :object_store, %{type: "gcs", key_id: "k", secret: "s"})
    on_exit(fn -> Application.put_env(:offloader, :object_store, prev) end)

    seed(
      [commit("888", "2026-07-01T00:00:00Z")],
      %{"#{@prefix}_committed_888" => ~s({"added":["p.parquet"],"removed":[]})}
    )

    {:ok, m} = Databricks.resolve(config())
    assert hd(m.files)["path"] == "gs://b/#{@prefix}p.parquet"
  end

  test "equal timestamps tie-break by name (deterministic)" do
    seed(
      [commit("111", "2026-07-01T00:00:00Z"), commit("222", "2026-07-01T00:00:00Z")],
      %{"#{@prefix}_committed_222" => ~s({"added":["p.parquet"],"removed":[]})}
    )

    assert {:ok, %Manifest{snapshot_id: "tid_222"}} = Databricks.resolve(config())
  end
end
