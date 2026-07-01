import Config

# runtime.exs runs at boot in EVERY environment — this is the container's env-var
# contract. Documented in docs/developer-experience.md → "Required container env vars".
# Parse each OFFLOADER_* var once here; Offloader.Config is the typed accessor.

# The env-var contract, read in all environments so tests can assert the defaults.
config :offloader,
  config_path: System.get_env("OFFLOADER_CONFIG"),
  cache_dir:
    System.get_env("OFFLOADER_CACHE_DIR") || Path.join(System.tmp_dir!(), "offloader-cache"),
  object_store_mode: System.get_env("OFFLOADER_OBJECT_STORE_MODE") || "local"

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
