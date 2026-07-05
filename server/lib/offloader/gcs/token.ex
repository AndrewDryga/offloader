defmodule Offloader.Gcs.Token do
  @moduledoc """
  Fetches a Google OAuth2 access token for GCS, trying sources in order and returning
  the first that succeeds:

    1. `OFFLOADER_GCS_TOKEN` — an explicit token from the environment (tests, or an
       operator injecting a token minted elsewhere).
    2. The GCE metadata server — the production path on GCE/GKE, where the VM/pod's
       service account mints tokens locally.
    3. The `gcloud` CLI (`auth application-default print-access-token`, then
       `auth print-access-token`) — the developer-laptop fallback.

  Returns `{:ok, token, expires_in_seconds | nil}` (nil when the source doesn't
  report a lifetime — the cache applies a conservative default) or `{:error, reasons}`
  with one reason per attempted source. Honoring the real `expires_in` matters: the
  metadata server returns a shared, already-aged token that may have only minutes
  left, so a fixed TTL would serve dead tokens.
  """

  @metadata_default "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
  @metadata_timeout_ms 3_000

  @spec fetch() :: {:ok, String.t(), non_neg_integer() | nil} | {:error, [term()]}
  def fetch do
    [&from_env/0, &from_metadata_server/0, &from_gcloud/0]
    |> Enum.reduce_while({:error, []}, fn source, {:error, reasons} ->
      case source.() do
        {:ok, _token, _expires_in} = ok -> {:halt, ok}
        {:error, reason} -> {:cont, {:error, reasons ++ [reason]}}
      end
    end)
  end

  defp from_env do
    case Offloader.Config.gcs_token() do
      token when is_binary(token) and token != "" -> {:ok, token, nil}
      _ -> {:error, :no_env_token}
    end
  end

  defp from_metadata_server do
    url = Application.get_env(:offloader, :gcs_metadata_token_url, @metadata_default)
    :ok = ensure_httpc()

    request = {String.to_charlist(url), [{~c"Metadata-Flavor", ~c"Google"}]}
    opts = [timeout: @metadata_timeout_ms, connect_timeout: @metadata_timeout_ms]

    case :httpc.request(:get, request, opts, body_format: :binary) do
      {:ok, {{_v, 200, _}, _headers, body}} ->
        case JSON.decode(body) do
          {:ok, %{"access_token" => token} = payload} ->
            {:ok, token, integer_or_nil(payload["expires_in"])}

          _ ->
            {:error, {:metadata_server, :invalid_body}}
        end

      {:ok, {{_v, status, _}, _headers, _body}} ->
        {:error, {:metadata_server, status}}

      {:error, reason} ->
        {:error, {:metadata_server, reason}}
    end
  end

  defp from_gcloud do
    ["application-default", nil]
    |> Enum.reduce_while({:error, :gcloud_unavailable}, fn variant, acc ->
      args =
        case variant do
          "application-default" -> ["auth", "application-default", "print-access-token"]
          nil -> ["auth", "print-access-token"]
        end

      case gcloud(args) do
        {:ok, token} -> {:halt, {:ok, token, nil}}
        :error -> {:cont, acc}
      end
    end)
  end

  defp gcloud(args) do
    case System.cmd("gcloud", args, stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> :error
          token -> {:ok, token}
        end

      {_out, _nonzero} ->
        :error
    end
  rescue
    # gcloud not installed
    ErlangError -> :error
  end

  defp integer_or_nil(n) when is_integer(n) and n > 0, do: n
  defp integer_or_nil(_), do: nil

  defp ensure_httpc do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end
end
