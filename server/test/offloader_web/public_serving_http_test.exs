defmodule OffloaderWeb.PublicServingHTTPTest do
  # A project with `auth: none` + a non-tenant dataset + a nested JSON column serves
  # over HTTP with no bearer token and returns nested objects — the shape of a public
  # upstream data API. async: false (Runtime is a singleton + DuckDB).
  use ExUnit.Case, async: false
  import Phoenix.ConnTest

  alias Offloader.Runtime

  @endpoint OffloaderWeb.ApiEndpoint
  @project Path.expand("../../../examples/public-metrics/offloader.yml", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "offl_pub_#{System.unique_integer([:positive])}")
    {:ok, rt} = Runtime.start_link(name: Runtime, config_path: @project, cache_dir: dir)

    on_exit(fn ->
      if Process.alive?(rt), do: GenServer.stop(rt)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp get_champion(id) do
    get(build_conn(), "/v1/endpoints/champion?" <> URI.encode_query(%{"champion_id" => id}))
  end

  test "serves with no Authorization header (public), returning the row" do
    body = json_response(get_champion("1"), 200)
    assert [row] = body["data"]
    assert row["champion_id"] == "1"
    assert row["patch"] == "16.13"
    # no tenant anywhere in the response envelope
    refute Map.has_key?(body["meta"], "tenant")
  end

  test "the JSON column comes back as a nested object, not a string" do
    body = json_response(get_champion("1"), 200)
    data = hd(body["data"])["data"]

    assert is_map(data)
    assert data["num_games"] == 136_068
    assert data["win_rate"] == 0.497
    assert data["tier"] == 3
    # a MAP nested inside the struct decodes to a nested object too
    assert data["by_lane"] == %{"mid" => 0.51, "top" => 0.47}
  end

  test "an unknown champion returns 200 with an empty result (no error/leak)" do
    body = json_response(get_champion("does_not_exist"), 200)
    assert body["data"] == []
  end

  test "a stray bearer token is simply ignored in public mode" do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer whatever")
      |> get("/v1/endpoints/champion?champion_id=11")

    assert json_response(conn, 200)["data"] |> hd() |> Map.get("champion_id") == "11"
  end

  test "?columns= narrows the response to the requested subset (real DuckDB)" do
    conn = get(build_conn(), "/v1/endpoints/champion?champion_id=1&columns=champion_id,data")
    [row] = json_response(conn, 200)["data"]

    assert Map.keys(row) |> Enum.sort() == ["champion_id", "data"]
    # the nested column still decodes when selected through the subset
    assert is_map(row["data"])
    # ordering still works even though `patch` (nothing ordered here) is excluded
    assert row["champion_id"] == "1"
  end

  test "?columns= outside the allowlist is 422" do
    conn = get(build_conn(), "/v1/endpoints/champion?champion_id=1&columns=champion_id,secret")
    assert json_response(conn, 422)["error"]["family"] == "invalid_param"
  end

  test "?columns= excluding the ORDER BY column still executes (expression fallback)" do
    # champion is ordered by champion_id; requesting only `data` drops that output
    # column, so the ORDER BY must fall back to the underlying column expression.
    conn = get(build_conn(), "/v1/endpoints/champion?champion_id=11&columns=data")
    [row] = json_response(conn, 200)["data"]
    assert Map.keys(row) == ["data"]
    assert row["data"]["num_games"] == 98_213
  end
end
