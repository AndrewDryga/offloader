defmodule Offloader.Telemetry do
  @moduledoc """
  Telemetry supervisor and metric definitions.

  `metrics/0` is the single source of truth for what the gateway measures; the
  Prometheus exporter on the admin port (task G09) reports exactly this list, so
  metrics and docs never drift.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The metrics the gateway measures. Consumed by the admin-port exporter (G09)."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Phoenix request timing (both endpoints emit under this prefix).
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      # VM health.
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total")
    ]
  end

  # No custom periodic measurements yet; snapshot/refresh gauges land with G08/G09.
  defp periodic_measurements, do: []
end
