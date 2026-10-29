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
      Offloader.TestSupport.stop_if_alive(rt)
      Offloader.TestSupport.rm_rf!(dir)
    end)

    :ok
  end

  defp champion(id), do: get(build_conn(), "/v1/endpoints/champion?champion_id=#{id}")

  # ConnTest skips the HTTP adapter, so anything Bandit adds on the way out (compression, its
  # Vary line) needs a real listener. It starts with the endpoint's own `http:` options.
  defp listen do
    {:ok, server} =
      Application.fetch_env!(:offloader, OffloaderWeb.ApiEndpoint)
      |> Keyword.get(:http, [])
      |> Keyword.merge(
        plug: OffloaderWeb.ApiEndpoint,
        ip: :loopback,
        port: 0,
        startup_log: false
      )
      |> Bandit.start_link()

    on_exit(fn -> Offloader.TestSupport.stop_if_alive(server) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  # The response head exactly as sent. :httpc keeps one value per known header, so it can't
  # show a header repeated on two lines.
  defp raw_head(port, method, path, headers) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    lines = Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

    :ok =
      :gen_tcp.send(socket, [
        "#{method} #{path} HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n",
        lines,
        "\r\n"
      ])

    head = recv_head(socket, "")
    :gen_tcp.close(socket)
    head
  end

  defp recv_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, _body] ->
        head

      [_partial] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        recv_head(socket, acc <> data)
    end
  end

  describe "public (auth: none) responses are edge-cacheable" do
    setup do: boot(@public)

    test "carry a weak ETag + a public Cache-Control derived from freshness" do
      conn = champion(1)
      assert conn.status == 200
      assert [etag] = get_resp_header(conn, "etag")
      assert etag =~ ~r/^W\/"[0-9a-f]{20}"$/
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

    # The bodies differ (request_id, generated_at), so sharing a validator is only honest
    # as a weak one: RFC 9110 reserves strong ETags for byte-identical representations.
    test "responses that differ only in per-request meta share a weak ETag" do
      first = champion(1)
      second = champion(1)
      refute first.resp_body == second.resp_body
      assert get_resp_header(first, "etag") == get_resp_header(second, "etag")
      assert [<<"W/", _::binary>>] = get_resp_header(first, "etag")
    end

    test "If-None-Match uses weak comparison, with or without the W/ prefix" do
      [etag] = get_resp_header(champion(1), "etag")

      conn =
        build_conn()
        |> put_req_header("if-none-match", String.replace_prefix(etag, "W/", ""))
        |> get("/v1/endpoints/champion?champion_id=1")

      assert conn.status == 304
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

    test "carry a CDN-Tag naming the dataset and endpoint, also on a 304" do
      conn = champion(1)
      assert get_resp_header(conn, "cdn-tag") == ["offloader:champion_stats:champion"]

      [etag] = get_resp_header(conn, "etag")

      not_modified =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/v1/endpoints/champion?champion_id=1")

      assert not_modified.status == 304
      assert get_resp_header(not_modified, "cdn-tag") == ["offloader:champion_stats:champion"]
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
      assert get_resp_header(conn, "cdn-tag") == []
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
      assert [vary] = get_resp_header(conn, "vary")
      assert vary =~ "origin"
    end

    test "an allow-list emits Vary: origin even without an Origin header (shared caches must key on it)" do
      Application.put_env(:offloader, :cors_origins, ["https://app.example.com"])
      conn = champion(1)
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert [vary] = get_resp_header(conn, "vary")
      assert vary =~ "origin"
    end

    # Bandit adds its own `vary: accept-encoding` line unless a Vary already names that token. Two
    # lines are valid HTTP, but a cache that reads only the first (Varnish, unless VCL collects
    # them) would key on the encoding alone and serve one origin's allow-origin to another.
    test "an allow-list sends one Vary line naming origin and accept-encoding, on every status" do
      Application.put_env(:offloader, :cors_origins, ["https://app.example.com"])
      port = listen()
      path = "/v1/endpoints/champion?champion_id=1"
      origin = {"origin", "https://app.example.com"}

      gzip = raw_head(port, "GET", path, [origin, {"accept-encoding", "gzip"}])
      plain = raw_head(port, "GET", path, [origin])
      [_, etag] = Regex.run(~r/^etag: ([^\r\n]+)/mi, plain)
      not_modified = raw_head(port, "GET", path, [origin, {"if-none-match", etag}])

      preflight =
        raw_head(port, "OPTIONS", path, [origin, {"access-control-request-method", "GET"}])

      for {head, status} <- [{gzip, 200}, {plain, 200}, {not_modified, 304}, {preflight, 204}] do
        assert head =~ ~r{^HTTP/1\.1 #{status} }
        assert [vary] = for(line <- String.split(head, "\r\n"), line =~ ~r/^vary:/i, do: line)
        assert vary =~ "origin"
        assert vary =~ "accept-encoding"
      end
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

  # Bandit compresses a response when the client's Accept-Encoding allows it, but skips one with a
  # strong ETag or `Cache-Control: no-transform`. Public responses stay compressible only while
  # their ETag is weak.
  describe "responses are compressed for clients that accept it" do
    setup do
      boot(@public)
      {:ok, _} = Application.ensure_all_started(:inets)
      %{url: ~c"http://127.0.0.1:#{listen()}/v1/endpoints/champion?champion_id=1"}
    end

    defp fetch(url, headers) do
      {:ok, {{_, 200, _}, resp_headers, body}} =
        :httpc.request(:get, {url, headers}, [], body_format: :binary)

      {Map.new(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end), body}
    end

    test "zstd and gzip bodies carry the same data, and caches keep the variants apart", %{
      url: url
    } do
      {plain_headers, plain} = fetch(url, [])
      refute Map.has_key?(plain_headers, "content-encoding")
      data = JSON.decode!(plain)["data"]

      for {coding, decode} <- [
            {"zstd", &IO.iodata_to_binary(:zstd.decompress(&1))},
            {"gzip", &:zlib.gunzip/1}
          ] do
        {headers, body} = fetch(url, [{~c"accept-encoding", String.to_charlist(coding)}])
        assert headers["content-encoding"] == coding
        assert headers["vary"] =~ "accept-encoding"
        assert headers["etag"] == plain_headers["etag"]
        assert JSON.decode!(decode.(body))["data"] == data
      end
    end
  end
end
