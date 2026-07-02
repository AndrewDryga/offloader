defmodule Offloader.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        Offloader.Telemetry,
        # Accumulates per-endpoint request counters + latency histogram for /metrics.
        Offloader.Metrics.Requests,
        # Fire-and-forget cleanup (superseded-snapshot table drops) off the Runtime mailbox.
        {Task.Supervisor, name: Offloader.TaskSupervisor},
        # Refresh workers register here, keyed {runtime_pid, dataset_id} — scoped so
        # concurrently-running runtimes (tests) never collide.
        {Registry, keys: :unique, name: Offloader.Refresh.Registry},
        # GCS bearer-token cache: idle unless a GCS source / gcs_bearer store is used.
        Offloader.Gcs.TokenCache,
        # Product traffic (endpoint API keys, tenant enforcement — added by later tasks).
        OffloaderWeb.ApiEndpoint,
        # Operator surface (health/metrics/diagnostics/docs). Keep it off the API port.
        OffloaderWeb.AdminEndpoint
      ] ++ runtime_children()

    opts = [strategy: :one_for_one, name: Offloader.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        log_ports()
        {:ok, pid}

      other ->
        other
    end
  end

  # Print a single, unambiguous line about which port is which — so an operator can
  # see at a glance that the ADMIN surface (health/metrics/diagnostics/docs) is a
  # separate port they must keep private (it is NOT an identity product).
  defp log_ports do
    api = port(OffloaderWeb.ApiEndpoint)
    admin = port(OffloaderWeb.AdminEndpoint)

    Logger.info(
      "Offloader ports — API #{api} (product traffic, API-key auth); " <>
        "ADMIN #{admin} (health/metrics/diagnostics/docs). " <>
        "Keep the ADMIN port private with your own network/proxy/IAM controls."
    )
  end

  defp port(endpoint) do
    case endpoint.config(:http) do
      http when is_list(http) -> Keyword.get(http, :port, "unset")
      _ -> "unset"
    end
  end

  # Phoenix calls this on a hot config change so each endpoint re-reads its config.
  @impl true
  def config_change(changed, _new, removed) do
    OffloaderWeb.ApiEndpoint.config_change(changed, removed)
    OffloaderWeb.AdminEndpoint.config_change(changed, removed)
    :ok
  end

  # Only run the serving runtime when a config file is mounted (OFFLOADER_CONFIG).
  # Without it the gateway still boots and serves health; endpoints answer not_ready.
  # Tests start their own named Offloader.Runtime, so skip the boot one under :test.
  # Config.Sync starts AFTER the Runtime (it reloads it) and only when auto-sync is enabled.
  defp runtime_children do
    if Offloader.Config.config_path() && offloader_env() != :test,
      do: [Offloader.Runtime | sync_children()],
      else: []
  end

  defp sync_children do
    interval = Offloader.Config.config_sync_interval_ms()
    if is_integer(interval) and interval > 0, do: [Offloader.Config.Sync], else: []
  end

  defp offloader_env do
    Application.get_env(:offloader, :env, :prod)
  end
end
