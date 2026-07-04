defmodule OffloaderWeb.DiagnosticsController do
  @moduledoc """
  Admin-port diagnostics and Prometheus metrics. `/diagnostics` (admin-token gated)
  returns the full operator view; `/metrics` returns Prometheus text for scraping.
  Both read `Offloader.Runtime`; if it is not running yet they degrade gracefully
  rather than crash. Neither ever emits an API key, token, or raw param.
  """

  use OffloaderWeb, :controller

  alias Offloader.{Metrics, Runtime}
  alias Offloader.Metrics.Requests

  def diagnostics(conn, _params) do
    if runtime_up?() do
      json(conn, Runtime.diagnostics())
    else
      conn |> put_status(503) |> json(%{status: "not_ready", detail: "runtime not started"})
    end
  end

  def metrics(conn, _params) do
    # Snapshot/pool gauges from diagnostics + accumulated request counters/histogram.
    snapshot =
      if runtime_up?(),
        do: Metrics.to_prometheus(Runtime.diagnostics()),
        else: "offloader_up 1\noffloader_ready 0\n"

    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, snapshot <> Requests.to_prometheus())
  end

  defp runtime_up?, do: is_pid(Process.whereis(Runtime))
end
