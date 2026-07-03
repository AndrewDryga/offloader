defmodule OffloaderWeb.ResilienceHTTPTest do
  # The documented 503 family at the HTTP layer where clients actually see it
  # (docs/api.md: "retry with backoff; it clears"), plus cache correctness across a
  # snapshot swap and the interval poll loop. async: false — named Runtime singleton,
  # and tests mutate their own tmp copies of the example project.
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Offloader.Runtime

  @endpoint OffloaderWeb.ApiEndpoint
  @public Path.expand("../../../examples/public-metrics", __DIR__)

  defp tmp!(tag) do
    dir = Path.join(System.tmp_dir!(), "offl_res_#{tag}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A mutable copy of the bundled public project, so tests can rewrite its manifest.
  defp copy_public_project! do
    dir = tmp!("proj")
    File.cp_r!(@public, dir)
    Path.join(dir, "offloader.yml")
  end

  defp boot(project_yml, opts) do
    {:ok, rt} =
      Runtime.start_link(
        [name: Runtime, config_path: project_yml, cache_dir: tmp!("cache")] ++ opts
      )

    on_exit(fn -> if Process.alive?(rt), do: GenServer.stop(rt) end)
    rt
  end

  defp champion, do: get(build_conn(), "/v1/endpoints/champion?champion_id=1")

  # A second snapshot for the champion_stats dataset: same parquet, new snapshot_id.
  defp write_manifest_v2!(project_yml) do
    dir = project_yml |> Path.dirname() |> Path.join("data/champion_stats")
    v1 = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    v2 =
      Map.merge(v1, %{
        "snapshot_id" => "2026-07-02T00:00:00Z_r0002",
        "watermark" => "2026-07-02T00:00:00Z",
        "created_at" => "2026-07-02T00:05:00Z"
      })

    File.write!(Path.join(dir, "manifest_v2.json"), Jason.encode!(v2))
    {Path.join(dir, "manifest_v2.json"), Path.join(dir, "manifest.json"), v2}
  end

  defp eventually(fun, timeout \\ 5_000),
    do: do_eventually(fun, System.monotonic_time(:millisecond) + timeout)

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(25)
        do_eventually(fun, deadline)
    end
  end

  test "with no Runtime at all, a bearer request is shed as a retryable 503, not a 500" do
    # The boot/restart window: the endpoint is up before the Runtime has a context.
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer offl_any_token")
      |> get("/v1/endpoints/champion?champion_id=1")

    assert conn.status == 503
    assert %{"error" => %{"family" => "not_ready", "message" => msg}} = json_response(conn, 503)
    assert msg =~ ~r/starting/i
  end

  test "a dataset whose snapshot never materialized serves 503 not_ready, and the API stays up" do
    project = copy_public_project!()
    manifest = project |> Path.dirname() |> Path.join("data/champion_stats/manifest.json")
    File.write!(manifest, "{ not json")

    boot(project, [])

    conn = champion()
    assert conn.status == 503
    assert %{"error" => %{"family" => "not_ready", "message" => msg}} = json_response(conn, 503)
    assert msg =~ ~r/not ready/i
  end

  test "an old ETag stops matching after a snapshot swap — a client can never be pinned to stale data" do
    project = copy_public_project!()
    boot(project, [])

    first = champion()
    assert first.status == 200
    [etag1] = get_resp_header(first, "etag")
    assert get_in(json_response(first, 200), ["meta", "snapshot_id"]) =~ "r0001"

    {v2_path, _v1_path, v2} = write_manifest_v2!(project)
    assert {:ok, _sid} = Runtime.refresh(Runtime, "champion_stats", v2_path)

    revalidated =
      build_conn()
      |> put_req_header("if-none-match", etag1)
      |> get("/v1/endpoints/champion?champion_id=1")

    # The old validator must MISS (fresh 200 with the new snapshot), then the new one hits.
    assert revalidated.status == 200
    assert get_in(json_response(revalidated, 200), ["meta", "snapshot_id"]) == v2["snapshot_id"]
    [etag2] = get_resp_header(revalidated, "etag")
    refute etag2 == etag1

    cached =
      build_conn()
      |> put_req_header("if-none-match", etag2)
      |> get("/v1/endpoints/champion?champion_id=1")

    assert cached.status == 304
  end

  test "the interval poll loop picks up a new snapshot with no restart and no manual refresh" do
    project = copy_public_project!()
    boot(project, refresh_interval_ms: 100)

    assert get_in(json_response(champion(), 200), ["meta", "snapshot_id"]) =~ "r0001"

    # Publish the new snapshot the boring way: overwrite the manifest the dataset points at.
    {v2_path, v1_path, v2} = write_manifest_v2!(project)
    File.cp!(v2_path, v1_path)

    eventually(fn ->
      get_in(json_response(champion(), 200), ["meta", "snapshot_id"]) == v2["snapshot_id"]
    end)
  end
end
