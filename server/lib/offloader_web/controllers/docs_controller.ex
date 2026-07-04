defmodule OffloaderWeb.DocsController do
  @moduledoc """
  Admin-port generated documentation for the product API: an endpoint catalog
  (`/docs`) and an OpenAPI spec (`/openapi.json`), both generated from the loaded
  contracts so they can't drift from what the runtime enforces. Contains no secrets,
  so it is open on the (private) admin port — but never served from the API port.
  """

  use OffloaderWeb, :controller

  alias Offloader.{Docs, Runtime}

  def catalog(conn, _params) do
    with_catalog(conn, &Docs.catalog/1)
  end

  def schema(conn, _params) do
    with_catalog(conn, &Docs.schema/1)
  end

  def openapi(conn, _params) do
    with_catalog(conn, &Docs.openapi/1)
  end

  defp with_catalog(conn, build) do
    if is_pid(Process.whereis(Runtime)),
      do: json(conn, build.(Runtime.catalog())),
      else: conn |> put_status(503) |> json(%{status: "not_ready", detail: "runtime not started"})
  end
end
