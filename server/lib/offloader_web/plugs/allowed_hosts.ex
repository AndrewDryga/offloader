defmodule OffloaderWeb.Plugs.AllowedHosts do
  @moduledoc """
  Refuses an API request addressed to a host name the operator didn't list
  (`OFFLOADER_ALLOWED_HOSTS`). That is how a DNS-rebinding page reaches a deployment on a
  private network: the attacker points a name they own at the internal address, and the
  visitor's browser sends that name in `Host` while it reads the replies as its own.

  Unset, every host is served (the default). Set, a request passes when its host is listed,
  is `localhost`, or is an IP address: a rebinding page can't send those, while local tools
  and load balancers' health checks often do. `/healthz` always passes, so a probe that names
  another host can't take an instance out of rotation; it says nothing but "ok".
  """

  @behaviour Plug
  import Plug.Conn

  alias Offloader.ApiError
  alias OffloaderWeb.Response

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Offloader.Config.allowed_hosts() do
      nil -> conn
      hosts -> if allowed?(conn, hosts), do: conn, else: refuse(conn)
    end
  end

  defp allowed?(%Plug.Conn{request_path: "/healthz"}, _hosts), do: true

  defp allowed?(conn, hosts) do
    host = conn.host |> String.downcase() |> String.trim_trailing(".")
    host in hosts or host == "localhost" or ip_address?(host)
  end

  defp ip_address?(host) do
    literal = host |> String.trim_leading("[") |> String.trim_trailing("]")
    match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(literal)))
  end

  defp refuse(conn) do
    error = ApiError.new(:forbidden, "this server doesn't answer to that host name")

    conn
    |> Response.send_error(error, Response.request_id(conn))
    |> halt()
  end
end
