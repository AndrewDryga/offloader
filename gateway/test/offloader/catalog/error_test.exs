defmodule Offloader.Catalog.ErrorTest do
  use ExUnit.Case, async: true

  alias Offloader.Catalog.Error

  describe "new/5 and format/1" do
    test "builds without a hint and formats one operator-readable line" do
      e = Error.new("datasets/x.yml", "columns[2].name", :bad_name, "not a safe identifier")

      assert %Error{file: "datasets/x.yml", path: "columns[2].name", code: :bad_name, hint: nil} =
               e

      assert Error.format(e) ==
               "datasets/x.yml: columns[2].name: not a safe identifier (bad_name)"
    end

    test "carries and appends the hint when present" do
      e =
        Error.new("offloader.yml", "keys", :missing_keys, "no keys file", "point keys: at a file")

      assert e.hint == "point keys: at a file"

      assert Error.format(e) ==
               "offloader.yml: keys: no keys file (missing_keys) — hint: point keys: at a file"
    end
  end
end
