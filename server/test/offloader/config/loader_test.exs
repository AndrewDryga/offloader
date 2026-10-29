defmodule Offloader.Config.LoaderTest do
  # Resolving OFFLOADER_CONFIG: a local path loads as-is; a `gs://…` path fetches the
  # project tree via the (stubbed) bearer client into <cache>/config and loads that.
  # async: false — the swappable `:gcs_source_client` is a global app-env seam.
  use ExUnit.Case, async: false

  alias Offloader.Config.Loader

  # repo root: test/offloader/config → up 4 → server → repo
  @example Path.expand("../../../../examples/customer-analytics", __DIR__)

  # An Agent-backed fake so the retry test can fail the first list then succeed.
  defmodule FakeGcs do
    @behaviour Offloader.Source.GcsClient

    def start(opts), do: {:ok, _} = Agent.start_link(fn -> Map.new(opts) end, name: __MODULE__)
    # start_link ties the Agent to the test process, so on_exit may run stop/0 once
    # that process (and the link) has begun tearing the Agent down — whereis can still
    # return a pid that exits before Agent.stop reaches it. Tolerate that race.
    def stop do
      if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)
    catch
      :exit, _ -> :ok
    end

    @impl true
    def list_objects(_bucket, prefix) do
      remaining =
        Agent.get_and_update(__MODULE__, fn s ->
          n = Map.get(s, :list_fail_times, 0)
          {n, Map.put(s, :list_fail_times, max(n - 1, 0))}
        end)

      cond do
        remaining > 0 -> {:error, {:gcs_api_error, 503}}
        err = Agent.get(__MODULE__, &Map.get(&1, :list_error)) -> {:error, err}
        true -> {:ok, filter(Agent.get(__MODULE__, &Map.get(&1, :objects, [])), prefix)}
      end
    end

    @impl true
    def get_object(_bucket, name) do
      Agent.update(__MODULE__, &Map.update(&1, :get_calls, 1, fn n -> n + 1 end))

      case Agent.get(__MODULE__, &Map.get(&1, :bodies, %{}))[name] do
        nil -> {:error, {:not_found, name}}
        body -> {:ok, body}
      end
    end

    def get_calls, do: Agent.get(__MODULE__, &Map.get(&1, :get_calls, 0))

    defp filter(objects, prefix),
      do: Enum.filter(objects, &String.starts_with?(&1["name"], prefix))
  end

  defp with_fake(opts, env_key \\ :gcs_source_client) do
    prev = Application.get_env(:offloader, env_key)
    FakeGcs.start(opts)
    Application.put_env(:offloader, env_key, FakeGcs)

    on_exit(fn ->
      FakeGcs.stop()

      if prev,
        do: Application.put_env(:offloader, env_key, prev),
        else: Application.delete_env(:offloader, env_key)
    end)
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && eventually(fun, deadline)
    end
  end

  defp tmp_cache do
    dir = Path.join(System.tmp_dir!(), "offl_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Build GCS list items + bodies from the example project's yaml files under `prefix`.
  defp example_objects(prefix) do
    Path.wildcard(Path.join(@example, "**/*.{yml,yaml}"))
    |> Enum.reduce({[], %{}}, fn path, {objs, bodies} ->
      name = "#{prefix}/#{Path.relative_to(path, @example)}"
      body = File.read!(path)

      obj = %{
        "name" => name,
        "size" => Integer.to_string(byte_size(body)),
        "updated" => "2026-07-02T00:00:00Z"
      }

      {[obj | objs], Map.put(bodies, name, body)}
    end)
  end

  describe "local config" do
    test "loads a local project path unchanged" do
      assert {:ok, catalog} = Loader.load(Path.join(@example, "offloader.yml"), tmp_cache())
      assert Map.has_key?(catalog.datasets, "customer_usage")
    end
  end

  describe "remote config (gs://)" do
    test "fetches the project tree into <cache>/config and loads it" do
      {objects, bodies} = example_objects("proj")
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()

      assert {:ok, catalog} = Loader.load("gs://my-bucket/proj", cache)
      assert Map.has_key?(catalog.datasets, "customer_usage")
      assert map_size(catalog.endpoints) == 3
      assert File.exists?(Path.join([cache, "config", "offloader.yml"]))
    end

    test "fetches companion data (a manifest.json + snapshot file), not just yaml" do
      {objects, bodies} = example_objects("proj")

      # A relative manifest points at these; a self-contained bucket project must bring
      # them down too, not only the .yml config.
      data = [
        {"proj/data/x/manifest.json", ~s({"snapshot_id":"s1"})},
        {"proj/data/x/snap.parquet", "PAR1"}
      ]

      objects =
        objects ++
          Enum.map(data, fn {name, body} ->
            %{"name" => name, "size" => Integer.to_string(byte_size(body)), "updated" => "t"}
          end)

      bodies = Enum.reduce(data, bodies, fn {name, body}, acc -> Map.put(acc, name, body) end)
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()

      assert {:ok, _catalog} = Loader.load("gs://my-bucket/proj", cache)
      assert File.read!(Path.join([cache, "config", "data/x/manifest.json"])) =~ "s1"
      assert File.exists?(Path.join([cache, "config", "data/x/snap.parquet"]))
    end

    test "retries a transient 5xx and then succeeds" do
      {objects, bodies} = example_objects("proj")
      with_fake(objects: objects, bodies: bodies, list_fail_times: 1)
      assert {:ok, _catalog} = Loader.load("gs://my-bucket/proj", tmp_cache())
    end

    test "no yaml objects under the prefix is a clear error" do
      with_fake(objects: [], bodies: %{})

      assert {:error, {:no_config_objects, "my-bucket", "proj"}} =
               Loader.load("gs://my-bucket/proj", tmp_cache())
    end

    test "a tree missing offloader.yml fails validation, not with a crash" do
      body = "id: x\n"

      objects = [
        %{
          "name" => "proj/datasets/x.yml",
          "size" => Integer.to_string(byte_size(body)),
          "updated" => "t"
        }
      ]

      with_fake(objects: objects, bodies: %{"proj/datasets/x.yml" => body})
      assert {:error, {:config_invalid, _}} = Loader.load("gs://my-bucket/proj", tmp_cache())
    end

    test "a malformed offloader.yml is a config error, not a crash" do
      {objects, bodies} = example_objects("proj")
      # a scalar (non-mapping) offloader.yml is rejected by the catalog loader
      bodies = Map.put(bodies, "proj/offloader.yml", "just a string, not a mapping")
      with_fake(objects: objects, bodies: bodies)
      assert {:error, {:config_invalid, _}} = Loader.load("gs://my-bucket/proj", tmp_cache())
    end

    test "a too-large tree is refused before any download" do
      huge = Integer.to_string(33 * 1024 * 1024)
      objects = [%{"name" => "proj/offloader.yml", "size" => huge, "updated" => "t"}]
      with_fake(objects: objects, bodies: %{})
      assert {:error, {:config_too_large, _}} = Loader.load("gs://my-bucket/proj", tmp_cache())
    end

    test "bad credentials (401/unauthorized) are not retried and surface" do
      with_fake(objects: [], bodies: %{}, list_error: :unauthorized)
      assert {:error, :unauthorized} = Loader.load("gs://my-bucket/proj", tmp_cache())
    end

    test "a crafted object name that escapes the config dir is rejected" do
      body = "version: 1\n"
      # name resolves to a `..`-escaping relative path under the prefix
      objects = [
        %{
          "name" => "proj/../evil.yml",
          "size" => Integer.to_string(byte_size(body)),
          "updated" => "t"
        }
      ]

      with_fake(objects: objects, bodies: %{"proj/../evil.yml" => body})
      cache = tmp_cache()

      assert {:error, {:unsafe_config_path, _}} = Loader.load("gs://my-bucket/proj", cache)
      refute File.exists?(Path.join(cache, "evil.yml"))
    end
  end

  describe "config generations" do
    # The whole example tree, data included, listed in name order as GCS does.
    defp project_objects(prefix) do
      Path.wildcard(Path.join(@example, "**/*.{yml,yaml,json,csv}"))
      |> Enum.reduce({[], %{}}, fn path, {objs, bodies} ->
        name = "#{prefix}/#{Path.relative_to(path, @example)}"
        body = File.read!(path)
        obj = %{"name" => name, "size" => Integer.to_string(byte_size(body)), "updated" => "t"}
        {[obj | objs], Map.put(bodies, name, body)}
      end)
      |> then(fn {objs, bodies} -> {Enum.sort_by(objs, & &1["name"]), bodies} end)
    end

    defp config_file(cache, rel), do: File.read!(Path.join([cache, "config", rel]))
    defp generations(cache), do: File.ls!(Path.join(cache, "configs"))

    test "a failed fetch leaves the current config untouched and keeps no partial copy" do
      {objects, bodies} = project_objects("proj")
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()
      assert {:ok, _} = Loader.load("gs://my-bucket/proj", cache)
      csv = Path.join(cache, "config/data/customer_usage/customer_usage.csv")
      before = File.read!(csv)

      # The first object in list order fails, after the old copy would already be wiped.
      Agent.update(
        FakeGcs,
        &%{&1 | bodies: Map.delete(bodies, "proj/data/customer_usage/customer_usage.csv")}
      )

      assert {:error, {:fetch_failed, _, _}} = Loader.load("gs://my-bucket/proj", cache)

      assert File.read(csv) == {:ok, before}
      assert length(generations(cache)) == 1
    end

    test "an invalid revision is never activated" do
      {objects, bodies} = project_objects("proj")
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()
      assert {:ok, _} = Loader.load("gs://my-bucket/proj", cache)

      bodies =
        bodies
        |> Map.update!(
          "proj/data/customer_usage/manifest.json",
          &String.replace(&1, "r0007", "r0099")
        )
        |> Map.update!("proj/offloader.yml", &(&1 <> "\nbogus_key: 1\n"))

      Agent.update(FakeGcs, &%{&1 | bodies: bodies})
      assert {:error, {:config_invalid, _}} = Loader.load("gs://my-bucket/proj", cache)

      assert config_file(cache, "data/customer_usage/manifest.json") =~ "r0007"
      assert length(generations(cache)) == 1
    end

    test "a valid revision becomes current; the catalog reads it through the stable path" do
      {objects, bodies} = project_objects("proj")
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()
      assert {:ok, first} = Loader.load("gs://my-bucket/proj", cache)

      bodies =
        Map.update!(
          bodies,
          "proj/data/customer_usage/manifest.json",
          &String.replace(&1, "r0007", "r0099")
        )

      Agent.update(FakeGcs, &%{&1 | bodies: bodies})
      assert {:ok, second} = Loader.load("gs://my-bucket/proj", cache)

      assert first.config_dir == Path.join(cache, "config")
      assert second.config_dir == first.config_dir
      assert config_file(cache, "data/customer_usage/manifest.json") =~ "r0099"
      assert length(generations(cache)) == 2
    end

    test "prune keeps the current generation, the newest two, and any a snapshot still reads" do
      cache = tmp_cache()
      root = Path.join(cache, "configs")
      for g <- ~w(1-a 2-b 3-c 4-d 5-e), do: File.mkdir_p!(Path.join([root, g, "data"]))
      File.ln_s!("configs/3-c", Path.join(cache, "config"))
      in_use = Path.join([root, "1-a", "data"])

      :ok = Loader.prune(cache, [in_use, nil])

      assert Enum.sort(generations(cache)) == ~w(1-a 3-c 4-d 5-e)
    end

    @csv "proj/data/customer_usage/customer_usage.csv"

    # remote_scan reads the snapshot's files from the config tree on every request.
    defp remote_scan_project do
      {objects, bodies} = project_objects("proj")
      replace = &String.replace(&1, "serving_mode: local_table", "serving_mode: remote_scan")
      {objects, Map.new(bodies, fn {name, body} -> {name, replace.(body)} end)}
    end

    defp boot(cache) do
      {:ok, rt} =
        Offloader.Runtime.start_link(
          name: nil,
          config_path: "gs://my-bucket/proj",
          cache_dir: cache
        )

      on_exit(fn -> Offloader.TestSupport.stop_if_alive(rt) end)
      rt
    end

    # A distinct `from` per call, so the response cache never answers instead of the files.
    defp serve(rt, from) do
      params = %{"from" => from, "to" => "2026-06-01"}
      Offloader.Runtime.serve(rt, "customer_usage_summary", "tenant_acme", params, "r")
    end

    test "a remote_scan snapshot keeps serving through a failed fetch and an invalid revision" do
      {objects, bodies} = remote_scan_project()
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()
      rt = boot(cache)

      invalid =
        bodies
        |> Map.update!(
          "proj/data/customer_usage/manifest.json",
          &String.replace(&1, "r0007", "r0099")
        )
        |> Map.update!("proj/offloader.yml", &(&1 <> "\nbogus_key: 1\n"))

      Agent.update(FakeGcs, &%{&1 | bodies: invalid})
      assert {:error, {:config_invalid, _}} = Loader.load("gs://my-bucket/proj", cache)
      Agent.update(FakeGcs, &%{&1 | bodies: Map.delete(bodies, @csv)})
      assert {:error, {:fetch_failed, _, _}} = Loader.load("gs://my-bucket/proj", cache)

      assert {:ok, %{meta: %{serving_mode: "remote_scan"}}} = serve(rt, "2026-05-30")
      assert {:ok, "2026-06-01T00:00:00Z_r0007"} = Offloader.Runtime.refresh(rt, "customer_usage")
    end

    test "a generation stays while a serving snapshot reads it, even after the bucket drops it" do
      {objects, bodies} = remote_scan_project()
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()
      rt = boot(cache)
      [first] = generations(cache)

      # The YAML is unchanged, so the snapshot (and its file list) stays; only the bucket
      # lost the CSV. Three revisions push the first generation out of the newest two.
      Agent.update(FakeGcs, fn s ->
        %{
          s
          | objects: Enum.reject(objects, &(&1["name"] == @csv)),
            bodies: Map.delete(bodies, @csv)
        }
      end)

      for _ <- 1..3, do: assert({:ok, _} = Loader.load("gs://my-bucket/proj", cache))
      {:ok, catalog} = Loader.load("gs://my-bucket/proj", cache)
      :ok = Offloader.Runtime.reload(rt, catalog)

      assert eventually(fn -> length(generations(cache)) == 3 end)
      assert first in generations(cache)
      refute File.exists?(Path.join(cache, "config/data/customer_usage/customer_usage.csv"))
      assert {:ok, _} = serve(rt, "2026-05-31")
    end

    test "a build whose generation is pruned while it runs never goes live" do
      {objects, bodies} = remote_scan_project()
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()
      rt = boot(cache)
      {:ok, _} = Loader.load("gs://my-bucket/proj", cache)
      building = cache |> generations() |> Enum.sort() |> List.last()

      # The refresh builds from `building`, then waits for the paused Runtime. Meanwhile a newer
      # config lands and `building` is deleted, as a prune after two newer configs would.
      :ok = :sys.suspend(rt)
      refresh = Task.async(fn -> Offloader.Runtime.refresh(rt, "customer_usage") end)

      assert eventually(fn ->
               match?({:message_queue_len, n} when n > 0, Process.info(rt, :message_queue_len))
             end)

      {:ok, _} = Loader.load("gs://my-bucket/proj", cache)
      File.rm_rf!(Path.join([cache, "configs", building]))
      :ok = :sys.resume(rt)
      Task.await(refresh)

      assert File.dir?(Offloader.Runtime.snapshot_active(rt, "customer_usage").dir)
      assert {:ok, _} = serve(rt, "2026-05-31")
    end

    test "a GCS folder placeholder object is skipped" do
      {objects, bodies} = project_objects("proj")
      placeholder = %{"name" => "proj/data/", "size" => "0", "updated" => "t"}
      objects = Enum.sort_by([placeholder | objects], & &1["name"])
      with_fake(objects: objects, bodies: Map.put(bodies, "proj/data/", ""))

      assert {:ok, _} = Loader.load("gs://my-bucket/proj", tmp_cache())
    end

    test "a tree that can't be written is discarded" do
      {objects, bodies} = project_objects("proj")
      # A file named `datasets` blocks the `datasets/` directory the next object needs.
      blocker = %{"name" => "proj/datasets", "size" => "1", "updated" => "t"}
      objects = Enum.sort_by([blocker | objects], & &1["name"])
      with_fake(objects: objects, bodies: Map.put(bodies, "proj/datasets", "x"))
      cache = tmp_cache()

      assert {:error, {:write_failed, "datasets/customer_usage.yml", _}} =
               Loader.load("gs://my-bucket/proj", cache)

      assert generations(cache) == []
    end

    test "a single config tree from an older version is replaced by the generation link" do
      {objects, bodies} = project_objects("proj")
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()
      File.mkdir_p!(Path.join(cache, "config/datasets"))
      File.write!(Path.join(cache, "config/stale.yml"), "old")

      assert {:ok, _} = Loader.load("gs://my-bucket/proj", cache)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(cache, "config"))
      refute File.exists?(Path.join(cache, "config/stale.yml"))
    end
  end

  describe "local config behind someone else's symlink" do
    # git-sync and Kubernetes ConfigMap volumes swap a link to a new directory and then delete
    # the old one. A snapshot must keep following the link, not pin the deleted target.
    defp release(root, name) do
      dir = Path.join(root, name)
      File.cp_r!(@example, dir)

      for file <- Path.wildcard(Path.join(dir, "endpoints/*.yml")) do
        body = File.read!(file)

        File.write!(
          file,
          String.replace(body, "serving_mode: local_table", "serving_mode: remote_scan")
        )
      end

      dir
    end

    defp point(root, name) do
      File.ln_s!(name, Path.join(root, "current.next"))
      File.rename!(Path.join(root, "current.next"), Path.join(root, "current"))
    end

    test "a remote_scan snapshot keeps serving after the link moves and the old target goes" do
      root = tmp_cache()
      old = release(root, "v1")
      point(root, "v1")

      {:ok, rt} =
        Offloader.Runtime.start_link(
          name: nil,
          config_path: Path.join(root, "current/offloader.yml"),
          cache_dir: Path.join(root, "cache")
        )

      on_exit(fn -> Offloader.TestSupport.stop_if_alive(rt) end)
      params = &%{"from" => &1, "to" => "2026-06-01"}

      serve =
        &Offloader.Runtime.serve(rt, "customer_usage_summary", "tenant_acme", params.(&1), "r")

      assert {:ok, _} = serve.("2026-05-30")

      release(root, "v2")
      point(root, "v2")
      File.rm_rf!(old)

      assert {:ok, _} = serve.("2026-05-31")
    end
  end

  describe "remote config (s3://)" do
    test "fetches the project tree from s3:// via the S3 client seam" do
      {objects, bodies} = example_objects("proj")
      with_fake([objects: objects, bodies: bodies], :s3_source_client)
      cache = tmp_cache()

      assert {:ok, catalog} = Loader.load("s3://my-bucket/proj", cache)
      assert Map.has_key?(catalog.datasets, "customer_usage")
      assert File.exists?(Path.join([cache, "config", "offloader.yml"]))
    end

    test "digest reads via LIST for s3:// too" do
      {objects, _bodies} = example_objects("proj")
      with_fake([objects: objects, bodies: %{}], :s3_source_client)
      assert {:ok, _} = Loader.digest("s3://my-bucket/proj")
    end
  end

  describe "unsupported schemes" do
    test "https:// config is rejected" do
      assert {:error, {:unsupported_config_scheme, "https"}} =
               Loader.load("https://host/path", tmp_cache())
    end
  end

  describe "digest (change detection)" do
    test "is stable for an unchanged tree and reads via LIST only (no downloads)" do
      {objects, _bodies} = example_objects("proj")
      with_fake(objects: objects, bodies: %{})

      assert {:ok, d1} = Loader.digest("gs://my-bucket/proj")
      assert {:ok, d2} = Loader.digest("gs://my-bucket/proj")
      assert d1 == d2
      # digest must never download objects — only list them
      assert FakeGcs.get_calls() == 0
    end

    test "changes when an object's updated/size changes" do
      {objects, _bodies} = example_objects("proj")
      with_fake(objects: objects, bodies: %{})
      assert {:ok, before} = Loader.digest("gs://my-bucket/proj")

      bumped = Enum.map(objects, fn o -> Map.put(o, "updated", "2026-08-01T00:00:00Z") end)
      FakeGcs.stop()
      FakeGcs.start(objects: bumped, bodies: %{})
      assert {:ok, later} = Loader.digest("gs://my-bucket/proj")
      refute before == later
    end

    test "works for a local path (mtime/size based)" do
      assert {:ok, token} = Loader.digest(Path.join(@example, "offloader.yml"))
      assert is_binary(token)
    end
  end

  describe "boot integration" do
    test "the Runtime boots from a gs:// config path and adopts the fetched catalog" do
      {objects, bodies} = example_objects("proj")
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()

      {:ok, rt} =
        Offloader.Runtime.start_link(
          name: nil,
          config_path: "gs://my-bucket/proj",
          cache_dir: cache
        )

      on_exit(fn -> Offloader.TestSupport.stop_if_alive(rt) end)

      catalog = Offloader.Runtime.catalog(rt)
      assert catalog
      assert Map.has_key?(catalog.datasets, "customer_usage")
      assert map_size(catalog.endpoints) == 3
      # the fetch physically happened during boot
      assert File.exists?(Path.join([cache, "config", "offloader.yml"]))
    end
  end

  # A container that starts while the bucket can't be read serves the config it last fetched
  # from the same path, so a GCS or credentials outage doesn't stop a restart from serving.
  describe "a boot while the config bucket can't be read" do
    defp outage(error), do: Agent.update(FakeGcs, &Map.put(&1, :list_error, error))

    defp fetched_cache do
      {objects, bodies} = project_objects("proj")
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()
      assert {:ok, %{config_from_cache: false}} = Loader.load("gs://my-bucket/proj", cache)
      cache
    end

    defp boot_load(path, cache), do: Loader.load(path, cache, fallback_to_cached: true)

    defp object(name, body \\ "x"),
      do:
        {%{"name" => name, "size" => Integer.to_string(byte_size(body)), "updated" => "t"}, body}

    # Add objects to the bucket's listing (and their bodies) for the next fetch.
    defp add_objects(pairs) do
      Agent.update(FakeGcs, fn s ->
        %{
          s
          | objects: s.objects ++ Enum.map(pairs, &elem(&1, 0)),
            bodies: Map.merge(s.bodies, Map.new(pairs, fn {o, b} -> {o["name"], b} end))
        }
      end)
    end

    test "serves the config last fetched from the same path" do
      cache = fetched_cache()
      [generation] = generations(cache)
      outage({:gcs_api_error, 503})

      assert {:ok, catalog} = boot_load("gs://my-bucket/proj", cache)
      assert catalog.config_dir == Path.join(cache, "config")
      assert catalog.config_from_cache
      assert Map.has_key?(catalog.datasets, "customer_usage")
      assert generations(cache) == [generation]
    end

    test "a trailing slash names the same path" do
      cache = fetched_cache()
      outage({:gcs_api_error, 403})
      assert {:ok, _} = boot_load("gs://my-bucket/proj/", cache)
    end

    test "counts bad credentials as the bucket being unreadable" do
      cache = fetched_cache()
      outage(:unauthorized)
      assert {:ok, _} = boot_load("gs://my-bucket/proj", cache)
    end

    test "fails when nothing was fetched before" do
      with_fake(objects: [], list_error: {:gcs_api_error, 503})
      assert {:error, {:gcs_api_error, 503}} = boot_load("gs://my-bucket/proj", tmp_cache())
    end

    test "never serves a config fetched from another path" do
      # A mistyped new OFFLOADER_CONFIG must fail loudly, not boot the old project.
      cache = fetched_cache()
      outage({:gcs_api_error, 403})
      assert {:error, {:gcs_api_error, 403}} = boot_load("gs://my-bucket/other", cache)
    end

    test "fails when the bucket no longer exists" do
      # Deleting the bucket is an answer, not an outage, and retires the deployment.
      cache = fetched_cache()
      outage({:gcs_api_error, 404})
      assert {:error, {:gcs_api_error, 404}} = boot_load("gs://my-bucket/proj", cache)
    end

    test "doesn't trust a generation that never recorded its path" do
      cache = fetched_cache()
      File.rm!(Path.join([cache, "config", ".source"]))
      outage({:gcs_api_error, 403})
      assert {:error, {:gcs_api_error, 403}} = boot_load("gs://my-bucket/proj", cache)
    end

    test "fails when the bucket answers without a usable config" do
      cache = fetched_cache()
      Agent.update(FakeGcs, &%{&1 | objects: []})
      assert {:error, {:no_config_objects, _, _}} = boot_load("gs://my-bucket/proj", cache)
    end

    test "fails when the bucket's tree can't be used, or the disk can't hold it" do
      cache = fetched_cache()

      cases = [
        too_many_config_files: for(i <- 1..500, do: object("proj/extra/#{i}.txt")),
        config_too_large: [
          {%{"name" => "proj/big.bin", "size" => "40000000", "updated" => "t"}, ""}
        ],
        unsafe_config_path: [object("proj/../evil.yml", "version: 1\n")],
        # A file where the next object needs a directory.
        write_failed: [object("proj/zz"), object("proj/zz/a.txt")]
      ]

      for {reason, extra} <- cases do
        {objects, bodies} = project_objects("proj")
        Agent.update(FakeGcs, &%{&1 | objects: objects, bodies: bodies})
        add_objects(extra)

        assert {:error, error} = boot_load("gs://my-bucket/proj", cache)
        assert elem(error, 0) == reason
      end
    end

    test "records the listing digest, so sync starts from the running config" do
      cache = fetched_cache()
      {:ok, running} = Loader.running_digest("gs://my-bucket/proj", cache)
      assert {:ok, ^running} = Loader.digest("gs://my-bucket/proj")

      # A newer revision lands while the pod is down, and its boot can't read the bucket.
      Agent.update(FakeGcs, fn s ->
        %{s | objects: Enum.map(s.objects, &Map.put(&1, "updated", "later"))}
      end)

      outage({:gcs_api_error, 403})
      assert {:ok, %{config_from_cache: true}} = boot_load("gs://my-bucket/proj", cache)

      Agent.update(FakeGcs, &Map.delete(&1, :list_error))
      assert {:ok, live} = Loader.digest("gs://my-bucket/proj")
      assert {:ok, ^running} = Loader.running_digest("gs://my-bucket/proj", cache)
      refute live == running
    end

    test "fails when the cached config no longer validates" do
      cache = fetched_cache()
      File.write!(Path.join([cache, "config", "offloader.yml"]), "bogus_key: 1\n", [:append])
      outage({:gcs_api_error, 403})
      assert {:error, {:gcs_api_error, 403}} = boot_load("gs://my-bucket/proj", cache)
    end

    test "only a boot falls back: a sync's load reports the outage" do
      cache = fetched_cache()
      outage({:gcs_api_error, 403})
      assert {:error, {:gcs_api_error, 403}} = Loader.load("gs://my-bucket/proj", cache)
    end

    test "a restart during the outage keeps serving the warm snapshot" do
      {objects, bodies} = project_objects("proj")
      with_fake(objects: objects, bodies: bodies)
      cache = tmp_cache()
      rt = boot(cache)
      assert {:ok, _} = serve(rt, "2026-05-30")
      Offloader.TestSupport.stop_if_alive(rt)

      # Only the warm DuckDB table can serve now: the cached tree loses its data file.
      File.rm!(Path.join(cache, "config/data/customer_usage/customer_usage.csv"))
      outage({:gcs_api_error, 403})
      rt = boot(cache)

      assert Offloader.Runtime.ready?(rt)

      assert {:ok, %{meta: %{snapshot_id: "2026-06-01T00:00:00Z_r0007"}}} =
               serve(rt, "2026-05-31")

      diag = Offloader.Runtime.diagnostics(rt)
      assert diag.config_from_cache
      assert Offloader.Metrics.to_prometheus(diag) =~ "offloader_config_from_cache 1"
    end
  end
end
