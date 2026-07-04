defmodule OffloaderWeb.CacheAndCorsHTTPTest do
  # Edge/browser HTTP behaviour: public responses are CDN-cacheable (ETag + Cache-Control +
  # 304), authed responses are never shared-cached (private, no-store), and CORS lets a
  # browser front-end call the API. async: false — Runtime singleton + DuckDB + app-env seam.
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Offloader.Runtime

  @endpoint OffloaderWeb.ApiEndpoint
  @public Path.expand("../../../examples/public-metrics/offloader.yml", __DIR__)
  @authed Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)

  defp boot(project) do
    dir = Path.join(System.tmp_dir!(), "offl_cc_#{System.unique_integer([:positive])}")
    {:ok, rt} = Runtime.start_link(name: Runtime, config_path: project, cache_dir: dir)

    on_exit(fn ->
      if Process.alive?(rt), do: GenServer.stop(rt)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp champion(id), do: get(build_conn(), "/v1/endpoints/champion?champion_id=#{id}")

  describe "public (auth: none) responses are edge-cacheable" do
    setup do: boot(@public)

    test "carry an ETag + a public Cache-Control derived from freshness" do
      conn = champion(1)
      assert conn.status == 200
      assert [etag] = get_resp_header(conn, "etag")
      assert etag =~ ~r/^"[0-9a-f]{20}"$/
      assert [cc] = get_resp_header(conn, "cache-control")
      assert cc =~ "public"
      assert cc =~ "max-age="
      assert cc =~ "stale-while-revalidate"
    end

    test "If-None-Match with the current ETag returns a bodyless 304" do
      [etag] = get_resp_header(champion(1), "etag")

      conn =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/v1/endpoints/champion?champion_id=1")

      assert conn.status == 304
      assert conn.resp_body == ""
      assert get_resp_header(conn, "etag") == [etag]
    end

    test "a different request gets a different ETag" do
      e1 = hd(get_resp_header(champion(1), "etag"))
      e2 = hd(get_resp_header(champion(2), "etag"))
      refute e1 == e2
    end

    test "If-None-Match is an exact list match — the ETag embedded in junk is NOT a hit" do
      [etag] = get_resp_header(champion(1), "etag")

      embedded =
        build_conn()
        |> put_req_header("if-none-match", "junk#{etag}junk")
        |> get("/v1/endpoints/champion?champion_id=1")

      assert embedded.status == 200

      listed =
        build_conn()
        |> put_req_header("if-none-match", ~s("something-else", ) <> etag)
        |> get("/v1/endpoints/champion?champion_id=1")

      assert listed.status == 304
    end

    test "meta carries the endpoint contract version (an ETag input — a reload can change the contract without a new snapshot)" do
      assert get_in(json_response(champion(1), 200), ["meta", "version"]) == 1
    end

    test "responses carry X-Content-Type-Options: nosniff" do
      assert get_resp_header(champion(1), "x-content-type-options") == ["nosniff"]
    end
  end

  describe "authed responses are never shared-cached" do
    setup do: boot(@authed)

    test "carry Cache-Control private, no-store and no ETag" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer offl_demo_acme_key")
        |> get("/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "etag") == []
    end
  end

  describe "CORS for a browser front-end" do
    setup do: boot(@public)

    setup do
      prev = Application.get_env(:offloader, :cors_origins)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:offloader, :cors_origins, prev),
          else: Application.delete_env(:offloader, :cors_origins)
      end)

      :ok
    end

    test "no CORS headers when unset (the default)" do
      Application.delete_env(:offloader, :cors_origins)
      assert get_resp_header(champion(1), "access-control-allow-origin") == []
    end

    test "wildcard origin for a public API" do
      Application.put_env(:offloader, :cors_origins, ["*"])

      conn =
        build_conn()
        |> put_req_header("origin", "https://app.example.com")
        |> get("/v1/endpoints/champion?champion_id=1")

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "an explicit allow-list echoes a listed origin with credentials" do
      Application.put_env(:offloader, :cors_origins, ["https://app.example.com"])

      conn =
        build_conn()
        |> put_req_header("origin", "https://app.example.com")
        |> get("/v1/endpoints/champion?champion_id=1")

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example.com"]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
    end

    test "an off-list origin gets no allow-origin — but still Vary: origin" do
      Application.put_env(:offloader, :cors_origins, ["https://app.example.com"])

      conn =
        build_conn()
        |> put_req_header("origin", "https://evil.example.com")
        |> get("/v1/endpoints/champion?champion_id=1")

      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert "origin" in get_resp_header(conn, "vary")
    end

    test "an allow-list emits Vary: origin even without an Origin header (shared caches must key on it)" do
      Application.put_env(:offloader, :cors_origins, ["https://app.example.com"])
      conn = champion(1)
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert "origin" in get_resp_header(conn, "vary")
    end

    test "wildcard emits allow-origin on every response, even without an Origin header" do
      Application.put_env(:offloader, :cors_origins, ["*"])
      assert get_resp_header(champion(1), "access-control-allow-origin") == ["*"]
    end

    test "an off-list preflight is answered 204 with no allow headers" do
      Application.put_env(:offloader, :cors_origins, ["https://app.example.com"])

      conn =
        build_conn()
        |> put_req_header("origin", "https://evil.example.com")
        |> dispatch(@endpoint, :options, "/v1/endpoints/champion")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-allow-methods") == []
    end

    test "an OPTIONS preflight is answered 204 with CORS headers, before auth" do
      Application.put_env(:offloader, :cors_origins, ["*"])

      conn =
        build_conn()
        |> put_req_header("origin", "https://app.example.com")
        |> dispatch(@endpoint, :options, "/v1/endpoints/champion")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") != []
    end
  end
end
