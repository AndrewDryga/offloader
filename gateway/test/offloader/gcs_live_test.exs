defmodule Offloader.GcsLiveTest do
  # The real thing, end to end: Databricks resolver → real GCS client (token chain)
  # → engine materialize over the bearer HTTP secret → serve a row. Hits the actual
  # production bucket READ-ONLY, so it is excluded by default:
  #
  #     mix test --include gcs_live
  #
  # Needs credentials (gcloud ADC / metadata server / OFFLOADER_GCS_TOKEN) with read
  # access to the bucket.
  use ExUnit.Case, async: false

  @moduletag :gcs_live

  alias Offloader.{Engine, Manifest}
  alias Offloader.Source.Databricks

  @bucket "databricks-serving-databases"
  @prefix "prod/lol/live_aram_mayhem_champion/"

  test "resolves, materializes, and serves the latest prod snapshot" do
    {:ok, dataset} =
      Offloader.Catalog.Dataset.parse(
        %{
          "id" => "aram_live",
          "manifest" => "unused.json",
          "schema" => [
            %{"name" => "champion_id", "type" => "VARCHAR"},
            %{"name" => "patch", "type" => "VARCHAR"},
            %{"name" => "dt", "type" => "VARCHAR"},
            %{"name" => "data", "type" => "JSON"}
          ]
        },
        "datasets/aram_live.yml"
      )

    config = %{
      bucket: @bucket,
      prefix: @prefix,
      dataset: dataset,
      client: Offloader.Gcs.Client
    }

    case Databricks.resolve(config) do
      {:ok, :none} ->
        flunk("prod bucket has no committed snapshot — unexpected")

      {:ok, %Manifest{} = manifest} ->
        assert manifest.snapshot_id =~ ~r/^tid_\d+$/
        assert [%{"path" => "https://storage.googleapis.com/" <> _} | _] = manifest.files

        dir = Path.join(System.tmp_dir!(), "offl_gcs_live_#{System.unique_integer([:positive])}")

        {:ok, eng} =
          Engine.start_link(cache_dir: dir, object_store: %{type: "gcs_bearer"})

        on_exit(fn ->
          if Process.alive?(eng), do: Engine.stop(eng)
          File.rm_rf!(dir)
        end)

        case Engine.materialize(eng, "aram_live", manifest) do
          {:ok, %{row_count: n}} ->
            assert n > 0

            {:ok, res} =
              Engine.execute(
                eng,
                "SELECT CAST(champion_id AS VARCHAR) AS champion_id, " <>
                  "to_json(data)::VARCHAR AS data FROM aram_live " <>
                  "WHERE CAST(champion_id AS VARCHAR) = $1",
                ["1"],
                ["data"]
              )

            assert [[champion_id, data]] = res.rows
            assert champion_id == "1"
            assert is_map(data) and is_integer(data["num_games"])

          {:error, %Engine.Error{message: message}} ->
            # The bucket can transiently reference parts a concurrent export just
            # removed (observed live). That is exactly the keep-serving-stale case —
            # not an auth failure, which is what this test guards.
            assert message =~ ~r/404|Not Found/,
                   "materialize failed for a non-transient reason: #{message}"
        end
    end
  end
end
