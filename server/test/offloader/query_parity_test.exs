defmodule Offloader.QueryParityTest do
  # upstream query-model parity: `combinations` (exact-set match on client-sent declared
  # params, checked BEFORE defaults), per-param `aliases` (value→value rewrite with the
  # Plug `+`→space fix), and `?columns=` (an allowlist-bounded projection subset).
  use ExUnit.Case, async: true

  alias Offloader.{ApiError, Compiler}
  alias Offloader.Catalog.{Dataset, Endpoint}

  defp dataset do
    {:ok, ds} =
      Dataset.parse(
        %{
          "id" => "stats",
          "manifest" => "m.json",
          "schema" => [
            %{"name" => "rank", "type" => "VARCHAR"},
            %{"name" => "map_code", "type" => "VARCHAR"},
            %{"name" => "games", "type" => "BIGINT"},
            %{"name" => "data", "type" => "JSON"}
          ]
        },
        "datasets/stats.yml"
      )

    ds
  end

  defp endpoint(overrides) do
    base = %{
      "name" => "stats",
      "version" => 1,
      "owner" => "team@example.com",
      "dataset" => "stats",
      "params" => [
        %{"name" => "rank", "type" => "string", "required" => false, "default" => "ALL"},
        %{"name" => "map_code", "type" => "string", "required" => false, "default" => "ALL"}
      ],
      "query" => %{
        "select" => [
          %{"as" => "rank", "column" => "rank"},
          %{"as" => "games", "column" => "games"},
          %{"as" => "data", "column" => "data"}
        ],
        "filters" => [
          %{"column" => "rank", "op" => "eq", "param" => "rank"},
          %{"column" => "map_code", "op" => "eq", "param" => "map_code"}
        ],
        "order_by" => [%{"column" => "games", "dir" => "desc"}]
      },
      "columns" => ["rank", "games", "data"]
    }

    Endpoint.parse(Map.merge(base, overrides), "endpoints/stats.yml", dataset())
  end

  defp compile(ep, request), do: Compiler.compile(ep, request, nil, {:table, "stats"})

  describe "combinations" do
    test "a request matching a declared combination compiles" do
      {:ok, ep} = endpoint(%{"combinations" => [["rank"], ["rank", "map_code"]]})
      assert {:ok, _} = compile(ep, %{"rank" => "GOLD"})
      assert {:ok, _} = compile(ep, %{"rank" => "GOLD", "map_code" => "de_dust2"})
    end

    test "a request whose param set is not a declared combination is 422" do
      {:ok, ep} = endpoint(%{"combinations" => [["rank", "map_code"]]})

      assert {:error, %ApiError{family: :invalid_param}} = compile(ep, %{"rank" => "GOLD"})
      assert {:error, %ApiError{family: :invalid_param}} = compile(ep, %{})
    end

    test "the match is on CLIENT-SENT params, before defaults are merged" do
      # `rank` has a default, but the client did not send it — so ["rank"] must NOT match.
      {:ok, ep} = endpoint(%{"combinations" => [["rank"]]})
      assert {:error, %ApiError{}} = compile(ep, %{})
      assert {:ok, _} = compile(ep, %{"rank" => "GOLD"})
    end

    test "reserved params (limit/offset/columns) don't count toward the combination" do
      {:ok, ep} = endpoint(%{"combinations" => [["rank"]]})

      assert {:ok, _} =
               compile(ep, %{"rank" => "GOLD", "limit" => "5", "columns" => "rank,games"})
    end

    test "no combinations declared keeps today's any-subset behaviour" do
      {:ok, ep} = endpoint(%{})
      assert {:ok, _} = compile(ep, %{})
      assert {:ok, _} = compile(ep, %{"rank" => "GOLD"})
    end

    test "a combination naming an undeclared param is rejected at load" do
      assert {:error, errors} = endpoint(%{"combinations" => [["nope"]]})
      assert Enum.any?(errors, &(&1.code == :unknown_param))
    end
  end

  describe "param aliases" do
    defp aliased_endpoint(param_extra) do
      endpoint(%{
        "params" => [
          Map.merge(
            %{"name" => "rank", "type" => "string", "required" => false},
            param_extra
          ),
          %{"name" => "map_code", "type" => "string", "required" => false}
        ]
      })
    end

    test "a client value maps through the alias to the stored value" do
      {:ok, ep} = aliased_endpoint(%{"aliases" => %{"25" => "1-25", "50" => "26-50"}})
      {:ok, plan} = compile(ep, %{"rank" => "25"})
      assert hd(plan.params) == "1-25"
    end

    test "an unknown value passes through unchanged (upstream behaviour)" do
      {:ok, ep} = aliased_endpoint(%{"aliases" => %{"25" => "1-25"}})
      {:ok, plan} = compile(ep, %{"rank" => "whatever"})
      assert hd(plan.params) == "whatever"
    end

    test "a trailing space (Plug's +-decoding) is restored to + before alias lookup" do
      {:ok, ep} = aliased_endpoint(%{"aliases" => %{"EMERALD+" => "emerald_plus"}})
      {:ok, plan} = compile(ep, %{"rank" => "EMERALD "})
      assert hd(plan.params) == "emerald_plus"
    end

    test "an aliased enum value must land inside the enum, and + restore applies" do
      {:ok, ep} =
        aliased_endpoint(%{
          "type" => "enum",
          "enum" => ["gold", "13+"],
          "aliases" => %{"GOLD" => "gold"}
        })

      assert {:ok, plan} = compile(ep, %{"rank" => "GOLD"})
      assert hd(plan.params) == "gold"

      # "13+" arrives as "13 " via Plug; membership retry restores it
      assert {:ok, plan2} = compile(ep, %{"rank" => "13 "})
      assert hd(plan2.params) == "13+"

      assert {:error, %ApiError{family: :invalid_param}} = compile(ep, %{"rank" => "iron"})
    end

    test "an alias targeting a value outside the enum is rejected at load" do
      assert {:error, errors} =
               aliased_endpoint(%{
                 "type" => "enum",
                 "enum" => ["gold"],
                 "aliases" => %{"X" => "not_in_enum"}
               })

      assert Enum.any?(errors, &(&1.code == :invalid_value))
    end

    test "aliases on an integer param are rejected at load" do
      assert {:error, errors} =
               endpoint(%{
                 "params" => [
                   %{
                     "name" => "rank",
                     "type" => "integer",
                     "required" => false,
                     "aliases" => %{"a" => "b"}
                   },
                   %{"name" => "map_code", "type" => "string", "required" => false}
                 ]
               })

      assert Enum.any?(errors, &(&1.code == :invalid_value))
    end
  end

  describe "?columns= projection subset" do
    test "narrows the projection, response columns, and json flags" do
      {:ok, ep} = endpoint(%{})
      {:ok, plan} = compile(ep, %{"columns" => "games,data"})

      assert plan.columns == ["games", "data"]
      assert plan.json_columns == ["data"]
      refute plan.sql =~ ~s|"rank" AS "rank"|
      assert plan.sql =~ ~s|to_json("data")|
    end

    test "a column outside the allowlist is 422" do
      {:ok, ep} = endpoint(%{})

      assert {:error, %ApiError{family: :invalid_param}} =
               compile(ep, %{"columns" => "games,secret"})
    end

    test "an empty or malformed columns value is 422" do
      {:ok, ep} = endpoint(%{})
      assert {:error, %ApiError{}} = compile(ep, %{"columns" => ""})
      assert {:error, %ApiError{}} = compile(ep, %{"columns" => "games,,rank"})
    end

    test "ordering keeps working when the ordered column is excluded" do
      {:ok, ep} = endpoint(%{})
      {:ok, plan} = compile(ep, %{"columns" => "rank"})

      # `games` (the order column) is not projected; ORDER BY falls back to the
      # underlying expression instead of the missing output alias.
      assert plan.columns == ["rank"]
      assert plan.sql =~ ~s|ORDER BY "games" DESC|
    end

    test "omitting columns keeps the full projection" do
      {:ok, ep} = endpoint(%{})
      {:ok, plan} = compile(ep, %{})
      assert plan.columns == ["rank", "games", "data"]
    end
  end
end
