defmodule Offloader.DynamicRefreshTest do
  # Dynamic source refresh: per-dataset workers re-resolve the latest snapshot,
  # skip when unchanged, isolate failures, and the runtime warm-starts from the
  # sidecar + persistent DuckDB file. async: false — global app env seams + Runtime.
  use ExUnit.Case, async: false

  alias Offloader.Runtime

  @project Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)

  defmodule FakeGcs do
    @behaviour Offloader.Source.GcsClient

    # Seeded via :persistent_term so worker processes (not the test process) see it.
    def seed(objects, bodies) do
      :persistent_term.put({__MODULE__, :objects}, objects)
      :persistent_term.put({__MODULE__, :bodies}, bodies)
    end

    @impl true
    def list_objects(_bucket, prefix) do
      case :persistent_term.get({__MODULE__, :objects}, []) do
        {:error, _} = err -> err
        objects -> {:ok, Enum.filter(objects, &String.starts_with?(&1["name"], prefix))}
      end
    end

    @impl true
    def get_object(_bucket, name) do
      case :persistent_term.get({__MODULE__, :bodies}, %{})[name] do
        nil -> {:error, {:not_found, name}}
        body -> {:ok, body}
      end
    end
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "offl_dyn_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp start_runtime(config_path, dir, opts \\ []) do
    {:ok, rt} =
      Runtime.start_link(
        Keyword.merge([name: nil, config_path: config_path, cache_dir: dir], opts)
      )

    on_exit(fn -> if Process.alive?(rt), do: GenServer.stop(rt) end)
    rt
  end

  describe "skip-if-unchanged" do
    test "a manual refresh forces; the boot refresh of a warm cache is :unchanged" do
      dir = tmp_dir()
      rt = start_runtime(@project, dir)

      # Manual refresh of the SAME snapshot still returns ok (forced re-materialize).
      assert {:ok, "2026-06-01T00:00:00Z_r0007"} = Runtime.refresh(rt, "customer_usage")

      # Restart on the same cache dir: warm start seeds the snapshot, the boot
      # refresh sees the same snapshot_id and records :unchanged — and serving works
      # immediately.
      GenServer.stop(rt)
      rt2 = start_runtime(@project, dir)

      assert Runtime.ready?(rt2)
      state = Runtime.snapshot_state(rt2, "customer_usage")
      assert state.active.snapshot_id == "2026-06-01T00:00:00Z_r0007"
      assert state.last_attempted.status == :unchanged

      params = %{"from" => "2026-05-30", "to" => "2026-06-01"}

      assert {:ok, resp} =
               Runtime.serve(rt2, "customer_usage_summary", "tenant_acme", params, "r")

      assert resp.meta.snapshot_id == "2026-06-01T00:00:00Z_r0007"
    end

    test "warm start serves from disk even when the manifest is no longer loadable" do
      dir = tmp_dir()

      # First boot from a COPY of the project whose manifest we can break later.
      project_dir = Path.join(tmp_dir(), "project")
      File.mkdir_p!(project_dir)
      File.cp_r!(Path.dirname(@project), project_dir)
      config = Path.join(project_dir, "offloader.yml")

      rt = start_runtime(config, dir)
      assert Runtime.ready?(rt)
      GenServer.stop(rt)

      # Break the manifest: the refresh will be rejected, but the warm snapshot serves.
      manifest = Path.join(project_dir, "data/customer_usage/manifest.json")
      File.write!(manifest, "{not json")

      rt2 = start_runtime(config, dir)
      assert Runtime.ready?(rt2)

      state = Runtime.snapshot_state(rt2, "customer_usage")
      assert state.active.snapshot_id == "2026-06-01T00:00:00Z_r0007"
      assert state.last_attempted.status == :rejected

      params = %{"from" => "2026-05-30", "to" => "2026-06-01"}
      assert {:ok, _} = Runtime.serve(rt2, "customer_usage_summary", "tenant_acme", params, "r")
    end
  end

  describe "dynamic (databricks) source datasets" do
    defp write_source_project(dir, parquet_path) do
      config_dir = Path.join(dir, "config")
      File.mkdir_p!(Path.join(config_dir, "datasets"))
      File.mkdir_p!(Path.join(config_dir, "endpoints"))

      File.write!(Path.join(config_dir, "offloader.yml"), """
      version: 1
      auth: none
      datasets_dir: datasets
      endpoints_dir: endpoints
      """)

      File.write!(Path.join(config_dir, "datasets/champs.yml"), """
      id: champs
      source:
        type: databricks
        bucket: fake-bucket
        prefix: prod/lol/champs/
      schema:
        - { name: champion_id, type: VARCHAR }
        - { name: patch, type: VARCHAR }
        - { name: data, type: JSON }
      """)

      File.write!(Path.join(config_dir, "endpoints/champs.yml"), """
      name: champs
      version: 1
      owner: t@example.com
      description: champs
      dataset: champs
      params:
        - { name: champion_id, type: string, required: true }
      query:
        select:
          - { as: champion_id, column: champion_id }
          - { as: data, column: data }
        filters:
          - { column: champion_id, op: eq, param: champion_id }
      columns: [champion_id, data]
      """)

      # The fake bucket: one committed tid whose part is served from a local file
      # (file:// is not supported by the resolver URL builder, so point the fake
      # commit at the local parquet via the manifest "path" indirection — the
      # resolver emits https URLs; instead we exercise the LOCAL path by using a
      # file path in `added` and asserting via the https prefix override below).
      FakeGcs.seed(
        [%{"name" => "prod/lol/champs/_committed_42", "updated" => "2026-07-01T00:00:00Z"}],
        %{
          "prod/lol/champs/_committed_42" =>
            Jason.encode!(%{added: [Path.basename(parquet_path)], removed: []})
        }
      )

      Path.join(config_dir, "offloader.yml")
    end

    test "a source dataset resolves, materializes, and serves via the worker" do
      # Serve the example public-metrics parquet over the "https" URL the resolver
      # builds — by pointing gcs_base_url at a local static file server.
      parquet =
        Path.expand(
          "../../../examples/public-metrics/data/champion_stats/champion_stats.parquet",
          __DIR__
        )

      # Local HTTP server that returns the parquet for ANY path.
      defmodule ParquetPlug do
        @behaviour Plug
        def init(o), do: o

        def call(conn, _o) do
          body = File.read!(:persistent_term.get({__MODULE__, :file}))
          Plug.Conn.send_resp(conn, 200, body)
        end
      end

      :persistent_term.put({ParquetPlug, :file}, parquet)

      {port, _} =
        Enum.find_value(47_651..47_660, fn p ->
          case Bandit.start_link(plug: ParquetPlug, port: p, ip: :loopback) do
            {:ok, pid} -> {p, pid}
            _ -> nil
          end
        end)

      prev_base = Application.get_env(:offloader, :gcs_base_url)
      prev_client = Application.get_env(:offloader, :gcs_source_client)
      Application.put_env(:offloader, :gcs_base_url, "http://127.0.0.1:#{port}")
      Application.put_env(:offloader, :gcs_source_client, FakeGcs)

      on_exit(fn ->
        if prev_base,
          do: Application.put_env(:offloader, :gcs_base_url, prev_base),
          else: Application.delete_env(:offloader, :gcs_base_url)

        if prev_client,
          do: Application.put_env(:offloader, :gcs_source_client, prev_client),
          else: Application.delete_env(:offloader, :gcs_source_client)
      end)

      dir = tmp_dir()
      config = write_source_project(dir, "champion_stats.parquet")
      rt = start_runtime(config, dir)

      assert Runtime.ready?(rt)
      state = Runtime.snapshot_state(rt, "champs")
      assert state.active.snapshot_id == "tid_42"

      assert {:ok, resp} = Runtime.serve(rt, "champs", nil, %{"champion_id" => "1"}, "r")
      assert [%{"champion_id" => "1", "data" => %{"num_games" => 136_068}}] = resp.data
    end

    test "one failing source never blocks a healthy dataset's refresh" do
      # Two datasets: a healthy STATIC one and a databricks one whose listings error.
      dir = tmp_dir()
      config_dir = Path.join(dir, "config")
      File.mkdir_p!(Path.join(config_dir, "datasets"))
      File.mkdir_p!(Path.join(config_dir, "endpoints"))
      File.mkdir_p!(Path.join(config_dir, "data"))

      example_data = Path.expand("../../../examples/customer-analytics/data", __DIR__)
      File.cp_r!(example_data, Path.join(config_dir, "data"))

      File.write!(Path.join(config_dir, "offloader.yml"), """
      version: 1
      auth: none
      datasets_dir: datasets
      endpoints_dir: endpoints
      """)

      File.write!(Path.join(config_dir, "datasets/usage.yml"), """
      id: customer_usage
      manifest: data/customer_usage/manifest.json
      schema:
        - { name: usage_date, type: DATE }
        - { name: tenant_id, type: VARCHAR }
        - { name: account_id, type: VARCHAR }
        - { name: product_area, type: VARCHAR }
        - { name: active_users, type: INTEGER }
        - { name: api_calls, type: BIGINT }
        - { name: storage_gb, type: DOUBLE }
        - { name: plan, type: VARCHAR }
      """)

      File.write!(Path.join(config_dir, "datasets/broken.yml"), """
      id: broken
      source:
        type: databricks
        bucket: fake-bucket
        prefix: prod/lol/broken/
      schema:
        - { name: champion_id, type: VARCHAR }
      """)

      File.write!(Path.join(config_dir, "endpoints/usage.yml"), """
      name: usage
      version: 1
      owner: t@example.com
      description: usage
      dataset: customer_usage
      params:
        - { name: account_id, type: string, required: true }
      query:
        select:
          - { as: account_id, column: account_id }
          - { as: api_calls, column: api_calls }
        filters:
          - { column: account_id, op: eq, param: account_id }
      columns: [account_id, api_calls]
      """)

      prev_client = Application.get_env(:offloader, :gcs_source_client)
      Application.put_env(:offloader, :gcs_source_client, FakeGcs)

      on_exit(fn ->
        if prev_client,
          do: Application.put_env(:offloader, :gcs_source_client, prev_client),
          else: Application.delete_env(:offloader, :gcs_source_client)
      end)

      FakeGcs.seed({:error, {:gcs_api_error, 503}}, %{})

      rt = start_runtime(Path.join(config_dir, "offloader.yml"), dir)

      # The broken source dataset recorded a failed attempt; the static one serves.
      broken = Runtime.snapshot_state(rt, "broken")
      assert broken.active == nil
      assert broken.last_attempted.status == :failed

      usage = Runtime.snapshot_state(rt, "customer_usage")
      assert usage.active.snapshot_id == "2026-06-01T00:00:00Z_r0007"

      assert {:ok, resp} = Runtime.serve(rt, "usage", nil, %{"account_id" => "acct_apollo"}, "r")
      assert resp.data != []
      assert Enum.all?(resp.data, &(&1["account_id"] == "acct_apollo"))

      # A manual refresh of the healthy dataset keeps working while the broken one fails.
      assert {:ok, _} = Runtime.refresh(rt, "customer_usage")
      assert {:error, :failed} = Runtime.refresh(rt, "broken")
    end
  end
end
