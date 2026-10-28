defmodule Offloader.Refresh do
  @moduledoc """
  One dataset refresh, from "where do snapshots come from" to "the new table is
  swapped in": resolve the candidate manifest (a static path or a dynamic source),
  skip when it's the snapshot already serving, check compatibility against the
  dataset contract, materialize into a NEW table, and atomically swap. Used by the
  Runtime's boot refresh and by each dataset's `Offloader.Refresh.Worker` — the
  logic is identical; only where it runs differs.

  Never swaps a bad snapshot: any rejection or failure leaves the currently-active
  snapshot untouched and returns an attempt record for diagnostics.
  """

  require Logger

  alias Offloader.{Engine, Manifest}
  alias Offloader.Source.Databricks

  @type snap :: %{
          snapshot_id: String.t(),
          watermark: String.t() | nil,
          table: String.t(),
          files: [map()],
          dir: String.t() | nil
        }
  @type attempt :: %{
          snapshot_id: String.t() | nil,
          status: :ok | :unchanged | :rejected | :failed,
          error: String.t() | nil,
          at: DateTime.t()
        }
  @type outcome ::
          {:swapped, snap(), attempt()} | {:unchanged | :rejected | :failed, attempt()}

  @doc """
  Refresh `dataset` on `engine`. `active` is the currently serving snap (or nil).
  `how` is `{:static, manifest_path}` or `{:source, source_config}`. Opts:
  `force: true` re-materializes even when the snapshot id is unchanged (the manual
  operator path).
  """
  @spec perform(
          GenServer.server(),
          Offloader.Catalog.Dataset.t(),
          snap() | nil,
          {:static, String.t()} | {:source, map()},
          keyword()
        ) :: outcome()
  def perform(engine, dataset, active, how, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    quarantined = Keyword.get(opts, :quarantined)

    case resolve(dataset, how) do
      {:ok, :none} ->
        {:unchanged, attempt(nil, :unchanged, "source has no committed snapshot")}

      {:ok, %Manifest{} = manifest} ->
        cond do
          not force and active != nil and manifest.snapshot_id == active.snapshot_id ->
            {:unchanged, attempt(manifest.snapshot_id, :unchanged, nil)}

          # This snapshot was just rolled back from — an auto-poll must NOT re-pull it, or
          # the operator's rollback silently undoes itself. It stays skipped until a NEWER
          # snapshot appears (which clears the quarantine) or a forced manual refresh.
          not force and manifest.snapshot_id == quarantined ->
            {:unchanged,
             attempt(
               manifest.snapshot_id,
               :unchanged,
               "snapshot was rolled back; waiting for a newer one"
             )}

          true ->
            check_and_swap(engine, dataset, manifest)
        end

      {:rejected, snapshot_id, summary} ->
        log(dataset, :rejected, summary)
        {:rejected, attempt(snapshot_id, :rejected, summary)}

      {:failed, summary} ->
        log(dataset, :failed, summary)
        {:failed, attempt(nil, :failed, summary)}
    end
  end

  @doc """
  A fresh table name for one materialization of a dataset. Every build gets its own table,
  so a build can never overwrite a table that is serving: not a forced refresh of the live
  snapshot, not two snapshot ids that sanitize to the same name, and not a staging build
  after a restart. The `snap_` prefix marks the tables Offloader owns.
  """
  @spec new_table(String.t()) :: String.t()
  def new_table(dataset_id),
    do: "snap_" <> dataset_id <> "_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  @doc """
  Materialize the dataset's latest snapshot into `table` WITHOUT swapping the live view — the
  blue-green BUILD step for a zero-downtime schema cutover. `table` is a caller-chosen name
  DISTINCT from the live snapshot table, so the build never touches what's serving; the Runtime
  performs the atomic `Engine.swap` onto it later. Returns `{:staged, snap}` (new table built,
  not yet live) or a rejection/failure whose `attempt` explains why — in which case the old
  snapshot keeps serving, untouched.
  """
  @spec stage(
          GenServer.server(),
          Offloader.Catalog.Dataset.t(),
          {:static, String.t()} | {:source, map()},
          String.t()
        ) :: {:staged, snap()} | {:rejected, attempt()} | {:failed, attempt()}
  def stage(engine, dataset, how, table) do
    case resolve(dataset, how) do
      {:ok, :none} ->
        {:failed, attempt(nil, :failed, "source has no committed snapshot")}

      {:ok, %Manifest{} = manifest} ->
        stage_manifest(engine, dataset, manifest, table)

      {:rejected, snapshot_id, summary} ->
        log(dataset, :rejected, summary)
        {:rejected, attempt(snapshot_id, :rejected, summary)}

      {:failed, summary} ->
        log(dataset, :failed, summary)
        {:failed, attempt(nil, :failed, summary)}
    end
  end

  defp stage_manifest(engine, dataset, manifest, table) do
    case Manifest.compatibility(manifest, dataset) do
      {:error, errors} ->
        summary = summarize(errors)
        log(dataset, :rejected, summary)
        {:rejected, attempt(manifest.snapshot_id, :rejected, summary)}

      :ok ->
        with {:materialize, {:ok, _}} <-
               {:materialize, Engine.materialize(engine, table, manifest, dataset.sort_columns)},
             {:check, :ok} <- {:check, check_materialized(engine, dataset, manifest, table)} do
          {:staged, snap(manifest, table)}
        else
          {:check, error} -> discard(engine, dataset, manifest, table, error)
          {step, {:error, error}} -> failed(dataset, manifest, step, error)
        end
    end
  end

  # ── resolve the candidate manifest ─────────────────────────────────────────────

  defp resolve(_dataset, {:static, path}) do
    case Manifest.load(path) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, errors} -> {:rejected, nil, summarize(errors)}
    end
  end

  defp resolve(dataset, {:source, %{type: "databricks"} = source}) do
    config = %{
      bucket: source.bucket,
      prefix: source.prefix,
      dataset: dataset,
      client: source_client()
    }

    case Databricks.resolve(config) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:failed, "source resolve failed: #{inspect(reason)}"}
    end
  end

  # The GCS client is swappable so refresh/isolation tests inject fixtures.
  defp source_client,
    do: Application.get_env(:offloader, :gcs_source_client, Offloader.Gcs.Client)

  # ── compatibility → materialize → swap ─────────────────────────────────────────

  defp check_and_swap(engine, dataset, manifest) do
    case Manifest.compatibility(manifest, dataset) do
      {:error, errors} ->
        summary = summarize(errors)
        log(dataset, :rejected, summary)
        {:rejected, attempt(manifest.snapshot_id, :rejected, summary)}

      :ok ->
        materialize_and_swap(engine, dataset, manifest)
    end
  end

  defp materialize_and_swap(engine, dataset, manifest) do
    table = new_table(dataset.id)

    with {:materialize, {:ok, _}} <-
           {:materialize, Engine.materialize(engine, table, manifest, dataset.sort_columns)},
         {:check, :ok} <- {:check, check_materialized(engine, dataset, manifest, table)},
         {:swap, :ok} <- {:swap, Engine.swap(engine, dataset.id, table)} do
      {:swapped, snap(manifest, table), attempt(manifest.snapshot_id, :ok, nil)}
    else
      {:check, error} -> discard(engine, dataset, manifest, table, error)
      {step, {:error, error}} -> failed(dataset, manifest, step, error)
    end
  end

  # Judge the columns and types the files really produced, not what the manifest declares: a
  # file can lack a column or carry another type, and that must never replace working data.
  defp check_materialized(engine, dataset, manifest, table) do
    case Engine.describe(engine, table) do
      {:ok, columns} ->
        Manifest.compatibility(%{manifest | schema: Manifest.physical_schema(columns)}, dataset)

      {:error, error} ->
        {:error, error}
    end
  end

  # A candidate that failed its check is never served, so drop it. Its name is unique to this
  # build (`new_table/1`), so the drop cannot touch a live table.
  defp discard(engine, dataset, manifest, table, {:error, errors}) when is_list(errors) do
    Engine.drop(engine, table)
    summary = summarize(errors)
    log(dataset, :rejected, summary)
    {:rejected, attempt(manifest.snapshot_id, :rejected, summary)}
  end

  defp discard(engine, dataset, manifest, table, {:error, error}) do
    Engine.drop(engine, table)
    failed(dataset, manifest, :check, error)
  end

  defp failed(dataset, manifest, step, error) do
    summary = "#{step} failed: #{error.message}"
    log(dataset, :failed, summary)
    {:failed, attempt(manifest.snapshot_id, :failed, summary)}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────

  defp snap(manifest, table),
    do: %{
      snapshot_id: manifest.snapshot_id,
      watermark: manifest.watermark,
      table: table,
      files: manifest.files,
      dir: manifest.dir
    }

  defp attempt(snapshot_id, status, error),
    do: %{snapshot_id: snapshot_id, status: status, error: error, at: DateTime.utc_now()}

  defp summarize(errors) when is_list(errors), do: "#{length(errors)} validation error(s)"

  defp log(dataset, status, summary),
    do: Logger.warning("refresh #{dataset.id} #{status}: #{summary}")
end
