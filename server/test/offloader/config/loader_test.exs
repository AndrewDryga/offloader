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
    def stop, do: if(pid = Process.whereis(__MODULE__), do: Agent.stop(pid))

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

      on_exit(fn -> if Process.alive?(rt), do: GenServer.stop(rt) end)

      catalog = Offloader.Runtime.catalog(rt)
      assert catalog
      assert Map.has_key?(catalog.datasets, "customer_usage")
      assert map_size(catalog.endpoints) == 3
      # the fetch physically happened during boot
      assert File.exists?(Path.join([cache, "config", "offloader.yml"]))
    end
  end
end
