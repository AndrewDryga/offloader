defmodule OffloaderWeb.Plugs.Cors do
  @moduledoc """
  Minimal CORS for the product API, so a browser front-end can call it directly.

  Origins come from `OFFLOADER_CORS_ORIGINS` (`Offloader.Config.cors_origins/0`):

    * unset → no CORS headers (the default; a same-origin or server-side caller is unaffected).
    * `["*"]` → `Access-Control-Allow-Origin: *` — for a public (`auth: none`) API.
    * an explicit list → the request `Origin` is echoed only if it's on the list, with
      `Access-Control-Allow-Credentials: true` so an authed (`Authorization` header) call works.

  Runs before the router, so a preflight `OPTIONS` is answered without hitting auth.
  """

  @behaviour Plug
  import Plug.Conn

  @methods "GET, OPTIONS"
  @allow_headers "authorization, content-type, if-none-match"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Offloader.Config.cors_origins() do
      nil -> conn
      origins -> apply_cors(conn, origins, request_origin(conn))
    end
  end

  # Wildcard is origin-independent, so emit it on EVERY response (even without an
  # `Origin` header): responses may be shared-cached (`Cache-Control: public`), and a
  # copy cached without the header would break a later browser caller.
  defp apply_cors(conn, ["*"], _origin) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> preflight_or_pass(true)
  end

  # An explicit list echoes per-origin, so EVERY response must carry `Vary: Origin` —
  # including no-Origin and off-list requests — or a shared cache stores a no-CORS
  # variant under the bare URL and serves it to allow-listed browsers.
  defp apply_cors(conn, origins, origin) do
    conn = merge_resp_header(conn, "vary", "origin")

    if is_binary(origin) and origin in origins do
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-credentials", "true")
      |> preflight_or_pass(true)
    else
      preflight_or_pass(conn, false)
    end
  end

  # A preflight always gets a terminal 204; a real request continues to the router.
  defp preflight_or_pass(conn, allowed?) do
    cond do
      conn.method != "OPTIONS" ->
        conn

      allowed? ->
        conn
        |> put_resp_header("access-control-allow-methods", @methods)
        |> put_resp_header("access-control-allow-headers", @allow_headers)
        |> put_resp_header("access-control-max-age", "600")
        |> send_resp(204, "")
        |> halt()

      true ->
        conn |> send_resp(204, "") |> halt()
    end
  end

  defp request_origin(conn) do
    case get_req_header(conn, "origin") do
      [origin | _] -> origin
      _ -> nil
    end
  end

  defp merge_resp_header(conn, key, value) do
    case get_resp_header(conn, key) do
      [] -> put_resp_header(conn, key, value)
      _ -> conn
    end
  end
end
