defmodule OffloaderWeb.MCPHTTPTest do
  # The MCP surface (POST /mcp) over real HTTP against a booted Runtime and real DuckDB.
  # Covers revision 2026-07-28's handshake-less contract (version + mirrored headers), the
  # initialize-era clients served on the same URL, and — the part that matters — that the
  # cache advertisement and the tenant boundary agree with the REST path. async: false
  # (singleton + DuckDB).
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Offloader.{MCP, Runtime}

  @endpoint OffloaderWeb.ApiEndpoint
  @public_project Path.expand("../../../examples/public-metrics/offloader.yml", __DIR__)
  @tenant_project Path.expand("../../../examples/customer-analytics/offloader.yml", __DIR__)

  @version MCP.protocol_version()
  @version_key "io.modelcontextprotocol/protocolVersion"
  @acme "offl_demo_acme_key"
  @globex "offl_demo_globex_key"
  @range %{"from" => "2026-05-30", "to" => "2026-06-01"}

  defp boot(project) do
    dir = Path.join(System.tmp_dir!(), "offl_mcp_#{System.unique_integer([:positive])}")
    {:ok, rt} = Runtime.start_link(name: Runtime, config_path: project, cache_dir: dir)

    on_exit(fn ->
      Offloader.TestSupport.stop_if_alive(rt)
      File.rm_rf!(dir)
    end)

    :ok
  end

  setup do
    previous = Application.get_env(:offloader, :mcp_enabled)
    Application.put_env(:offloader, :mcp_enabled, true)
    on_exit(fn -> Application.put_env(:offloader, :mcp_enabled, previous) end)
    :ok
  end

  # Build a spec-shaped request: version in both the header and `params._meta`, plus the
  # mirrored `Mcp-Method`/`Mcp-Name`. Opts override any single piece so a test can make
  # exactly one thing wrong.
  defp rpc(method, params \\ %{}, opts \\ []) do
    version = Keyword.get(opts, :version, @version)

    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{@version_key => Keyword.get(opts, :body_version, version)})
    }

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_header("mcp-protocol-version", version)
    |> put_header("mcp-method", Keyword.get(opts, :mcp_method, method))
    |> put_header("mcp-name", Keyword.get(opts, :mcp_name, mirrored_name(method, params)))
    |> put_bearer(opts[:token])
    |> post("/mcp", JSON.encode_to_iodata!(body) |> IO.iodata_to_binary())
  end

  # An initialize-era request: no `_meta` version and no mirrored headers, just the version
  # header those clients send after `initialize`. `version: nil` omits it, as 2025-03-26
  # clients do, `notification: true` omits the `id`, and `mcp_name:` forges a mirrored header.
  defp legacy(method, params \\ %{}, opts \\ []) do
    body = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    body = if opts[:notification], do: body, else: Map.put(body, "id", 1)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_header("mcp-protocol-version", Keyword.get(opts, :version, "2025-11-25"))
    |> put_header("mcp-name", opts[:mcp_name])
    |> put_bearer(opts[:token])
    |> post("/mcp", JSON.encode_to_iodata!(body) |> IO.iodata_to_binary())
  end

  defp mirrored_name("tools/call", params), do: params["name"]
  defp mirrored_name("resources/read", params), do: params["uri"]
  defp mirrored_name(_method, _params), do: nil

  defp put_header(conn, _name, nil), do: conn
  defp put_header(conn, name, value), do: put_req_header(conn, name, value)

  defp put_bearer(conn, nil), do: conn
  defp put_bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp result(conn), do: json_response(conn, 200)["result"]

  defp rpc_error(conn, status), do: json_response(conn, status)["error"]

  # The data payload an MCP result carries is the REST response body, serialized.
  defp payload(%{"contents" => [%{"text" => text} | _]}), do: JSON.decode!(text)
  defp payload(%{"content" => [%{"text" => text} | _]}), do: JSON.decode!(text)

  describe "a public project (auth: none)" do
    setup do: boot(@public_project)

    test "server/discover advertises the version and capabilities without a key" do
      result = result(rpc("server/discover"))

      assert result["supportedVersions"] == [
               "2026-07-28",
               "2025-11-25",
               "2025-06-18",
               "2025-03-26"
             ]

      assert result["resultType"] == "complete"
      assert Map.has_key?(result["capabilities"], "tools")
      assert Map.has_key?(result["capabilities"], "resources")
      assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "offloader"
      assert is_binary(result["instructions"])
    end

    test "tools/list exposes each endpoint with a closed input schema" do
      [tool] = result(rpc("tools/list"))["tools"]

      assert tool["name"] == "champion"
      assert tool["inputSchema"]["required"] == ["champion_id"]
      assert tool["inputSchema"]["additionalProperties"] == false
      # the reserved query params ride along with the declared ones
      assert %{"champion_id" => _, "limit" => _, "offset" => _, "columns" => _} =
               tool["inputSchema"]["properties"]
    end

    test "tools/call serves the row through the compiled plan" do
      result =
        result(rpc("tools/call", %{"name" => "champion", "arguments" => %{"champion_id" => "1"}}))

      assert result["isError"] == false
      assert [row] = payload(result)["data"]
      assert row["champion_id"] == "1"
      # the nested JSON column survives the round trip as an object
      assert is_map(row["data"])
    end

    test "resources/templates/list emits an RFC 6570 template per endpoint" do
      [template] = result(rpc("resources/templates/list"))["resourceTemplates"]

      assert template["uriTemplate"] ==
               "offloader://champion{?champion_id,limit,offset,columns}"

      assert template["mimeType"] == "application/json"
    end

    test "resources/list omits an endpoint that cannot be read without arguments" do
      # `champion` requires champion_id, so its bare URI is not readable — it belongs in
      # the template list, not the concrete resource list.
      assert result(rpc("resources/list"))["resources"] == []
    end

    test "resources/read is advertised as shared-cacheable, in-band and over HTTP" do
      conn = rpc("resources/read", %{"uri" => "offloader://champion?champion_id=1"})
      result = result(conn)

      assert result["cacheScope"] == "public"
      assert result["ttlMs"] > 0
      assert [cache_control] = get_resp_header(conn, "cache-control")
      assert cache_control =~ "public, max-age="
      # The same purge tag as the REST response for this endpoint.
      assert get_resp_header(conn, "cdn-tag") == ["offloader:champion_stats:champion"]

      assert [row] = payload(result)["data"]
      assert row["champion_id"] == "1"
    end

    test "tools/call is never advertised as cacheable — the spec has no cache fields for it" do
      conn = rpc("tools/call", %{"name" => "champion", "arguments" => %{"champion_id" => "1"}})

      refute Map.has_key?(result(conn), "cacheScope")
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "cdn-tag") == []
    end

    test "a non-string argument is coerced the same way a query string would be" do
      result =
        result(rpc("tools/call", %{"name" => "champion", "arguments" => %{"champion_id" => 1}}))

      assert result["isError"] == false
      assert [%{"champion_id" => "1"}] = payload(result)["data"]
    end

    test "an unknown endpoint comes back as a tool error the model can act on" do
      result = result(rpc("tools/call", %{"name" => "nope", "arguments" => %{}}))

      assert result["isError"] == true
      assert [%{"text" => message}] = result["content"]
      assert message =~ "not found"
    end

    test "a bad param is a tool error, not a protocol error" do
      result =
        result(
          rpc("tools/call", %{
            "name" => "champion",
            "arguments" => %{"champion_id" => "1", "columns" => "champion_id,secret"}
          })
        )

      assert result["isError"] == true
    end

    test "a resource uri outside the offloader:// scheme is rejected without echoing it" do
      error = rpc("resources/read", %{"uri" => "file:///etc/passwd"}) |> rpc_error(200)

      assert error["code"] == -32_602
      refute error["message"] =~ "passwd"
    end
  end

  describe "protocol contract" do
    setup do: boot(@public_project)

    test "a missing Mcp-Method header is a HeaderMismatch" do
      error = rpc("tools/list", %{}, mcp_method: nil) |> rpc_error(400)
      assert error["code"] == -32_020
    end

    test "an Mcp-Method that disagrees with the body is a HeaderMismatch" do
      error = rpc("tools/list", %{}, mcp_method: "tools/call") |> rpc_error(400)
      assert error["code"] == -32_020
    end

    test "an Mcp-Name that disagrees with the resource uri is a HeaderMismatch" do
      # The whole point of the mirrored header: a cache keyed on Mcp-Name must never be
      # able to key one resource while the server reads another.
      error =
        rpc("resources/read", %{"uri" => "offloader://champion?champion_id=1"},
          mcp_name: "offloader://champion?champion_id=2"
        )
        |> rpc_error(400)

      assert error["code"] == -32_020
    end

    test "an Mcp-Name on a method without a name is a HeaderMismatch" do
      # A cache keyed on Mcp-Name would otherwise file this list under the resource's key.
      error =
        rpc("tools/list", %{}, mcp_name: "offloader://champion?champion_id=1") |> rpc_error(400)

      assert error["code"] == -32_020
    end

    test "a base64-sentinel Mcp-Name is decoded before comparison" do
      uri = "offloader://champion?champion_id=1"
      encoded = "=?base64?" <> Base.encode64(uri) <> "?="

      assert result(rpc("resources/read", %{"uri" => uri}, mcp_name: encoded))["cacheScope"] ==
               "public"
    end

    test "a version the server does not speak is rejected with every version it does" do
      error = rpc("tools/list", %{}, version: "1900-01-01") |> rpc_error(400)

      assert error["code"] == -32_022

      assert error["data"] == %{
               "supported" => MCP.supported_versions(),
               "requested" => "1900-01-01"
             }
    end

    # Where the eras meet: either half of 2026-07-28's version declaration holds the request
    # to its rules, and only an `initialize` without `_meta` is let through as initialize-era.
    test "a 2026-07-28 header without the _meta version is a HeaderMismatch" do
      assert legacy("tools/list", %{}, version: @version) |> rpc_error(400) |> Map.get("code") ==
               -32_020
    end

    test "a _meta version without the header is a HeaderMismatch" do
      error = rpc("tools/list", %{}, version: nil, body_version: @version) |> rpc_error(400)
      assert error["code"] == -32_020
    end

    test "an initialize left with a 2026-07-28 header is still answered as initialize-era" do
      result =
        result(legacy("initialize", %{"protocolVersion" => "2025-06-18"}, version: @version))

      assert result["protocolVersion"] == "2025-06-18"
    end

    test "a request naming an initialize-era version in _meta is pointed at initialize" do
      error = rpc("tools/list", %{}, version: "2025-11-25") |> rpc_error(400)

      assert error["code"] == -32_022
      assert error["message"] =~ "initialize"
    end

    test "a batch is refused with a clear error" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", ~s([{"jsonrpc":"2.0","id":1,"method":"ping"}]))

      assert %{"code" => -32_600, "message" => message} = rpc_error(conn, 400)
      assert message =~ "batches"
    end

    test "a header/body version disagreement is a HeaderMismatch" do
      error = rpc("tools/list", %{}, body_version: "2025-06-18") |> rpc_error(400)
      assert error["code"] == -32_020
    end

    test "an unknown method is 404 with method-not-found" do
      assert rpc("prompts/list") |> rpc_error(404) |> Map.get("code") == -32_601
    end

    test "the endpoint is absent unless explicitly enabled" do
      Application.put_env(:offloader, :mcp_enabled, false)
      assert rpc("tools/list") |> rpc_error(404) |> Map.get("code") == -32_601
    end
  end

  describe "a tenant-scoped project (auth: required)" do
    setup do: boot(@tenant_project)

    test "a read without a bearer token is 401" do
      conn = rpc("resources/read", %{"uri" => "offloader://customer_usage_summary"})

      assert rpc_error(conn, 401)
      assert get_resp_header(conn, "www-authenticate") != []
    end

    test "tools/list without a bearer token is 401" do
      assert rpc("tools/list") |> rpc_error(401)
    end

    test "server/discover still answers without a key" do
      assert result(rpc("server/discover"))["supportedVersions"] == MCP.supported_versions()
    end

    test "tools/list shows only the endpoints the presented key grants" do
      acme = result(rpc("tools/list", %{}, token: @acme))["tools"] |> Enum.map(& &1["name"])
      globex = result(rpc("tools/list", %{}, token: @globex))["tools"] |> Enum.map(& &1["name"])

      assert acme == ["customer_usage_daily", "customer_usage_summary", "top_accounts_by_usage"]
      # globex's key grants exactly one endpoint — discovery must not reveal the rest
      assert globex == ["customer_usage_summary"]
    end

    test "resources/templates/list is scoped to the key too" do
      templates =
        result(rpc("resources/templates/list", %{}, token: @globex))["resourceTemplates"]

      assert Enum.map(templates, & &1["name"]) == ["customer_usage_summary"]
    end

    test "calling an endpoint the key does not grant is indistinguishable from unknown" do
      result =
        result(
          rpc("tools/call", %{"name" => "top_accounts_by_usage", "arguments" => @range},
            token: @globex
          )
        )

      assert result["isError"] == true
      assert [%{"text" => message}] = result["content"]
      assert message =~ "not found"
    end

    test "a tenant-scoped read is never advertised as shared-cacheable" do
      uri = "offloader://customer_usage_summary?" <> URI.encode_query(@range)
      conn = rpc("resources/read", %{"uri" => uri}, token: @acme)
      result = result(conn)

      assert result["cacheScope"] == "private"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "cdn-tag") == []
      assert payload(result)["data"] != []
    end

    test "two keys reading the same endpoint see only their own tenant's rows" do
      acme = read_summary(@acme)
      globex = read_summary(@globex)

      assert acme != []
      assert globex != []
      # The tenant filter is inserted from the key, so the account sets cannot overlap.
      acme_accounts = MapSet.new(acme, & &1["account_id"])
      globex_accounts = MapSet.new(globex, & &1["account_id"])
      assert MapSet.disjoint?(acme_accounts, globex_accounts)
    end

    test "the tenant column is not exposed in the response or the tool schema" do
      [row | _] = read_summary(@acme)
      refute Map.has_key?(row, "tenant_id")

      tool =
        result(rpc("tools/list", %{}, token: @acme))["tools"]
        |> Enum.find(&(&1["name"] == "customer_usage_summary"))

      refute Map.has_key?(tool["inputSchema"]["properties"], "tenant_id")
      refute tool["description"] =~ "tenant_id"
    end

    test "a revoked key is rejected" do
      assert rpc("tools/list", %{}, token: "offl_demo_revoked_key") |> rpc_error(401)
    end

    test "a tenant_id smuggled into the resource uri cannot override the key's tenant" do
      # The compiler forbids an endpoint from filtering on the tenant column, so
      # `tenant_id` is an undeclared param — rejected outright rather than applied.
      uri =
        "offloader://customer_usage_summary?" <>
          URI.encode_query(Map.put(@range, "tenant_id", "tenant_globex"))

      error = rpc("resources/read", %{"uri" => uri}, token: @acme) |> rpc_error(200)
      assert error["code"] == -32_602
    end

    test "a tenant_id smuggled into tool arguments is rejected the same way" do
      arguments = Map.put(@range, "tenant_id", "tenant_globex")

      result =
        result(
          rpc("tools/call", %{"name" => "customer_usage_summary", "arguments" => arguments},
            token: @acme
          )
        )

      assert result["isError"] == true
    end

    test "a nested argument is refused rather than guessed at" do
      arguments = Map.put(@range, "account_id", %{"$ne" => nil})

      result =
        result(
          rpc("tools/call", %{"name" => "customer_usage_summary", "arguments" => arguments},
            token: @acme
          )
        )

      assert result["isError"] == true
    end

    test "an MCP read lands in the same per-endpoint metrics as a REST read" do
      Offloader.Metrics.Requests.reset()
      read_summary(@acme)

      metrics = Offloader.Metrics.Requests.to_prometheus()

      assert metrics =~
               ~s(offloader_requests_total{endpoint="customer_usage_summary",status="ok"})
    end

    test "an unknown tool name cannot mint an unbounded metric series" do
      Offloader.Metrics.Requests.reset()
      invented = "made_up_#{System.unique_integer([:positive])}"

      rpc("tools/call", %{"name" => invented, "arguments" => %{}}, token: @acme)

      metrics = Offloader.Metrics.Requests.to_prometheus()
      refute metrics =~ invented
      assert metrics =~ ~s(endpoint="<unresolved>")
    end
  end

  # Clients that open with `initialize` (2025-03-26 to 2025-11-25) on the same URL: most agent
  # clients still do by default, and a 2026-07-28-only server leaves them nothing to fall back to.
  describe "an initialize-era client, against a tenant-scoped project" do
    setup do: boot(@tenant_project)

    test "initialize echoes a version it speaks, with no key and no session" do
      conn =
        legacy(
          "initialize",
          %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "1"}
          },
          version: nil
        )

      result = result(conn)
      assert result["protocolVersion"] == "2025-06-18"
      assert Map.keys(result["capabilities"]) |> Enum.sort() == ["resources", "tools"]
      assert result["serverInfo"]["name"] == "offloader"
      assert is_binary(result["instructions"])
      assert get_resp_header(conn, "mcp-session-id") == []
    end

    test "initialize offers the newest initialize-era version when it can't echo the one asked" do
      for asked <- ["2024-11-05", "2026-07-28", nil] do
        result = result(legacy("initialize", %{"protocolVersion" => asked}, version: nil))
        assert result["protocolVersion"] == "2025-11-25"
      end
    end

    test "a notification is accepted with 202 and no body" do
      conn = legacy("notifications/initialized", %{}, notification: true)

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "reads need the key and keep its endpoint scope and tenant" do
      assert legacy("tools/list") |> rpc_error(401)

      tools = result(legacy("tools/list", %{}, token: @globex))["tools"]
      assert Enum.map(tools, & &1["name"]) == ["customer_usage_summary"]

      call = %{"name" => "customer_usage_summary", "arguments" => @range}
      rows = legacy("tools/call", call, token: @acme) |> result() |> payload()
      assert rows["data"] == read_summary(@acme)
    end
  end

  describe "an initialize-era client, against a public project" do
    setup do: boot(@public_project)

    # A legacy request carries no validated Mcp-Name, so nothing in front of the server can key
    # a cache on the resource it reads; its revisions define no cache fields either. The abuse
    # case: claim an old version to skip header validation, forge Mcp-Name to point a cache at
    # another resource, and hope the response is stored under it.
    test "a read is never advertised as cacheable, in-band or over HTTP" do
      conn =
        legacy("resources/read", %{"uri" => "offloader://champion?champion_id=1"},
          mcp_name: "offloader://champion?champion_id=2"
        )

      result = result(conn)

      assert [row] = payload(result)["data"]
      assert row["champion_id"] == "1"

      for key <- ["ttlMs", "cacheScope", "resultType", "_meta"],
          do: refute(Map.has_key?(result, key))

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "cdn-tag") == []
    end

    test "a request without a version header is served as 2025-03-26" do
      assert [%{"name" => "champion"}] = result(legacy("tools/list", %{}, version: nil))["tools"]
    end

    test "a version header the server doesn't speak is rejected with every version it does" do
      error = legacy("tools/list", %{}, version: "2024-11-05") |> rpc_error(400)

      assert error["code"] == -32_022

      assert error["data"] == %{
               "supported" => MCP.supported_versions(),
               "requested" => "2024-11-05"
             }
    end

    test "a version header that isn't UTF-8 is rejected, not echoed into a crash" do
      error = legacy("tools/list", %{}, version: <<0xFF>>) |> rpc_error(400)

      assert error["code"] == -32_022
      assert error["data"] == %{"supported" => MCP.supported_versions()}
    end

    test "an unknown method is method-not-found inside a 200" do
      assert legacy("prompts/list") |> rpc_error(200) |> Map.get("code") == -32_601
    end

    test "ping answers an empty result" do
      assert result(legacy("ping")) == %{}
    end

    test "GET and DELETE are 405, allowing only POST" do
      for method <- [:get, :delete] do
        conn =
          build_conn()
          |> put_req_header("accept", "text/event-stream")
          |> dispatch(@endpoint, method, "/mcp")

        assert conn.status == 405
        assert get_resp_header(conn, "allow") == ["POST"]
      end
    end

    test "GET is 404 while MCP is disabled" do
      Application.put_env(:offloader, :mcp_enabled, false)
      assert dispatch(build_conn(), @endpoint, :get, "/mcp") |> rpc_error(404)
    end
  end

  defp read_summary(token) do
    uri = "offloader://customer_usage_summary?" <> URI.encode_query(@range)

    rpc("resources/read", %{"uri" => uri}, token: token)
    |> result()
    |> payload()
    |> Map.fetch!("data")
  end
end
