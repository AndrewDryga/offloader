# Compile-time base config, shared by all environments. Runtime/container config
# (ports, secret, env-var contract) lives in runtime.exs.
import Config

# Product (API) endpoint — customer-facing traffic.
config :offloader, OffloaderWeb.ApiEndpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: OffloaderWeb.ErrorJSON], layout: false]

# Admin/metrics endpoint — operator surface, kept off the API port.
config :offloader, OffloaderWeb.AdminEndpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: OffloaderWeb.ErrorJSON], layout: false]

config :offloader, :env, config_env()

config :phoenix, :json_library, JSON

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
