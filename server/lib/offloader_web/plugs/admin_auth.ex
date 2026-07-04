defmodule OffloaderWeb.Plugs.AdminAuth do
  @moduledoc """
  Gates the sensitive admin `/diagnostics` route with `OFFLOADER_ADMIN_TOKEN`.

  Fail-closed: if the token is not configured, diagnostics is refused (403) — the
  operator must set it deliberately. This is NOT an identity system; it is a single
  shared token so diagnostics is not readable by anyone who can reach the admin port.
  Health/status/metrics stay open for probes and Prometheus scraping on the (private)
  admin port. Comparison is constant-time.
  """

  @behaviour Plug

  import Plug.Conn
  alias Offloader.{ApiError, Config}
  alias OffloaderWeb.Response

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    request_id = Response.request_id(conn)

    case Config.admin_token() do
      token when is_binary(token) and token != "" ->
        if presented(conn) |> valid?(token),
          do: conn,
          else: halt_error(conn, :unauthorized, "invalid admin token", request_id)

      _ ->
        halt_error(
          conn,
          :not_ready,
          "admin token not configured (set OFFLOADER_ADMIN_TOKEN)",
          request_id
        )
    end
  end

  defp presented(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> ""
    end
  end

  defp valid?(presented, token) do
    byte_size(presented) == byte_size(token) and Plug.Crypto.secure_compare(presented, token)
  end

  defp halt_error(conn, family, message, request_id) do
    conn |> Response.send_error(ApiError.new(family, message), request_id) |> halt()
  end
end
