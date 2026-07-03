defmodule OffloaderWebTest do
  # router/0 and controller/0 run at compile time in the real endpoints, so coverage never
  # sees them — exercise them directly and assert they wire the pieces the web layer needs.
  use ExUnit.Case, async: true

  test "router/0 wires Phoenix.Router + Plug.Conn + Phoenix.Controller helpers" do
    src = Macro.to_string(OffloaderWeb.router())
    assert src =~ "Phoenix.Router"
    assert src =~ "Plug.Conn"
    assert src =~ "Phoenix.Controller"
  end

  test "controller/0 wires a JSON-only Phoenix.Controller" do
    src = Macro.to_string(OffloaderWeb.controller())
    assert src =~ "Phoenix.Controller"
    assert src =~ "formats: [:json]"
    assert src =~ "Plug.Conn"
  end
end
