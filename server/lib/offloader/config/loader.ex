defmodule Offloader.Config.Loader do
  @moduledoc """
  Resolve `OFFLOADER_CONFIG` to a loadable local project, then load + validate it.

  A local path loads as-is (today's behaviour). A `gs://bucket/prefix/` path fetches the
  whole project tree (`offloader.yml` + `datasets/` + `endpoints/` + the keys file) from GCS
  over the bearer token chain (`Offloader.Gcs.Client` — the same client the Databricks
  resolver lists with), then loads that local copy.

  ## Generations

  Each fetch lands in a NEW directory, `<cache_dir>/configs/<generation>/`, and is validated
  there. Only a valid tree becomes current: `<cache_dir>/config` is a symlink, renamed over in
  one atomic step to point at it. A failed fetch or an invalid revision is deleted and never
  touches the tree the running catalog reads. The catalog always reads through the stable
  `config` path, so a static dataset's identity does not change with each fetch, while a
  refresh loads its manifest through `pin/1`, so the snapshot keeps reading the files it was
  built from. `prune/2` deletes a generation once nothing uses it.

  The fetch is bounded (file count + total bytes) and retried a few times for transient GCS
  errors, so a momentary blip at boot doesn't crash the container. Credentials never touch
  logs — only file counts and the local cache path are logged.

  ## Booting while the bucket can't be read

  Each generation records where it was fetched from (`.source`) and the listing digest it was
  fetched at (`.digest`). At boot, and only then, a fetch that fails because the bucket can't
  be read (network, credentials, a GCS or S3 error) falls back to the current generation when
  it came from the same place and still validates, so a restart during an outage serves the
  config it last had; the catalog says so (`config_from_cache`). What the bucket says (it
  doesn't exist, no config, too large, unsafe paths), an invalid config, and local disk errors
  still fail. Sync's loads never fall back, and the sync loop starts from the running
  generation's digest, so it fetches the bucket's copy once the bucket answers.
  """

  require Logger

  alias Offloader.Catalog

  @config_link "config"
  @generations "configs"
  @source_file ".source"
  @digest_file ".digest"
  @max_files 500
  @max_bytes 32 * 1024 * 1024
  @yaml_exts [".yml", ".yaml"]
  @retries 3
  @retry_backoff_ms 500

  @doc """
  Load + validate the project at `config_path` (a local path or `gs://…`), fetching a remote
  tree into a new config generation first and making it current only once it validates.
  Returns the validated catalog or a reason (the same shape `Runtime.init` already turns into
  `{:stop, …}`). `fallback_to_cached: true` is for boot only (see the moduledoc).
  """
  @spec load(String.t(), String.t(), keyword()) :: {:ok, Catalog.t()} | {:error, term()}
  def load(config_path, cache_dir, opts \\ [])
      when is_binary(config_path) and is_binary(cache_dir) do
    case resolve(config_path) do
      {:remote, client, bucket, prefix} ->
        load_generation(client, bucket, prefix, cache_dir, source_id(config_path), opts)

      {:local, offloader_yml} ->
        validate(offloader_yml)

      {:error, _} = error ->
        error
    end
  end

  defp validate(offloader_yml) do
    case Catalog.load(offloader_yml) do
      {:ok, catalog} -> {:ok, catalog}
      {:error, errors} -> {:error, {:config_invalid, errors}}
    end
  end

  defp load_generation(client, bucket, prefix, cache_dir, source, opts) do
    dir = Path.join([cache_dir, @generations, generation_name()])

    case fetch_remote(client, bucket, prefix, dir) do
      {:ok, digest} ->
        with :ok <- write_file(Path.join(dir, @source_file), source, @source_file),
             :ok <- write_file(Path.join(dir, @digest_file), Base.encode16(digest), @digest_file),
             {:ok, catalog} <- validate(Path.join(dir, "offloader.yml")),
             {:ok, link} <- activate(dir, cache_dir) do
          {:ok, %{catalog | config_dir: link}}
        else
          error ->
            File.rm_rf(dir)
            error
        end

      {:error, reason} = error ->
        File.rm_rf(dir)

        if Keyword.get(opts, :fallback_to_cached, false) and unreadable?(reason),
          do: load_cached(cache_dir, source, reason, error),
          else: error
    end
  end

  # Within a fetch, these mean the bucket answered with something unusable or the local disk
  # failed. Anything else means it couldn't be read: network, credentials, a GCS or S3 error.
  # A 404 on the listing means the bucket is gone; a 404 on a download is a mid-upload race.
  defp unreadable?({:gcs_api_error, 404}), do: false
  defp unreadable?({:s3_api_error, 404}), do: false
  defp unreadable?({:no_config_objects, _, _}), do: false
  defp unreadable?({:too_many_config_files, _}), do: false
  defp unreadable?({:config_too_large, _}), do: false
  defp unreadable?({:unsafe_config_path, _}), do: false
  defp unreadable?({:write_failed, _, _}), do: false
  defp unreadable?(_reason), do: true

  # The current generation, if it was fetched from this same path and still validates. A
  # generation from before sources were recorded is not trusted.
  defp load_cached(cache_dir, source, reason, error) do
    link = Path.join(cache_dir, @config_link)

    with {:ok, ^source} <- File.read(Path.join(link, @source_file)),
         {:ok, catalog} <- validate(Path.join(link, "offloader.yml")) do
      Logger.warning(
        "config bucket unreadable at boot (#{inspect(reason)}); serving the config last " <>
          "fetched from #{source} (#{generation_of(link)}) until the bucket answers again"
      )

      {:ok, %{catalog | config_dir: link, config_from_cache: true}}
    else
      refusal ->
        Logger.warning(
          "config bucket unreadable at boot (#{inspect(reason)}), and the cached config " <>
            "can't stand in: #{refusal_reason(refusal)}"
        )

        error
    end
  end

  defp refusal_reason({:ok, other_source}), do: "it was fetched from #{other_source}"
  defp refusal_reason({:error, :enoent}), do: "none was fetched, or it predates this release"
  defp refusal_reason({:error, {:config_invalid, _}}), do: "it no longer validates"
  defp refusal_reason(other), do: inspect(other)

  # Where a generation comes from: the config path, plus the endpoint for an S3-compatible
  # store, where the same s3:// URL can name a bucket on another service.
  defp source_id("s3://" <> _ = path) do
    endpoint =
      Application.get_env(:offloader, :s3_base_url) ||
        (Offloader.Config.object_store() || %{})[:endpoint]

    base = String.trim_trailing(path, "/")
    if endpoint, do: "#{base} at #{endpoint}", else: base
  end

  defp source_id(path), do: String.trim_trailing(path, "/")

  @doc """
  The change-token of the config the server is running, as the sync loop's starting point. For
  a remote config it's the listing digest the current generation was fetched at, so a boot that
  fell back to the cache doesn't look current and the first sync tick fetches the bucket's copy.
  A local config is read live.
  """
  @spec running_digest(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def running_digest(config_path, cache_dir) do
    case resolve(config_path) do
      {:remote, _client, _bucket, _prefix} ->
        with {:ok, hex} <- File.read(Path.join([cache_dir, @config_link, @digest_file])),
             {:ok, digest} <- Base.decode16(hex) do
          {:ok, digest}
        else
          _ -> {:error, :no_recorded_digest}
        end

      {:local, _offloader_yml} ->
        digest(config_path)

      {:error, _} = error ->
        error
    end
  end

  defp generation_of(link) do
    case File.read_link(link) do
      {:ok, target} -> Path.basename(target)
      {:error, _} -> "unknown generation"
    end
  end

  # Sorts by creation time, and unique even for two fetches in the same millisecond.
  defp generation_name,
    do:
      "#{System.os_time(:millisecond)}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

  # Point <cache_dir>/config at `dir` by renaming a fresh symlink over it. rename(2) replaces
  # the old link atomically, so a reader resolves either the old generation or the new one.
  # The temporary link is named after the generation, so two activations can't collide. An
  # older version kept a plain directory there; it is removed first.
  defp activate(dir, cache_dir) do
    link = Path.join(cache_dir, @config_link)
    tmp = "#{link}.#{Path.basename(dir)}"

    with :ok <- remove_plain_dir(link),
         :ok <- File.ln_s(Path.join(@generations, Path.basename(dir)), tmp) do
      case File.rename(tmp, link) do
        :ok ->
          {:ok, link}

        error ->
          File.rm(tmp)
          error
      end
    end
  end

  defp remove_plain_dir(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.rm_rf(path) do
          {:ok, _} -> :ok
          {:error, reason, _file} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  @doc """
  `path` with the `config` link this module manages replaced by the generation it points at,
  so a snapshot built from it keeps reading the same files after a newer config is activated.
  Any other path comes back unchanged, including one through another tool's symlink (git-sync,
  a Kubernetes ConfigMap): that tool deletes old targets, so it must keep being followed.
  """
  @spec pin(String.t()) :: String.t()
  def pin(path) do
    parts = Path.split(path)

    Enum.find_value(1..length(parts)//1, path, fn n ->
      link = Path.join(Enum.take(parts, n))

      case File.read_link(link) do
        {:ok, @generations <> "/" <> _ = target} ->
          Path.join([Path.dirname(link), target | Enum.drop(parts, n)])

        _ ->
          nil
      end
    end)
  end

  @doc "True when `dir` lies in a config generation under `cache_dir` that no longer exists."
  @spec generation_missing?(String.t(), String.t() | nil) :: boolean()
  def generation_missing?(cache_dir, dir) do
    is_binary(dir) and String.starts_with?(dir, Path.join(cache_dir, @generations) <> "/") and
      not File.dir?(dir)
  end

  @doc """
  Delete the config generations nothing uses: every one under `<cache_dir>/configs` except the
  current one, the newest two (a fetch may be writing one, or a refresh reading the one just
  replaced), and any holding a directory in `in_use` (the pinned `dir` of a snapshot that is
  serving or kept for rollback). A no-op for a local config.
  """
  @spec prune(String.t(), [String.t() | nil]) :: :ok
  def prune(cache_dir, in_use) do
    root = Path.join(cache_dir, @generations)

    with {:ok, names} <- File.ls(root) do
      used =
        for dir <- in_use,
            is_binary(dir) and String.starts_with?(dir, root <> "/"),
            do: dir |> String.replace_prefix(root <> "/", "") |> Path.split() |> hd()

      current =
        case File.read_link(Path.join(cache_dir, @config_link)) do
          {:ok, target} -> [Path.basename(target)]
          {:error, _} -> []
        end

      keep = current ++ Enum.take(Enum.sort(names), -2) ++ used

      for name <- names, name not in keep, do: File.rm_rf(Path.join(root, name))
    end

    :ok
  end

  @doc """
  A cheap change-token for the config at `config_path` WITHOUT downloading it: for a `gs://…`
  path, a hash of the sorted `{name, updated, size}` from a single LIST call; for a local path,
  a hash of the sorted `{relpath, mtime, size}` of its `.yml`/`.yaml` files. Equal token ⇒ the
  config is unchanged, so the sync loop can skip a fetch + reload.
  """
  @spec digest(String.t()) :: {:ok, binary()} | {:error, term()}
  def digest("gs://" <> _ = url) do
    with {:ok, {bucket, prefix}} <- parse_gs(url), do: digest_remote(gcs_client(), bucket, prefix)
  end

  def digest("s3://" <> _ = url) do
    with {:ok, {bucket, prefix}} <- parse_s3(url), do: digest_remote(s3_client(), bucket, prefix)
  end

  def digest(path) do
    case URI.parse(path) do
      %URI{scheme: scheme} when scheme in ["https", "http"] ->
        {:error, {:unsupported_config_scheme, scheme}}

      _ ->
        dir = Path.dirname(path)

        token =
          Path.join(dir, "**/*.{yml,yaml}")
          |> Path.wildcard()
          |> Enum.map(fn file ->
            case File.stat(file, time: :posix) do
              {:ok, %{mtime: mtime, size: size}} -> {Path.relative_to(file, dir), mtime, size}
              _ -> {Path.relative_to(file, dir), 0, 0}
            end
          end)
          |> Enum.sort()
          |> hash()

        {:ok, token}
    end
  end

  defp digest_remote(client, bucket, prefix) do
    list_prefix = if prefix == "", do: "", else: prefix <> "/"

    with_retry(fn ->
      with {:ok, items} <- client.list_objects(bucket, list_prefix) do
        {:ok, listing_digest(items)}
      end
    end)
  end

  # The same token for a listing, whether the sync loop takes it or a fetch records it.
  defp listing_digest(items) do
    items
    |> Enum.filter(&yaml_name?(&1["name"]))
    |> Enum.map(&{&1["name"], &1["updated"], &1["size"]})
    |> Enum.sort()
    |> hash()
  end

  defp hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))

  # ── resolve config_path → a remote tree or a local offloader.yml ──────────────

  defp resolve("gs://" <> _ = url) do
    with {:ok, {bucket, prefix}} <- parse_gs(url), do: {:remote, gcs_client(), bucket, prefix}
  end

  defp resolve("s3://" <> _ = url) do
    with {:ok, {bucket, prefix}} <- parse_s3(url), do: {:remote, s3_client(), bucket, prefix}
  end

  defp resolve(path) do
    case URI.parse(path) do
      %URI{scheme: scheme} when scheme in ["https", "http"] ->
        {:error, {:unsupported_config_scheme, scheme}}

      _ ->
        {:local, path}
    end
  end

  # `gs://bucket/prefix/...` (or `s3://…`) → {bucket, prefix} with the trailing slash trimmed.
  # A bucket-only URL uses the empty prefix (whole bucket).
  defp parse_gs("gs://" <> rest), do: split_bucket_prefix(rest, "gs")
  defp parse_s3("s3://" <> rest), do: split_bucket_prefix(rest, "s3")

  defp split_bucket_prefix(rest, scheme) do
    case rest |> String.trim_trailing("/") |> String.split("/", parts: 2) do
      [bucket] when bucket != "" -> {:ok, {bucket, ""}}
      [bucket, prefix] when bucket != "" -> {:ok, {bucket, prefix}}
      _ -> {:error, {:"invalid_#{scheme}_url", "#{scheme}://" <> rest}}
    end
  end

  # ── fetch the project tree from GCS ────────────────────────────────────────────

  defp fetch_remote(client, bucket, prefix, dir),
    do: with_retry(fn -> do_fetch(client, bucket, prefix, dir) end)

  defp do_fetch(client, bucket, prefix, dir) do
    # Scope the listing to the prefix "directory" so a sibling like `<prefix>2/` can't leak in.
    list_prefix = if prefix == "", do: "", else: prefix <> "/"

    with {:ok, items} <- client.list_objects(bucket, list_prefix) do
      # Fetch the whole project tree — the config `.yml` AND its companion data (a static
      # `manifest.json` + small snapshot files a relative `manifest:` points at) — so a
      # self-contained project boots straight from a bucket. Still bounded by @max_files/
      # @max_bytes and path-guarded; a config-less prefix is rejected. Large data belongs
      # in remote-scan / gs:// manifest paths that DuckDB reads directly, not here.
      cond do
        not Enum.any?(items, &yaml_name?(&1["name"])) ->
          {:error, {:no_config_objects, bucket, prefix}}

        length(items) > @max_files ->
          {:error, {:too_many_config_files, length(items)}}

        total_bytes(items) > @max_bytes ->
          {:error, {:config_too_large, total_bytes(items)}}

        true ->
          with :ok <- download_all(client, bucket, list_prefix, items, dir),
               do: {:ok, listing_digest(items)}
      end
    end
  end

  # `dir` is this fetch's own new generation; a retry starts it over from empty. A file that
  # can't be written is an error like a failed get, so the caller discards the generation.
  defp download_all(client, bucket, list_prefix, items, dir) do
    File.rm_rf(dir)

    result =
      Enum.reduce_while(items, :ok, fn item, _acc ->
        name = item["name"]
        rel = String.replace_prefix(name, list_prefix, "")

        cond do
          # A folder made in the GCS console is an empty object named `…/`: nothing to write.
          rel == "" or String.ends_with?(rel, "/") ->
            {:cont, :ok}

          # Defense in depth: a crafted object name must never write outside its generation.
          not safe_rel?(rel) ->
            {:halt, {:error, {:unsafe_config_path, rel}}}

          true ->
            with {:ok, body} <- fetch_object(client, bucket, name, rel),
                 :ok <- write_file(Path.join(dir, rel), body, rel) do
              {:cont, :ok}
            else
              error -> {:halt, error}
            end
        end
      end)

    with :ok <- result do
      Logger.info(
        "loaded config: #{length(items)} file(s) from #{bucket}/#{list_prefix} → #{dir}"
      )

      :ok
    end
  end

  defp fetch_object(client, bucket, name, rel) do
    case client.get_object(bucket, name) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:fetch_failed, rel, reason}}
    end
  end

  defp write_file(path, body, rel) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, body) do
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, rel, reason}}
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
  defp transient?({:invalid_s3_url, _}), do: false
  defp transient?(:unauthorized), do: false
  defp transient?({:gcs_api_error, status}) when is_integer(status), do: status >= 500
  defp transient?({:s3_api_error, status}) when is_integer(status), do: status >= 500
  defp transient?({:fetch_failed, _rel, reason}), do: transient?(reason)
  defp transient?({:write_failed, _rel, _reason}), do: false
  defp transient?(_), do: true

  # ── helpers ────────────────────────────────────────────────────────────────────

  defp yaml_name?(name) when is_binary(name), do: Path.extname(name) in @yaml_exts
  defp yaml_name?(_), do: false

  # A downloaded object's relative path must stay inside the config dir: relative, no `..`,
  # no absolute segment.
  defp safe_rel?(rel), do: Path.type(rel) == :relative and ".." not in Path.split(rel)

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

  # The source clients are swappable so tests inject a fixture (no network) — same override the
  # Databricks refresh path uses. One per scheme: gs:// → GCS, s3:// → S3.
  defp gcs_client, do: Application.get_env(:offloader, :gcs_source_client, Offloader.Gcs.Client)
  defp s3_client, do: Application.get_env(:offloader, :s3_source_client, Offloader.S3.Client)
end
