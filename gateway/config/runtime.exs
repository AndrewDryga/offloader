import Config

# runtime.exs runs at boot in EVERY environment — this is the container's env-var
# contract. Documented in docs/developer-experience.md → "Required container env vars".
# Parse each OFFLOADER_* var once here; Offloader.Config is the typed accessor.

# DuckDB read-connection pool size — unset => engine default; must be a positive int.
pool_size =
  case System.get_env("OFFLOADER_POOL_SIZE") do
    nil ->
      nil

    raw ->
      case Integer.parse(raw) do
        {n, ""} when n > 0 -> n
        _ -> nil
      end
  end

# Remote object store — unset => local filesystem. Set OFFLOADER_S3_TYPE=s3|gcs to
# read snapshot files from s3:// / gs:// URLs (GCS uses HMAC KEY_ID/SECRET), or
# OFFLOADER_GCS_AUTH=bearer to read GCS over HTTPS with OAuth bearer tokens (from
# OFFLOADER_GCS_TOKEN, the GCE metadata server, or the gcloud CLI — in that order).
# Explicit HMAC credentials win when both are set.
object_store =
  case {System.get_env("OFFLOADER_S3_TYPE"), System.get_env("OFFLOADER_GCS_AUTH")} do
    {type, _} when type in ["s3", "gcs"] ->
      %{
        type: type,
        key_id: System.get_env("OFFLOADER_S3_KEY_ID"),
        secret: System.get_env("OFFLOADER_S3_SECRET"),
        region: System.get_env("OFFLOADER_S3_REGION"),
        endpoint: System.get_env("OFFLOADER_S3_ENDPOINT"),
        url_style: System.get_env("OFFLOADER_S3_URL_STYLE"),
        session_token: System.get_env("OFFLOADER_S3_SESSION_TOKEN"),
        use_ssl:
          case System.get_env("OFFLOADER_S3_USE_SSL") do
            "false" -> false
            "true" -> true
            _ -> nil
          end
      }

    {_, "bearer"} ->
      %{type: "gcs_bearer"}

    _ ->
      nil
  end

# The env-var contract, read in all environments so tests can assert the defaults.
config :offloader,
  config_path: System.get_env("OFFLOADER_CONFIG"),
  cache_dir:
    System.get_env("OFFLOADER_CACHE_DIR") || Path.join(System.tmp_dir!(), "offloader-cache"),
  pool_size: pool_size,
  object_store: object_store,
  gcs_token: System.get_env("OFFLOADER_GCS_TOKEN"),
  duckdb_threads:
    (case System.get_env("OFFLOADER_DUCKDB_THREADS") do
       nil ->
         nil

       raw ->
         case Integer.parse(raw) do
           {n, ""} when n > 0 -> n
           _ -> nil
         end
     end),
  duckdb_memory_limit: System.get_env("OFFLOADER_DUCKDB_MEMORY_LIMIT"),
  # Gates the admin /diagnostics route. Unset => diagnostics fail closed (403).
  admin_token: System.get_env("OFFLOADER_ADMIN_TOKEN")

# Optional log level override (e.g. OFFLOADER_LOG_LEVEL=debug). Unknown values are
# ignored rather than crashing the boot.
if level = System.get_env("OFFLOADER_LOG_LEVEL") do
  case level do
    l when l in ~w(emergency alert critical error warning notice info debug) ->
      config :logger, level: String.to_existing_atom(l)

    _ ->
      :ok
  end
end

# `PHX_SERVER=1 bin/offloader start` boots the HTTP servers when running a release.
if System.get_env("PHX_SERVER") do
  config :offloader, OffloaderWeb.ApiEndpoint, server: true
  config :offloader, OffloaderWeb.AdminEndpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("OFFLOADER_SECRET_KEY_BASE") ||
      raise """
      environment variable OFFLOADER_SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret
      """

  api_port = String.to_integer(System.get_env("OFFLOADER_API_PORT") || "4000")
  admin_port = String.to_integer(System.get_env("OFFLOADER_ADMIN_PORT") || "4001")

  # Bind both ports on all interfaces inside the container; the operator restricts
  # who can reach the admin port with their own network/proxy controls.
  config :offloader, OffloaderWeb.ApiEndpoint,
    server: true,
    http: [ip: {0, 0, 0, 0}, port: api_port],
    secret_key_base: secret_key_base

  config :offloader, OffloaderWeb.AdminEndpoint,
    server: true,
    http: [ip: {0, 0, 0, 0}, port: admin_port],
    secret_key_base: secret_key_base
end
