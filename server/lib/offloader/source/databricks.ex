defmodule Offloader.Source.Databricks do
  @moduledoc """
  Resolves the latest committed Databricks export in a GCS prefix into a manifest.

  Databricks writes exports transactionally per `{env}/{game}/{table}/` prefix:

      _started_<tid>
      part-*-tid-<tid>-*.parquet
      _committed_<tid>     ← JSON {"added": [...], "removed": [...]}
      _SUCCESS

  The directory accumulates parts from PREVIOUS tids until a vacuum, so "all .parquet
  in the dir" is not a consistent snapshot — the only safe set is the `added` list of
  the newest `_committed_<tid>` (verified against the production bucket). Vacuum
  commits (`_committed_vacuum<tid>`) are cleanup markers, not data, and are skipped.

  The resolved manifest carries remote file URLs — `gs://` under HMAC credentials,
  otherwise the HTTPS form covered by the bearer HTTP secret (`Offloader.Gcs.Client.
  object_url/2` picks per the configured auth) — and the DATASET's declared schema:
  Databricks ships no schema in the commit, so the dataset contract is the declaration
  and the parquet itself is the authority at materialize time.

  GCS access goes through an `Offloader.Source.GcsClient` so this logic is tested
  with fixture listings; the real client owns HTTP + credentials.
  """

  @behaviour Offloader.Source

  alias Offloader.Manifest

  @commit_prefix "_committed_"
  @vacuum_prefix "_committed_vacuum"

  @doc """
  Resolve the latest committed snapshot under `prefix` in `bucket`.

  Config keys: `:bucket`, `:prefix` (must end with `/`), `:dataset`
  (`%Offloader.Catalog.Dataset{}`), `:client` (a `GcsClient` module).
  """
  @impl true
  def resolve(%{bucket: bucket, prefix: prefix, dataset: dataset, client: client}) do
    with {:ok, items} <- client.list_objects(bucket, prefix <> @commit_prefix) do
      case latest_commit(items) do
        nil -> {:ok, :none}
        commit -> resolve_commit(client, bucket, prefix, dataset, commit)
      end
    end
  end

  defp resolve_commit(client, bucket, prefix, dataset, commit) do
    case commit_added(client, bucket, commit) do
      # An empty `added` list is a snapshot with no data — nothing to serve; the
      # caller keeps its current active snapshot.
      {:ok, []} -> {:ok, :none}
      {:ok, added} -> {:ok, build_manifest(bucket, prefix, dataset, commit, added)}
      {:error, _} = err -> err
    end
  end

  # ── latest data commit ──────────────────────────────────────────────────────────

  defp latest_commit(items) do
    case Enum.reject(items, &vacuum?/1) do
      [] -> nil
      commits -> Enum.max_by(commits, fn item -> {item["updated"], item["name"]} end)
    end
  end

  defp vacuum?(%{"name" => name}),
    do: name |> Path.basename() |> String.starts_with?(@vacuum_prefix)

  defp vacuum?(_), do: true

  defp commit_added(client, bucket, %{"name" => name}) do
    with {:ok, body} <- client.get_object(bucket, name) do
      case JSON.decode(body) do
        {:ok, %{"added" => added}} when is_list(added) ->
          {:ok, Enum.filter(added, &is_binary/1)}

        {:ok, _other} ->
          {:error, {:invalid_commit, name, "missing \"added\" list"}}

        {:error, reason} ->
          {:error, {:invalid_commit, name, "invalid JSON: #{inspect(reason)}"}}
      end
    end
  end

  # ── manifest ────────────────────────────────────────────────────────────────────

  defp build_manifest(bucket, prefix, dataset, commit, added) do
    tid = commit["name"] |> Path.basename() |> String.replace_leading(@commit_prefix, "")

    files =
      for part <- added do
        %{
          "path" => Offloader.Gcs.Client.object_url(bucket, prefix <> part),
          "format" => "parquet"
        }
      end

    %Manifest{
      dataset_id: dataset.id,
      snapshot_id: "tid_" <> tid,
      created_at: commit["updated"],
      watermark: commit["updated"],
      schema: dataset.schema,
      files: files,
      partition_columns: [],
      sort_columns: [],
      producer: "databricks",
      upstream_run_id: tid,
      compatibility_policy: "additive_only",
      dir: nil,
      columns: dataset.columns
    }
  end
end
