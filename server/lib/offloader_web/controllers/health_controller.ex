defmodule OffloaderWeb.HealthController do
  @moduledoc """
  Liveness/readiness/status probes. `healthz` is the public API-port liveness
  check; `live`/`ready`/`status` are the admin-port operator probes. Readiness and
  status grow real snapshot state in G08/G09 — for now they report process health
  and the build version, and never leak secrets or raw params.
  """

  use OffloaderWeb, :controller

  @doc "Public API-port liveness probe."
  def healthz(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @doc "Admin-port liveness: the process is up."
  def live(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @doc "Admin-port readiness: 200 once every dataset has an active snapshot, else 503."
  def ready(conn, _params) do
    ready = runtime_ready?()
    conn |> put_status(if(ready, do: 200, else: 503)) |> json(%{status: "ok", ready: ready})
  end

  @doc "Admin-port status: service identity and build version."
  def status(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "offloader",
      version: Offloader.version(),
      ready: runtime_ready?()
    })
  end

  # Ready iff the runtime is up and every dataset has an active snapshot.
  defp runtime_ready? do
    is_pid(Process.whereis(Offloader.Runtime)) and Offloader.Runtime.ready?()
  end
end
