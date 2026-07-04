defmodule Offloader.Gcs.Client do
  @moduledoc """
  The real `Offloader.Source.GcsClient`: GCS JSON API over `:httpc` (no extra deps)
  with bearer tokens from `Offloader.Gcs.TokenCache`. Listings paginate; a 401 forces
  one token refresh and a single retry (the cache may hold a token GCS just rejected).
  TLS is verified against the OS trust store.
  """

  @behaviour Offloader.Source.GcsClient

  @default_base "https://storage.googleapis.com"
  @page_size 1_000
  @timeout_ms 30_000

  @impl true
  def list_objects(bucket, prefix) do
    with_auth_retry(fn token -> list_all(bucket, prefix, token, nil, []) end)
  end

  @impl true
  def get_object(bucket, name) do
    with_auth_retry(fn token ->
      url = "#{base_url()}/storage/v1/b/#{encode(bucket)}/o/#{encode(name)}?alt=media"

      case request(url, token) do
        {:ok, 200, body} -> {:ok, body}
        {:ok, 401, _} -> {:error, :unauthorized}
        {:ok, status, _} -> {:error, {:gcs_api_error, status}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  The URL DuckDB should read an object through, per the configured auth mode: HMAC
  (`OFFLOADER_S3_TYPE=gcs`) covers `gs://` paths; otherwise the plain HTTPS form,
  which the bearer HTTP secret (or a public bucket) covers.
  """
  @spec object_url(String.t(), String.t()) :: String.t()
  def object_url(bucket, name) do
    case Offloader.Config.object_store() do
      %{type: "gcs"} -> "gs://#{bucket}/#{name}"
      _ -> "#{base_url()}/#{bucket}/#{encode_path(name)}"
    end
  end

  # ── listing with pagination ─────────────────────────────────────────────────────

  defp list_all(bucket, prefix, token, page_token, acc) do
    params =
      [
        {"prefix", prefix},
        {"maxResults", Integer.to_string(@page_size)},
        {"fields", "items(name,updated,size),nextPageToken"}
      ] ++ if(page_token, do: [{"pageToken", page_token}], else: [])

    url = "#{base_url()}/storage/v1/b/#{encode(bucket)}/o?" <> URI.encode_query(params)

    with {:ok, 200, body} <- request(url, token),
         {:ok, payload} <- Jason.decode(body) do
      items = acc ++ (payload["items"] || [])

      case payload["nextPageToken"] do
        nil -> {:ok, items}
        next -> list_all(bucket, prefix, token, next, items)
      end
    else
      {:ok, 401, _} -> {:error, :unauthorized}
      {:ok, status, _} -> {:error, {:gcs_api_error, status}}
      {:error, %Jason.DecodeError{}} -> {:error, {:gcs_api_error, :invalid_json}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── auth + transport ────────────────────────────────────────────────────────────

  defp with_auth_retry(fun) do
    if Offloader.Config.gcs_anonymous?() do
      # Public bucket, no credentials: issue the request unauthenticated. A 401/403 here
      # means the bucket isn't actually public — surfaced to the caller, not token-refreshed.
      fun.(nil)
    else
      cache = token_cache()

      with {:ok, token} <- Offloader.Gcs.TokenCache.get(cache) do
        case fun.(token) do
          {:error, :unauthorized} ->
            with {:ok, fresh} <- Offloader.Gcs.TokenCache.refresh(cache), do: fun.(fresh)

          other ->
            other
        end
      end
    end
  end

  # Which TokenCache server to ask — overridable so tests point at their own
  # instance with a controlled fetcher instead of the supervised global.
  defp token_cache,
    do: Application.get_env(:offloader, :gcs_token_cache, Offloader.Gcs.TokenCache)

  defp request(url, token) do
    :ok = ensure_started()

    headers =
      case token do
        nil -> []
        t -> [{~c"authorization", String.to_charlist("Bearer " <> t)}]
      end

    http_opts = [
      timeout: @timeout_ms,
      connect_timeout: 10_000,
      ssl: ssl_opts(url)
    ]

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts, body_format: :binary) do
      {:ok, {{_v, status, _}, _headers, body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ssl_opts("https://" <> _) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp ssl_opts(_http), do: []

  defp base_url, do: Application.get_env(:offloader, :gcs_base_url, @default_base)

  defp encode(segment), do: URI.encode_www_form(segment)

  # Encode an object name for the path form, keeping `/` separators.
  defp encode_path(name),
    do: name |> String.split("/") |> Enum.map_join("/", &URI.encode_www_form/1)

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end
end
