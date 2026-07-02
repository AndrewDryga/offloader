defmodule Offloader.ObjectStore do
  @moduledoc """
  Remote object-store (S3 / GCS) access for DuckDB. Offloader's manifests may point a
  snapshot's files at `s3://…`, `gs://…`, or `https://…` instead of local paths;
  DuckDB reads them directly through its `httpfs` extension. This module registers the
  credentials on each DuckDB connection so `read_parquet('s3://…')` just works.

  Credentials come from env vars (parsed once in `config/runtime.exs`), never from a
  request. We register them as a DuckDB **secret** (`CREATE OR REPLACE SECRET`), which
  is idempotent per connection and keeps the raw keys out of every generated SQL
  string. `http(s)://` sources need no credentials (public objects / signed URLs).

  Boring on purpose: one S3-compatible path (AWS S3, MinIO, Cloudflare R2, and GCS via
  its S3 interoperability endpoint) plus native GCS HMAC. `configure/2` is a no-op in
  local mode, so nothing changes for filesystem deployments.
  """

  alias Offloader.Sql

  @type t :: %{
          required(:type) => String.t(),
          optional(:key_id) => String.t() | nil,
          optional(:secret) => String.t() | nil,
          optional(:region) => String.t() | nil,
          optional(:endpoint) => String.t() | nil,
          optional(:url_style) => String.t() | nil,
          optional(:use_ssl) => boolean() | nil,
          optional(:session_token) => String.t() | nil
        }

  @doc """
  Apply object-store credentials to a DuckDB `conn`. No-op (`:ok`) when `config` is
  `nil` (local mode). Otherwise loads `httpfs` and registers the secret. For
  `type: "gcs_bearer"` the token comes from `Offloader.Gcs.TokenCache` (or an explicit
  `:token`, mainly for tests). Errors never echo a credential — values are scrubbed.
  """
  @spec configure(reference(), t() | nil) :: :ok | {:error, term()}
  def configure(_conn, nil), do: :ok

  def configure(conn, %{} = config) do
    # Resolve first (bearer mode fetches the token into `resolved`), THEN register the
    # secret — and scrub against `resolved`, since that is the map whose credential the
    # DDL embedded and could echo back in an error. A resolve failure carries no
    # credential, so it needs no scrub.
    with {:ok, resolved} <- resolve_credentials(config) do
      case apply_secret(conn, resolved) do
        :ok -> :ok
        {:error, reason} -> {:error, redact(reason, resolved)}
      end
    end
  end

  defp apply_secret(conn, resolved) do
    with {:ok, _} <- Duckdbex.query(conn, "INSTALL httpfs;"),
         {:ok, _} <- Duckdbex.query(conn, "LOAD httpfs;"),
         {:ok, _} <- Duckdbex.query(conn, secret_ddl(resolved)) do
      :ok
    end
  end

  # Bearer mode resolves its token at apply time, so a re-apply after a token refresh
  # registers the CURRENT token (the engine re-applies periodically).
  defp resolve_credentials(%{type: "gcs_bearer"} = config) do
    case config[:token] do
      token when is_binary(token) and token != "" ->
        {:ok, config}

      _ ->
        with {:ok, token} <- Offloader.Gcs.TokenCache.get() do
          {:ok, Map.put(config, :token, token)}
        end
    end
  end

  defp resolve_credentials(config), do: {:ok, config}

  @doc """
  Replace any credential value from `config` that leaked into an error `reason`. Public
  and pure so the redaction of every credential shape (bearer token, HMAC key/secret,
  session token) is directly testable — the token is the whole reason this exists.
  """
  @spec redact(term(), t()) :: term()
  def redact(reason, config) when is_binary(reason) do
    [:secret, :token, :key_id, :session_token]
    |> Enum.map(&config[&1])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.reduce(reason, &String.replace(&2, &1, "[redacted]"))
  end

  def redact(reason, _config), do: reason

  @doc """
  The `CREATE OR REPLACE SECRET` DDL for a config. Pure and testable; values are
  single-quote-escaped. Public so it can be unit-tested without a live connection.
  """
  @spec secret_ddl(t()) :: String.t()
  def secret_ddl(%{type: "gcs_bearer", token: token}) do
    "CREATE OR REPLACE SECRET offloader_store " <>
      "(TYPE HTTP, BEARER_TOKEN '#{Sql.escape(token)}');"
  end

  def secret_ddl(%{type: type} = config) do
    fields =
      config
      |> secret_fields(type)
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map(&render_field/1)

    inner = Enum.join(["TYPE #{secret_type(type)}" | fields], ", ")
    "CREATE OR REPLACE SECRET offloader_store (#{inner});"
  end

  @doc """
  True when a manifest file path is a remote URL DuckDB reads over the network
  (`s3://`, `gs://`, `gcs://`, `az://`, `http://`, `https://`) rather than a local file.
  """
  @spec remote_path?(String.t()) :: boolean()
  def remote_path?(path) when is_binary(path) do
    String.match?(path, ~r{^(s3|gs|gcs|az|azure|r2|http|https)://}i)
  end

  def remote_path?(_), do: false

  @doc """
  Build a config map from parsed env, or `nil` when no remote store is configured.
  `type` gates it: unset ⇒ local mode.
  """
  @spec from_env(map()) :: t() | nil
  def from_env(env) when is_map(env) do
    case env[:type] do
      t when t in ["s3", "gcs"] ->
        %{
          type: t,
          key_id: env[:key_id],
          secret: env[:secret],
          region: env[:region],
          endpoint: env[:endpoint],
          url_style: env[:url_style],
          use_ssl: env[:use_ssl],
          session_token: env[:session_token]
        }

      _ ->
        nil
    end
  end

  def from_env(_), do: nil

  # ── internals ──────────────────────────────────────────────────────────────────

  # GCS HMAC uses only KEY_ID/SECRET; S3 (and S3-compatible incl. GCS-over-S3) takes
  # the full set. DuckDB ignores unknown/empty fields we drop above.
  defp secret_fields(config, "gcs") do
    [key_id: config[:key_id], secret: config[:secret]]
  end

  defp secret_fields(config, _s3) do
    [
      key_id: config[:key_id],
      secret: config[:secret],
      region: config[:region],
      endpoint: config[:endpoint],
      url_style: config[:url_style],
      session_token: config[:session_token],
      use_ssl: config[:use_ssl]
    ]
  end

  defp secret_type("gcs"), do: "GCS"
  defp secret_type(_), do: "S3"

  defp render_field({:use_ssl, value}) when is_boolean(value), do: "USE_SSL #{value}"
  defp render_field({key, value}), do: "#{field_name(key)} '#{Sql.escape(to_string(value))}'"

  defp field_name(:key_id), do: "KEY_ID"
  defp field_name(:secret), do: "SECRET"
  defp field_name(:region), do: "REGION"
  defp field_name(:endpoint), do: "ENDPOINT"
  defp field_name(:url_style), do: "URL_STYLE"
  defp field_name(:session_token), do: "SESSION_TOKEN"
end
