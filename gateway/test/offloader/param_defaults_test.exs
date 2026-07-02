defmodule Offloader.ParamDefaultsTest do
  # A declared param `default` is validated at config load and, when the param is
  # omitted from a request, bound as the filter value (upstream semantics: omitting
  # `rank` means `rank = 'ALL'`, not "unfiltered").
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
            %{"name" => "games", "type" => "BIGINT"},
            %{"name" => "day", "type" => "DATE"}
          ]
        },
        "datasets/stats.yml"
      )

    ds
  end

  defp endpoint(params, filters) do
    Endpoint.parse(
      %{
        "name" => "stats",
        "version" => 1,
        "owner" => "team@example.com",
        "dataset" => "stats",
        "params" => params,
        "query" => %{
          "select" => [
            %{"as" => "rank", "column" => "rank"},
            %{"as" => "games", "column" => "games"}
          ],
          "filters" => filters
        },
        "columns" => ["rank", "games"]
      },
      "endpoints/stats.yml",
      dataset()
    )
  end

  defp rank_endpoint(param_overrides) do
    endpoint(
      [
        Map.merge(
          %{"name" => "rank", "type" => "string", "required" => false},
          param_overrides
        )
      ],
      [%{"column" => "rank", "op" => "eq", "param" => "rank"}]
    )
  end

  describe "compiler applies defaults" do
    test "an omitted optional param with a default still filters, bound to the default" do
      {:ok, ep} = rank_endpoint(%{"default" => "ALL"})
      {:ok, plan} = Compiler.compile(ep, %{}, nil, {:table, "stats"})

      assert plan.sql =~ ~s|CAST("rank" AS VARCHAR) = $1|
      assert hd(plan.params) == "ALL"
    end

    test "an explicit value overrides the default" do
      {:ok, ep} = rank_endpoint(%{"default" => "ALL"})
      {:ok, plan} = Compiler.compile(ep, %{"rank" => "GOLD"}, nil, {:table, "stats"})

      assert hd(plan.params) == "GOLD"
    end

    test "an omitted optional param with NO default drops the filter (unchanged behaviour)" do
      {:ok, ep} = rank_endpoint(%{})
      {:ok, plan} = Compiler.compile(ep, %{}, nil, {:table, "stats"})

      refute plan.sql =~ "WHERE"
    end

    test "a required param is still required even with a default-looking config" do
      {:ok, ep} = rank_endpoint(%{"required" => true})

      assert {:error, %ApiError{family: :invalid_param}} =
               Compiler.compile(ep, %{}, nil, {:table, "stats"})
    end

    test "an integer default is bound as an integer" do
      {:ok, ep} =
        endpoint(
          [%{"name" => "games", "type" => "integer", "required" => false, "default" => "10"}],
          [%{"column" => "games", "op" => "gte", "param" => "games"}]
        )

      {:ok, plan} = Compiler.compile(ep, %{}, nil, {:table, "stats"})
      assert hd(plan.params) == 10
    end
  end

  describe "defaults are validated at config load" do
    test "an enum default outside the enum is rejected" do
      assert {:error, errors} =
               rank_endpoint(%{"type" => "enum", "enum" => ["ALL", "GOLD"], "default" => "IRON"})

      assert Enum.any?(errors, &(&1.code == :invalid_default))
    end

    test "a non-ISO date default is rejected" do
      assert {:error, errors} =
               endpoint(
                 [%{"name" => "day", "type" => "date", "required" => false, "default" => "junk"}],
                 [%{"column" => "day", "op" => "gte", "param" => "day"}]
               )

      assert Enum.any?(errors, &(&1.code == :invalid_default))
    end

    test "a non-numeric integer default is rejected, and one over max is rejected" do
      for default <- ["abc", 999] do
        assert {:error, errors} =
                 endpoint(
                   [
                     %{
                       "name" => "games",
                       "type" => "integer",
                       "required" => false,
                       "max" => 100,
                       "default" => default
                     }
                   ],
                   [%{"column" => "games", "op" => "lte", "param" => "games"}]
                 )

        assert Enum.any?(errors, &(&1.code == :invalid_default)), "expected reject: #{default}"
      end
    end

    test "a valid string default passes" do
      assert {:ok, _} = rank_endpoint(%{"default" => "ALL"})
    end
  end
end
