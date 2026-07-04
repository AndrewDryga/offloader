defmodule Offloader.S3.Client do
  @moduledoc """
  An S3 config source: `list-objects-v2` + `get-object` over `:httpc`, AWS **SigV4**-signed
  (or anonymous for a public bucket). Implements `Offloader.Source.GcsClient` so the config
  loader can fetch a project tree from `s3://` exactly as it does from `gs://`.

  Credentials come from `OFFLOADER_S3_*` (`Offloader.Config.object_store/0`): with a key/secret
  the request is signed, without them it goes out unauthenticated (public bucket). Virtual-hosted
  AWS addressing by default (`<bucket>.s3.<region>.amazonaws.com`); `OFFLOADER_S3_ENDPOINT` (or
  `:s3_base_url` in tests) switches to a path-style base for S3-compatible stores. DuckDB still
  reads snapshot DATA via its own S3 secret; this is only the control-plane config fetch. TLS is
  verified for https.
  """

  @behaviour Offloader.Source.GcsClient

  @service "s3"
  @timeout_ms 30_000
  @empty_sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @impl true
  def list_objects(bucket, prefix), do: list_all(bucket, prefix, nil, [])

  @impl true
  def get_object(bucket, key) do
    case request(bucket, "/" <> encode_path(key), []) do
      {:ok, 200, body} -> {:ok, body}
      {:ok, status, _} when status in [401, 403] -> {:error, :unauthorized}
      {:ok, status, _} -> {:error, {:s3_api_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── listing (list-objects-v2, paginated via continuation-token) ─────────────────

  defp list_all(bucket, prefix, continuation, acc) do
    query =
      [{"list-type", "2"}, {"prefix", prefix}] ++
        if continuation, do: [{"continuation-token", continuation}], else: []

    case request(bucket, "/", query) do
      {:ok, 200, body} ->
        items = parse_contents(body)

        case parse_tag(body, "NextContinuationToken") do
          nil -> {:ok, acc ++ items}
          next -> list_all(bucket, prefix, next, acc ++ items)
        end

      {:ok, status, _} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, status, _} ->
        {:error, {:s3_api_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Each <Contents> block → the GcsClient item shape (name/updated/size). Regex is enough for
  # the small, trusted config listing; keys are simple object paths.
  defp parse_contents(xml) do
    Regex.scan(~r{<Contents>(.*?)</Contents>}s, xml)
    |> Enum.map(fn [_, inner] ->
      %{
        "name" => unescape(parse_tag(inner, "Key") || ""),
        "updated" => parse_tag(inner, "LastModified"),
        "size" => parse_tag(inner, "Size")
      }
    end)
  end

  defp parse_tag(xml, tag) do
    case Regex.run(~r{<#{tag}>([^<]*)</#{tag}>}, xml) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp unescape(s),
    do:
      s
      |> String.replace("&amp;", "&")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")

  # ── request + SigV4 ─────────────────────────────────────────────────────────────

  defp request(bucket, path, query) do
    :ok = ensure_started()
    cfg = Offloader.Config.object_store() || %{}
    region = cfg[:region] || "us-east-1"
    qs = canonical_query(query)

    # Default: AWS virtual-hosted (bucket.s3.region.amazonaws.com; signed URI = path). With an
    # explicit base (OFFLOADER_S3_ENDPOINT for S3-compatible stores, or :s3_base_url in tests):
    # path-style (signed URI = /bucket + path).
    {host, canonical_uri, url_base, https?} =
      case base_url(cfg) do
        nil ->
          h = "#{bucket}.s3.#{region}.amazonaws.com"
          {h, path, "https://" <> h <> path, true}

        base ->
          %URI{host: bh, port: bp, scheme: bs} = URI.parse(base)
          host_hdr = if bp in [nil, 80, 443], do: bh, else: "#{bh}:#{bp}"
          uri = "/" <> bucket <> path
          {host_hdr, uri, base <> uri, bs == "https"}
      end

    url = url_base <> if(qs == "", do: "", else: "?" <> qs)
    headers = auth_headers(cfg, host, canonical_uri, qs, region)

    http_opts = [
      timeout: @timeout_ms,
      connect_timeout: 10_000,
      ssl: if(https?, do: ssl_opts(), else: [])
    ]

    req = {String.to_charlist(url), headers}

    case :httpc.request(:get, req, http_opts, body_format: :binary) do
      {:ok, {{_v, status, _}, _h, body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  # Explicit base for a custom/S3-compatible endpoint or a test stub; nil ⇒ AWS virtual-hosted.
  defp base_url(cfg) do
    case Application.get_env(:offloader, :s3_base_url) || cfg[:endpoint] do
      nil -> nil
      "http://" <> _ = url -> url
      "https://" <> _ = url -> url
      host -> "https://" <> host
    end
  end

  # Signed headers when a key/secret is present; bare host header when anonymous.
  defp auth_headers(%{key_id: key, secret: secret} = cfg, host, path, qs, region)
       when is_binary(key) and key != "" and is_binary(secret) and secret != "" do
    {amz_date, datestamp} = timestamps()
    token = cfg[:session_token]

    base = [
      {"host", host},
      {"x-amz-content-sha256", @empty_sha256},
      {"x-amz-date", amz_date}
    ]

    base = if token && token != "", do: base ++ [{"x-amz-security-token", token}], else: base
    signed_headers = base |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.join(";")

    canonical_headers =
      base |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join("", fn {k, v} -> "#{k}:#{v}\n" end)

    canonical_request =
      Enum.join(
        ["GET", path, qs, canonical_headers, signed_headers, @empty_sha256],
        "\n"
      )

    scope = "#{datestamp}/#{region}/#{@service}/aws4_request"

    string_to_sign =
      Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, hex(sha256(canonical_request))], "\n")

    signature = hex(hmac(signing_key(secret, datestamp, region), string_to_sign))

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{key}/#{scope}, " <>
        "SignedHeaders=#{signed_headers}, Signature=#{signature}"

    to_httpc_headers([{"authorization", authorization} | base])
  end

  # No credentials → anonymous (public bucket): only the host header.
  defp auth_headers(_cfg, host, _path, _qs, _region), do: to_httpc_headers([{"host", host}])

  defp signing_key(secret, datestamp, region) do
    ("AWS4" <> secret)
    |> hmac(datestamp)
    |> hmac(region)
    |> hmac(@service)
    |> hmac("aws4_request")
  end

  # Sorted, RFC3986-encoded `k=v` pairs joined by `&`.
  defp canonical_query(query) do
    query
    |> Enum.map(fn {k, v} -> {aws_encode(to_string(k)), aws_encode(to_string(v))} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  # Encode a path, keeping `/` separators (each segment RFC3986-encoded).
  defp encode_path(key), do: key |> String.split("/") |> Enum.map_join("/", &aws_encode/1)

  # RFC3986 unreserved set unencoded; everything else %-encoded (AWS-style, uppercase hex).
  defp aws_encode(s) do
    s
    |> :binary.bin_to_list()
    |> Enum.map_join(fn c ->
      cond do
        c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?-, ?_, ?., ?~] ->
          <<c>>

        true ->
          "%" <> (c |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
      end
    end)
  end

  defp to_httpc_headers(list),
    do: Enum.map(list, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

  # UTC now as {amz_date "YYYYMMDDTHHMMSSZ", datestamp "YYYYMMDD"}. Overridable for tests.
  defp timestamps do
    dt = Application.get_env(:offloader, :s3_clock, &DateTime.utc_now/0).()
    p = &String.pad_leading(Integer.to_string(&1), 2, "0")
    date = "#{dt.year}#{p.(dt.month)}#{p.(dt.day)}"
    {"#{date}T#{p.(dt.hour)}#{p.(dt.minute)}#{p.(dt.second)}Z", date}
  end

  defp sha256(data), do: :crypto.hash(:sha256, data)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end
end
