defmodule Offloader.ConfigTest do
  use ExUnit.Case, async: true

  test "cache_dir has a concrete default path" do
    assert is_binary(Offloader.Config.cache_dir())
  end

  test "config_path is nil until a config file is mounted" do
    assert Offloader.Config.config_path() == nil
  end

  test "version/0 returns the build version string" do
    assert Offloader.version() =~ ~r/^\d+\.\d+\.\d+/
  end
end
