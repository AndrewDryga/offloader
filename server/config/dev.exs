import Config

# Local dev: bind both ports to loopback. secret_key_base here is dev-only and
# safe to commit; production reads OFFLOADER_SECRET_KEY_BASE at runtime.
dev_secret = "dev_only_secret_key_base_change_me_0123456789abcdef0123456789abcdefXYZ"

config :offloader, OffloaderWeb.ApiEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  debug_errors: true,
  secret_key_base: dev_secret

config :offloader, OffloaderWeb.AdminEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  check_origin: false,
  debug_errors: true,
  secret_key_base: dev_secret

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
