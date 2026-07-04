defmodule OffloaderTest do
  use ExUnit.Case, async: true

  test "version/0 returns the running build version as a non-empty string" do
    v = Offloader.version()
    assert is_binary(v)
    assert v != ""
  end
end
