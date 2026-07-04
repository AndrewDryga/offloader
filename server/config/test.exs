import Config

# Tests dispatch through the endpoints without booting a server (server: false).
# Distinct ports keep the config valid if a test opts into `server: true`.
test_secret = "test_only_secret_key_base_0123456789abcdef0123456789abcdef0123456789XYZ"

config :offloader, OffloaderWeb.ApiEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: test_secret,
  server: false

config :offloader, OffloaderWeb.AdminEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: test_secret,
  server: false

# Print only warnings and errors during test.
config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
