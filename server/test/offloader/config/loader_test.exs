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
      in_use = Offloader.Manifest.real_path(Path.join([root, "1-a", "data"]))

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
end
