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

  @doc "Admin-port readiness: the instance can serve. Snapshot readiness added in G08."
  def ready(conn, _params) do
    json(conn, %{status: "ok", ready: true})
  end

  @doc "Admin-port status: service identity and build version."
  def status(conn, _params) do
    json(conn, %{status: "ok", service: "offloader", version: Offloader.version()})
  end
end
