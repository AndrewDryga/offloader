defmodule OffloaderWeb.AllowedHostsTest do
  # OFFLOADER_ALLOWED_HOSTS: when set, the API refuses a request addressed to any other host
  # name, which is how a DNS-rebinding page reaches an internal deployment. Unset changes
  # nothing. async: false — Runtime singleton + the app-env seam.
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Offloader.Runtime

  @endpoint OffloaderWeb.ApiEndpoint
  @public Path.expand("../../../examples/public-metrics/offloader.yml", __DIR__)
  @path "/v1/endpoints/champion?champion_id=1"

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_hosts_#{System.unique_integer([:positive])}")
    {:ok, rt} = Runtime.start_link(name: Runtime, config_path: @public, cache_dir: dir)

    previous =
      Map.new([:allowed_hosts, :cors_origins], &{&1, Application.get_env(:offloader, &1)})

    on_exit(fn ->
      Offloader.TestSupport.stop_if_alive(rt)
      Offloader.TestSupport.rm_rf!(dir)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:offloader, key, value),
          else: Application.delete_env(:offloader, key)
      end
    end)

    :ok
  end

  defp allow(hosts), do: Application.put_env(:offloader, :allowed_hosts, hosts)

  defp get_as(host, path \\ @path), do: build_conn() |> Map.put(:host, host) |> get(path)

  test "unset, every host name is served" do
    Application.delete_env(:offloader, :allowed_hosts)
    assert get_as("evil.example").status == 200
  end

  test "a listed host is served, whatever its case or trailing dot" do
    allow(["offloader.internal"])

    for host <- ["offloader.internal", "OFFLOADER.Internal", "offloader.internal."],
        do: assert(get_as(host).status == 200)
  end

  test "any other host name is refused before anything else runs" do
    allow(["offloader.internal"])
    # With CORS wide open, a refusal that ran after the CORS plug would still carry its header.
    Application.put_env(:offloader, :cors_origins, ["*"])
    conn = get_as("evil.example")

    assert conn.status == 403
    assert %{"error" => %{"family" => "forbidden"}} = JSON.decode!(conn.resp_body)
    assert get_resp_header(conn, "access-control-allow-origin") == []

    mcp = build_conn() |> Map.put(:host, "evil.example") |> post("/mcp", %{})
    assert mcp.status == 403
  end

  test "an IP address or localhost is served: a rebinding page can't send either" do
    allow(["offloader.internal"])

    for host <- ["10.0.0.5", "[::1]", "localhost"],
        do: assert(get_as(host).status == 200)
  end

  test "the load-balancer health check answers whatever the host" do
    allow(["offloader.internal"])
    assert get_as("lb-probe.example", "/healthz").status == 200
  end
end
