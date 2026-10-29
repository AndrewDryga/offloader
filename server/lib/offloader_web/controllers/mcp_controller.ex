defmodule OffloaderWeb.MCPController do
  @moduledoc """
  The MCP endpoint (`POST /mcp`) on the product API port, over Streamable HTTP.

  Revision `2026-07-28` is stateless — no `initialize` handshake, no session header, no
  GET stream — so this is one route that answers each POST on its own. Every request
  carries its protocol version and is authorized independently, exactly like the REST
  path: reads run through `Runtime.serve/5`, so the tenant filter, endpoint allowlist,
  and column allowlist are the same ones the compiler already enforces.

  ## Clients still on the `initialize` handshake

  In late 2026 most agent clients still open with `initialize` (revisions 2025-03-26 to
  2025-11-25), and against a 2026-07-28-only server they have nothing to fall back to. The spec lets
  one endpoint serve both eras, so the era is chosen per request: an `initialize`, or a
  request with neither a version in `_meta` nor a `2026-07-28` header, is initialize-era;
  everything else is held to 2026-07-28's rules. Initialize-era requests are served
  statelessly too. `initialize` is answered like `server/discover`, with no session ID;
  a notification gets a bare 202; later requests name the agreed version in
  `MCP-Protocol-Version`, or nothing on 2025-03-26. Methods, keys, and tenant filters
  are the same. Their results carry no cache fields and are never shareable: with no
  validated `Mcp-Name`, nothing in front of the server could key a cache on them.

  ## Why the mirrored headers are enforced, not tolerated

  SEP-2243 requires `Mcp-Method` (and `Mcp-Name` on `tools/call`/`resources/read`) to
  mirror the body, so an intermediary can route, rate-limit, and cache without parsing
  JSON-RPC. That is only worth anything if the headers are *trustworthy*: a server that
  accepts a request whose header disagrees with its body lets a cache key one thing
  while the server executes another. So a mismatch or a missing header is a
  `-32020 HeaderMismatch` (HTTP 400), per spec, rather than a warning.

  ## Errors

  Auth and readiness carry an HTTP status the client must act on (401, 503). Ordinary
  application failures — a bad param, an endpoint the key does not grant — are HTTP 200
  with a JSON-RPC error, and for `tools/call` they come back as `isError: true` results
  so the model can see the problem and correct the call itself.
  """

  use OffloaderWeb, :controller

  alias Offloader.{ApiError, Config, MCP, Runtime}
  alias Offloader.Metrics.Requests
  alias OffloaderWeb.{CachePolicy, Response}

  # JSON-RPC reserved codes, plus the two the MCP spec allocates from its own range.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603
  @header_mismatch -32_020
  @unsupported_version -32_022

  @version_meta_key "io.modelcontextprotocol/protocolVersion"
  @sentinel_prefix "=?base64?"
  @sentinel_suffix "?="

  def handle(conn, _params) do
    conn = put_resp_header(conn, "x-request-id", Response.request_id(conn))
    body = conn.body_params

    with :ok <- check_enabled(),
         {:ok, request} <- parse_request(body),
         {:ok, era} <- check_version(conn, request),
         :ok <- check_headers(conn, request, era) do
      conn |> assign(:mcp_era, era) |> dispatch(request)
    else
      :notification ->
        send_resp(conn, 202, "")

      {:error, status, code, message, data} ->
        rpc_error(conn, id_of(body), status, code, message, data)
    end
  end

  # Initialize-era clients open a GET event stream and end sessions with DELETE. This
  # server keeps neither, and 405 is how both eras say so.
  def method_not_allowed(conn, _params) do
    case check_enabled() do
      :ok -> conn |> put_resp_header("allow", "POST") |> send_resp(405, "")
      {:error, status, code, message, data} -> rpc_error(conn, nil, status, code, message, data)
    end
  end

  # ── gate / request validation ────────────────────────────────────────────────

  # New surface, opt-in: an operator turns it on deliberately rather than discovering
  # they exposed one by upgrading.
  defp check_enabled do
    if Config.mcp_enabled?(),
      do: :ok,
      else: error(404, @method_not_found, "the MCP endpoint is not enabled on this server")
  end

  # A notification (no `id`) asks for nothing back, and this server acts on none.
  defp parse_request(%{"jsonrpc" => "2.0", "method" => method} = body)
       when is_binary(method) and not is_map_key(body, "id"),
       do: :notification

  defp parse_request(%{"jsonrpc" => "2.0", "method" => method} = body) when is_binary(method) do
    case Map.get(body, "params", %{}) do
      params when is_map(params) ->
        {:ok, %{id: id_of(body), method: method, params: params}}

      _ ->
        error(400, @invalid_request, "params must be an object")
    end
  end

  # Only 2025-03-26 allowed batches; 2025-06-18 dropped them. Plug.Parsers hands a
  # top-level JSON array over as `_json`.
  defp parse_request(%{"_json" => list}) when is_list(list),
    do: error(400, @invalid_request, "batches are not supported: send one request per POST")

  defp parse_request(body) when is_map(body),
    do: error(400, @invalid_request, "expected a JSON-RPC 2.0 request with a method")

  defp parse_request(_body), do: error(400, @parse_error, "request body must be a JSON object")

  defp id_of(%{"id" => id}) when is_binary(id) or is_integer(id), do: id
  defp id_of(_body), do: nil

  # ── protocol version ─────────────────────────────────────────────────────────

  # A request that names its version in `_meta`, or whose header names 2026-07-28, is
  # modern: the header and `_meta` must agree before either is trusted, then the version
  # must be one we speak. Anything else comes from an initialize-era client, which sends
  # the header after `initialize`, except on 2025-03-26, which predates it.
  defp check_version(conn, request) do
    header = header_value(conn, "mcp-protocol-version")

    declared =
      case request.params do
        %{"_meta" => %{@version_meta_key => version}} -> version
        _ -> nil
      end

    cond do
      # A client falling back from a 2026-07-28 probe may still send that header.
      request.method == "initialize" and is_nil(declared) -> {:ok, :legacy}
      declared != nil or header == MCP.protocol_version() -> check_modern(header, declared)
      is_nil(header) or header in MCP.legacy_versions() -> {:ok, :legacy}
      true -> unsupported_version(header)
    end
  end

  defp check_modern(header, declared) do
    cond do
      is_nil(header) ->
        error(400, @header_mismatch, "the MCP-Protocol-Version header is required")

      header != declared ->
        error(
          400,
          @header_mismatch,
          "the MCP-Protocol-Version header does not match _meta.#{@version_meta_key}"
        )

      header != MCP.protocol_version() ->
        unsupported_version(header)

      true ->
        {:ok, :modern}
    end
  end

  # `requested` comes from a header, which can carry bytes that aren't UTF-8 and would
  # crash the JSON encoder, so it's echoed only when valid.
  defp unsupported_version(requested) do
    data = %{supported: MCP.supported_versions()}
    data = if String.valid?(requested), do: Map.put(data, :requested, requested), else: data

    message =
      if requested in MCP.legacy_versions(),
        do: "protocol version #{requested} is served after an initialize handshake",
        else: "unsupported protocol version"

    error(400, @unsupported_version, message, data)
  end

  # ── mirrored headers (SEP-2243) ──────────────────────────────────────────────

  # Initialize-era revisions define no mirrored headers.
  defp check_headers(_conn, _request, :legacy), do: :ok

  defp check_headers(conn, request, :modern) do
    with :ok <- match_header(conn, "mcp-method", request.method, "Mcp-Method") do
      case required_name(request) do
        :not_required -> refute_name(conn)
        {:ok, expected} -> match_header(conn, "mcp-name", expected, "Mcp-Name")
        :missing -> :ok
      end
    end
  end

  # `Mcp-Name` mirrors the tool name or the resource URI — the value an intermediary
  # would key a cache on. When the body omits it entirely the request is malformed for
  # a different reason; let the method handler produce that error.
  defp required_name(%{method: "tools/call", params: params}), do: fetch_string(params, "name")
  defp required_name(%{method: "resources/read", params: params}), do: fetch_string(params, "uri")
  defp required_name(_request), do: :not_required

  # A name on a method that has none would let a cache keyed on `Mcp-Name` file this
  # method's result under some resource's key.
  defp refute_name(conn) do
    if header_value(conn, "mcp-name"),
      do:
        error(
          400,
          @header_mismatch,
          "the Mcp-Name header applies only to tools/call and resources/read"
        ),
      else: :ok
  end

  defp fetch_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> :missing
    end
  end

  defp match_header(conn, header, expected, label) do
    case header_value(conn, header) do
      nil ->
        error(400, @header_mismatch, "the #{label} header is required")

      value ->
        if decode_header(value) == expected,
          do: :ok,
          else:
            error(400, @header_mismatch, "the #{label} header does not match the request body")
    end
  end

  defp header_value(conn, header) do
    case get_req_header(conn, header) do
      [value | _] -> value
      [] -> nil
    end
  end

  # A value that isn't representable as plain ASCII arrives Base64-wrapped in the
  # spec's sentinel. Anything else is already the literal value.
  defp decode_header(@sentinel_prefix <> rest) do
    with true <- String.ends_with?(rest, @sentinel_suffix),
         encoded = binary_part(rest, 0, byte_size(rest) - byte_size(@sentinel_suffix)),
         {:ok, decoded} <- Base.decode64(encoded) do
      decoded
    else
      _ -> @sentinel_prefix <> rest
    end
  end

  defp decode_header(value), do: value

  # ── dispatch ─────────────────────────────────────────────────────────────────

  defp dispatch(conn, %{method: "server/discover", id: id}) do
    # Answered before authentication: it carries no data and no endpoint names, and a
    # client is expected to call it to pick a version before it has credentials.
    send_result(conn, id, MCP.discover(), cache_fields(nil, CachePolicy.list_ttl_seconds()))
  end

  defp dispatch(conn, %{method: "tools/list", id: id}) do
    with_visible(conn, id, fn endpoints, tenant ->
      send_result(
        conn,
        id,
        %{tools: MCP.tools(endpoints)},
        cache_fields(tenant, CachePolicy.list_ttl_seconds())
      )
    end)
  end

  defp dispatch(conn, %{method: "resources/list", id: id}) do
    with_visible(conn, id, fn endpoints, tenant ->
      send_result(
        conn,
        id,
        %{resources: MCP.resources(endpoints)},
        cache_fields(tenant, CachePolicy.list_ttl_seconds())
      )
    end)
  end

  defp dispatch(conn, %{method: "resources/templates/list", id: id}) do
    with_visible(conn, id, fn endpoints, tenant ->
      send_result(
        conn,
        id,
        %{resourceTemplates: MCP.resource_templates(endpoints)},
        cache_fields(tenant, CachePolicy.list_ttl_seconds())
      )
    end)
  end

  defp dispatch(conn, %{method: "tools/call", id: id, params: params}) do
    with {:ok, name} <- require_string(params, "name", "tool name"),
         {:ok, arguments} <- require_arguments(params) do
      case read(conn, name, arguments) do
        {:ok, _tenant, response} ->
          send_result(conn, id, %{content: [text_content(encode(response))], isError: false}, %{})

        # A bad param or an endpoint this key can't reach is something the model can
        # act on — hand it back as a tool result, not a protocol error it never sees.
        {:error, %ApiError{family: family} = api_error}
        when family in [:not_found, :invalid_param] ->
          send_result(conn, id, %{content: [text_content(api_error.message)], isError: true}, %{})

        {:error, api_error} ->
          api_rpc_error(conn, id, api_error)
      end
    else
      {:error, status, code, message, data} -> rpc_error(conn, id, status, code, message, data)
    end
  end

  defp dispatch(conn, %{method: "resources/read", id: id, params: params}) do
    with {:ok, uri} <- require_string(params, "uri", "resource uri"),
         {:ok, name, arguments} <- parse_resource_uri(uri) do
      case read(conn, name, arguments) do
        {:ok, tenant, response} ->
          conn
          |> put_cdn_tag(tenant, name)
          |> send_result(
            id,
            %{contents: [resource_content(uri, encode(response))]},
            cache_fields(tenant, CachePolicy.ttl_seconds(response))
          )

        {:error, api_error} ->
          api_rpc_error(conn, id, api_error)
      end
    else
      {:error, status, code, message, data} -> rpc_error(conn, id, status, code, message, data)
    end
  end

  defp dispatch(%{assigns: %{mcp_era: :legacy}} = conn, %{method: "initialize"} = request),
    do: send_result(conn, request.id, MCP.initialize(request.params["protocolVersion"]), %{})

  defp dispatch(%{assigns: %{mcp_era: :legacy}} = conn, %{method: "ping", id: id}),
    do: send_result(conn, id, %{}, %{})

  # 2026-07-28 answers an unknown method with a 404. Initialize-era clients expect the
  # JSON-RPC error inside a 200, as the SDK servers send it: the TypeScript client treats
  # any other status as a transport failure.
  defp dispatch(conn, %{method: method, id: id}) do
    status = if conn.assigns.mcp_era == :modern, do: 404, else: 200
    rpc_error(conn, id, status, @method_not_found, "unknown method #{inspect(method)}", nil)
  end

  # Only a 2026-07-28 read can sit in a shared cache, so only it gets the purge tag.
  defp put_cdn_tag(%{assigns: %{mcp_era: :modern}} = conn, tenant, name),
    do: CachePolicy.put_cdn_tag(conn, tenant, name)

  defp put_cdn_tag(conn, _tenant, _name), do: conn

  # ── serving ──────────────────────────────────────────────────────────────────

  defp read(conn, name, arguments) do
    request_id = Response.request_id(conn)
    start = System.monotonic_time()

    result =
      with {:ok, tenant} <- resolve_tenant(conn, name),
           {:ok, params} <- stringify(arguments),
           {:ok, response} <- Runtime.serve(name, tenant, params, request_id) do
        {:ok, tenant, response}
      end

    record(name, result, start)
    result
  end

  # Record into the same per-endpoint series the REST path uses, so an operator's latency
  # and volume dashboards cover both surfaces instead of silently omitting agent traffic.
  # The status comes from the error FAMILY, not the HTTP status: an MCP application error
  # is carried inside a 200, and folding those into `ok` would hide them. `Requests.record/3`
  # bounds the endpoint label from there.
  defp record(name, result, start) do
    status =
      case result do
        {:ok, _tenant, _response} -> 200
        {:error, %ApiError{} = api_error} -> ApiError.status(api_error)
      end

    Requests.record(name, status, start)
  end

  # Mirrors `OffloaderWeb.Plugs.ApiAuth`: public mode serves with no tenant, otherwise
  # the bearer is authorized for THIS endpoint and the tenant comes from the key.
  defp resolve_tenant(conn, name) do
    cond do
      not runtime_up?() -> {:error, ApiError.new(:not_ready, "service is starting")}
      Runtime.public?() -> {:ok, nil}
      true -> with {:ok, token} <- bearer(conn), do: Runtime.authorize(token, name)
    end
  end

  defp with_visible(conn, id, render) do
    result =
      cond do
        not runtime_up?() -> {:error, ApiError.new(:not_ready, "service is starting")}
        Runtime.public?() -> Runtime.visible_endpoints(nil)
        true -> with {:ok, token} <- bearer(conn), do: Runtime.visible_endpoints(token)
      end

    case result do
      {:ok, endpoints, tenant} -> render.(endpoints, tenant)
      {:error, api_error} -> api_rpc_error(conn, id, api_error)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, ApiError.new(:unauthorized, "missing or malformed bearer token")}
    end
  end

  defp runtime_up?, do: is_pid(Process.whereis(Runtime))

  # The compiler coerces from the string forms an HTTP query delivers, so a JSON
  # argument that arrived as a number or boolean is rendered the same way — one
  # coercion path for both surfaces. A nested value has no query-string equivalent, so
  # it is rejected rather than guessed at. The param NAME is never echoed back.
  defp stringify(arguments) do
    Enum.reduce_while(arguments, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case scalar(value) do
        {:ok, string} ->
          {:cont, {:ok, Map.put(acc, to_string(key), string)}}

        :error ->
          {:halt,
           {:error,
            ApiError.new(:invalid_param, "arguments must be strings, numbers, or booleans")}}
      end
    end)
  end

  defp scalar(value) when is_binary(value), do: {:ok, value}
  defp scalar(value) when is_integer(value) or is_float(value), do: {:ok, to_string(value)}
  defp scalar(value) when is_boolean(value), do: {:ok, to_string(value)}
  defp scalar(_value), do: :error

  # ── params ───────────────────────────────────────────────────────────────────

  defp require_string(params, key, label) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> error(200, @invalid_params, "#{label} is required")
    end
  end

  defp require_arguments(params) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> {:ok, arguments}
      _ -> error(200, @invalid_params, "arguments must be an object")
    end
  end

  defp parse_resource_uri(uri) do
    case MCP.parse_uri(uri) do
      {:ok, name, params} ->
        {:ok, name, params}

      :error ->
        # Don't echo the URI back — it is caller-controlled text.
        error(200, @invalid_params, "resource uri must start with offloader://")
    end
  end

  # ── rendering ────────────────────────────────────────────────────────────────

  defp encode(response), do: response |> JSON.encode_to_iodata!() |> IO.iodata_to_binary()

  defp text_content(text), do: %{type: "text", text: text}

  defp resource_content(uri, text), do: %{uri: uri, mimeType: "application/json", text: text}

  # SEP-2549. `cacheScope` is "public" only when `CachePolicy` says these exact bytes
  # may sit in a shared cache — the same decision the REST path renders as
  # `Cache-Control`, so a tenant-scoped result can never be advertised as shareable.
  defp cache_fields(tenant, ttl_seconds) do
    %{
      ttlMs: ttl_seconds * 1000,
      cacheScope: if(CachePolicy.shared?(tenant), do: "public", else: "private")
    }
  end

  # An initialize-era result is the bare payload those revisions define, and never
  # shareable: the request carried no validated `Mcp-Name` to key a cache on.
  defp send_result(%{assigns: %{mcp_era: :legacy}} = conn, id, payload, _cache) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> send_json(200, %{jsonrpc: "2.0", id: id, result: payload})
  end

  defp send_result(conn, id, payload, cache) do
    result =
      payload
      |> Map.put(:resultType, "complete")
      |> Map.put(:_meta, MCP.result_meta())
      |> Map.merge(cache)

    conn
    |> put_cache_header(cache)
    |> send_json(200, %{jsonrpc: "2.0", id: id, result: result})
  end

  # Keep the HTTP layer agreeing with the in-band SEP-2549 fields. A plain CDN cannot
  # read `cacheScope` out of a JSON-RPC body, so the same decision is restated as
  # `Cache-Control` — and a result with no cache fields at all (`tools/call`) is
  # forbidden from a shared cache in both places rather than defaulting to permissive.
  defp put_cache_header(conn, %{cacheScope: "public", ttlMs: ttl_ms}),
    do: put_resp_header(conn, "cache-control", "public, max-age=#{div(ttl_ms, 1000)}")

  defp put_cache_header(conn, _cache),
    do: put_resp_header(conn, "cache-control", "private, no-store")

  defp api_rpc_error(conn, id, %ApiError{} = api_error) do
    {status, code} = rpc_status(api_error.family)
    rpc_error(conn, id, status, code, api_error.message, nil)
  end

  # Auth and readiness are transport-level conditions the client must act on, so they
  # carry the matching HTTP status. Everything else is an ordinary application result.
  defp rpc_status(:unauthorized), do: {401, @invalid_request}
  defp rpc_status(:not_ready), do: {503, @internal_error}
  defp rpc_status(:internal), do: {500, @internal_error}
  defp rpc_status(_family), do: {200, @invalid_params}

  defp rpc_error(conn, id, status, code, message, data) do
    error = %{code: code, message: message}
    error = if data, do: Map.put(error, :data, data), else: error

    conn =
      if status == 401,
        do: put_resp_header(conn, "www-authenticate", ~s(Bearer realm="offloader")),
        else: conn

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> send_json(status, %{jsonrpc: "2.0", id: id, error: error})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(body))
  end

  defp error(status, code, message, data \\ nil), do: {:error, status, code, message, data}
end
