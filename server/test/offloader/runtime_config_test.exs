defmodule Offloader.RuntimeConfigTest do
  # The container's env contract lives in config/runtime.exs; read it the way a boot does.
  # async: false — it sets process-wide environment variables.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  defp read_with(env, vars) do
    previous = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)
    Enum.each(vars, fn {name, value} -> put_env(name, value) end)

    try do
      Config.Reader.read!(@runtime, env: env)
    after
      Enum.each(previous, fn {name, value} -> put_env(name, value) end)
    end
  end

  defp put_env(name, nil), do: System.delete_env(name)
  defp put_env(name, value), do: System.put_env(name, value)

  defp api_http(config), do: get_in(config, [:offloader, OffloaderWeb.ApiEndpoint, :http])

  test "API responses are compressed unless OFFLOADER_COMPRESSION turns it off" do
    for value <- [nil, "on", "true"] do
      http = api_http(read_with(:test, %{"OFFLOADER_COMPRESSION" => value}))
      assert http[:http_options][:compress] == true
    end

    for value <- ["off", "false", "0", "no"] do
      http = api_http(read_with(:test, %{"OFFLOADER_COMPRESSION" => value}))
      assert http[:http_options][:compress] == false
    end
  end

  test "OFFLOADER_ALLOWED_HOSTS is a lowercased list; unset or blank means no check" do
    hosts = fn value ->
      get_in(read_with(:test, %{"OFFLOADER_ALLOWED_HOSTS" => value}), [:offloader, :allowed_hosts])
    end

    assert hosts.(nil) == nil
    assert hosts.(" , ") == nil

    assert hosts.(" API.example.com:443 , offloader.internal. ") == [
             "api.example.com",
             "offloader.internal"
           ]

    # These could never match, so they would quietly refuse every request by name.
    for bad <- ["https://api.example.com", "*.internal", "api.example.com/v1", "пример.рф"] do
      assert_raise RuntimeError, ~r/isn't a host name/, fn -> hosts.(bad) end
    end
  end

  test "in a container the switch sits alongside the port the API binds" do
    vars = %{
      "OFFLOADER_COMPRESSION" => "off",
      "OFFLOADER_SECRET_KEY_BASE" => String.duplicate("k", 64),
      "OFFLOADER_API_PORT" => "4321"
    }

    http = api_http(read_with(:prod, vars))
    assert http[:port] == 4321
    assert http[:http_options][:compress] == false
  end
end
