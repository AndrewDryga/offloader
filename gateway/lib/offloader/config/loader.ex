defmodule Offloader.Config.Loader do
  @moduledoc """
  Resolve `OFFLOADER_CONFIG` to a loadable local project, then load + validate it.

  A local path loads as-is (today's behaviour). A `gs://bucket/prefix/` path fetches the
  whole project tree (`offloader.yml` + `datasets/` + `endpoints/` + the keys file) from GCS
  into `<cache_dir>/config/` over the bearer token chain (`Offloader.Gcs.Client` — the same
  client the Databricks resolver lists with), then loads that local copy. Remote config is
  GCS-only for v1.

  The fetch is bounded (file count + total bytes) and retried a few times for transient GCS
  errors, so a momentary blip at boot doesn't crash the container. Credentials never touch
  logs — only file counts and the local cache path are logged.
  """

  require Logger

  alias Offloader.Catalog

  @config_subdir "config"
  @max_files 500
  @max_bytes 32 * 1024 * 1024
  @yaml_exts [".yml", ".yaml"]
  @retries 3
  @retry_backoff_ms 500

  @doc """
  Load + validate the project at `config_path` (a local path or `gs://…`), fetching a remote
  tree into `<cache_dir>/config/` first. Returns the validated catalog or a reason (the same
  shape `Runtime.init` already turns into `{:stop, …}`).
  """
  @spec load(String.t(), String.t()) :: {:ok, Catalog.t()} | {:error, term()}
  def load(config_path, cache_dir) when is_binary(config_path) and is_binary(cache_dir) do
    with {:ok, offloader_yml} <- resolve(config_path, cache_dir) do
      case Catalog.load(offloader_yml) do
        {:ok, catalog} -> {:ok, catalog}
        {:error, errors} -> {:error, {:config_invalid, errors}}
      end
    end
  end

  # ── resolve config_path → a local offloader.yml ────────────────────────────────

  defp resolve("gs://" <> _ = url, cache_dir) do
    with {:ok, {bucket, prefix}} <- parse_gs(url),
         dir = Path.join(cache_dir, @config_subdir),
         :ok <- fetch_remote(bucket, prefix, dir) do
      {:ok, Path.join(dir, "offloader.yml")}
    end
  end

  defp resolve(path, _cache_dir) do
    case URI.parse(path) do
      %URI{scheme: scheme} when scheme in ["s3", "https", "http"] ->
        {:error, {:unsupported_config_scheme, scheme}}

      _ ->
        {:ok, path}
    end
  end

  # `gs://bucket/prefix/...` → {bucket, prefix} with the trailing slash trimmed. A
  # bucket-only URL (`gs://bucket`) uses the empty prefix (whole bucket).
  defp parse_gs("gs://" <> rest) do
    case rest |> String.trim_trailing("/") |> String.split("/", parts: 2) do
      [bucket] when bucket != "" -> {:ok, {bucket, ""}}
      [bucket, prefix] when bucket != "" -> {:ok, {bucket, prefix}}
      _ -> {:error, {:invalid_gs_url, "gs://" <> rest}}
    end
  end

  # ── fetch the project tree from GCS ────────────────────────────────────────────

  defp fetch_remote(bucket, prefix, dir), do: with_retry(fn -> do_fetch(bucket, prefix, dir) end)

  defp do_fetch(bucket, prefix, dir) do
    # Scope the listing to the prefix "directory" so a sibling like `<prefix>2/` can't leak in.
    list_prefix = if prefix == "", do: "", else: prefix <> "/"

    with {:ok, items} <- client().list_objects(bucket, list_prefix) do
      yaml = Enum.filter(items, &yaml_name?(&1["name"]))

      cond do
        yaml == [] ->
          {:error, {:no_config_objects, bucket, prefix}}

        length(yaml) > @max_files ->
          {:error, {:too_many_config_files, length(yaml)}}

        total_bytes(yaml) > @max_bytes ->
          {:error, {:config_too_large, total_bytes(yaml)}}

        true ->
          download_all(bucket, list_prefix, yaml, dir)
      end
    end
  end

  # Wipe the local config dir first so a file removed upstream doesn't linger and get loaded.
  defp download_all(bucket, list_prefix, items, dir) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    result =
      Enum.reduce_while(items, :ok, fn item, _acc ->
        name = item["name"]
        rel = String.replace_prefix(name, list_prefix, "")

        case client().get_object(bucket, name) do
          {:ok, body} ->
            path = Path.join(dir, rel)
            File.mkdir_p!(Path.dirname(path))
            File.write!(path, body)
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:fetch_failed, rel, reason}}}
        end
      end)

    with :ok <- result do
      Logger.info(
        "loaded config: #{length(items)} file(s) from gs://#{bucket}/#{list_prefix} → #{dir}"
      )

      :ok
    end
  end

  # ── retry (transient GCS/transport errors only) ────────────────────────────────

  defp with_retry(fun, attempt \\ 1) do
    case fun.() do
      {:error, reason} = err ->
        if attempt < @retries and transient?(reason) do
          Process.sleep(@retry_backoff_ms * attempt)
          with_retry(fun, attempt + 1)
        else
          err
        end

      other ->
        other
    end
  end

  # Deterministic failures (won't change on retry) and bad credentials are NOT transient;
  # 5xx, malformed JSON, and transport errors are.
  defp transient?({:no_config_objects, _, _}), do: false
  defp transient?({:too_many_config_files, _}), do: false
  defp transient?({:config_too_large, _}), do: false
  defp transient?({:invalid_gs_url, _}), do: false
  defp transient?(:unauthorized), do: false
  defp transient?({:gcs_api_error, status}) when is_integer(status), do: status >= 500
  defp transient?({:fetch_failed, _rel, reason}), do: transient?(reason)
  defp transient?(_), do: true

  # ── helpers ────────────────────────────────────────────────────────────────────

  defp yaml_name?(name) when is_binary(name), do: Path.extname(name) in @yaml_exts
  defp yaml_name?(_), do: false

  defp total_bytes(items),
    do: Enum.reduce(items, 0, fn item, acc -> acc + parse_size(item["size"]) end)

  defp parse_size(size) when is_binary(size) do
    case Integer.parse(size) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_size(size) when is_integer(size), do: size
  defp parse_size(_), do: 0

  # The GCS client is swappable so tests inject a fixture (no network) — same override the
  # Databricks refresh path uses.
  defp client, do: Application.get_env(:offloader, :gcs_source_client, Offloader.Gcs.Client)
end
