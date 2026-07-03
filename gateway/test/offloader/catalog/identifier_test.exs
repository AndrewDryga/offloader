defmodule Offloader.Catalog.IdentifierTest do
  # These validators are the only gate between config-supplied names and identifiers the
  # compiler quotes into SQL, so the reject cases matter as much as the accept cases.
  use ExUnit.Case, async: true

  alias Offloader.Catalog.Identifier

  describe "valid?/1 — Offloader-minted ids (dataset / endpoint / param)" do
    test "accepts lowercase-leading snake_case up to 63 chars" do
      assert Identifier.valid?("a")
      assert Identifier.valid?("revenue_by_day")
      assert Identifier.valid?("x1_y2_z3")
      # first char + 62 more = 63, the DuckDB/Postgres identifier cap
      assert Identifier.valid?("a" <> String.duplicate("z", 62))
    end

    test "rejects uppercase, leading digit/underscore, punctuation, spaces, quotes, empty" do
      refute Identifier.valid?("Revenue")
      refute Identifier.valid?("9cost")
      refute Identifier.valid?("_x")
      refute Identifier.valid?("a-b")
      refute Identifier.valid?("a.b")
      refute Identifier.valid?("a b")
      refute Identifier.valid?(~s(a"b))
      refute Identifier.valid?("a;drop")
      refute Identifier.valid?("")
    end

    test "rejects over-length (64 > 63)" do
      refute Identifier.valid?(String.duplicate("a", 64))
    end

    test "rejects non-binary input" do
      refute Identifier.valid?(nil)
      refute Identifier.valid?(:atom)
      refute Identifier.valid?(123)
    end
  end

  describe "valid_column?/1 — producer-shaped column names" do
    test "accepts camelCase, digit-leading, and underscores (still quote-safe)" do
      assert Identifier.valid_column?("situationalItems")
      assert Identifier.valid_column?("5_cost_offset")
      assert Identifier.valid_column?("Account_ID")
      assert Identifier.valid_column?(String.duplicate("a", 63))
    end

    test "rejects quotes, spaces, dots, dashes, empty, and over-length" do
      refute Identifier.valid_column?("a b")
      refute Identifier.valid_column?("a.b")
      refute Identifier.valid_column?("a-b")
      refute Identifier.valid_column?(~s(a"b))
      refute Identifier.valid_column?("")
      refute Identifier.valid_column?(String.duplicate("a", 64))
    end

    test "rejects non-binary input" do
      refute Identifier.valid_column?(nil)
      refute Identifier.valid_column?(123)
    end
  end
end
