defmodule Offloader.GcsTest do
  # Token chain + cache + the real GCS client, exercised against a local Bandit stub
  # (no network, no credentials). async: false — swaps global app env (metadata URL,
  # base URL, gcs_token, token-cache seam).
  use ExUnit.Case, async: false

  alias Offloader.Gcs.{Client, Token, TokenCache}

  defmodule FakeGcsPlug do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      handle(conn.path_info, conn)
    end

    # metadata server token endpoint
    defp handle(["token"], conn) do
      send_json(conn, 200, %{access_token: "meta-token", expires_in: 600, token_type: "Bearer"})
    end

    # GCS JSON API: list objects (two pages via pageToken)
    defp handle(["storage", "v1", "b", _bucket, "o"], conn) do
      case auth(conn) do
        "Bearer expired" ->
          send_json(conn, 401, %{error: "unauthorized"})

        "Bearer " <> _ ->
          case conn.query_params["pageToken"] do
            nil ->
              send_json(conn, 200, %{
                items: [%{name: "a/_committed_1", updated: "2026-07-01T00:00:00Z"}],
                nextPageToken: "page2"
              })

            "page2" ->
              send_json(conn, 200, %{
                items: [%{name: "a/_committed_2", updated: "2026-07-02T00:00:00Z"}]
              })
          end

        _ ->
          send_json(conn, 401, %{error: "no token"})
      end
    end

    # GCS JSON API: object media download (the name segment arrives URL-decoded)
    defp handle(["storage", "v1", "b", _bucket, "o", name], conn) do
      case auth(conn) do
        "Bearer " <> _ -> send_resp(conn, 200, "media-of:" <> name)
        _ -> send_json(conn, 401, %{error: "no token"})
      end
    end

    defp handle(_other, conn), do: send_resp(conn, 404, "not found")

    defp auth(conn), do: conn |> get_req_header("authorization") |> List.first()

    defp send_json(conn, status, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end
  end

  setup_all do
    # Fixed loopback port for the stub; retry a few in case one is taken.
    {port, _server} =
      Enum.find_value(47_631..47_640, fn port ->
        case Bandit.start_link(plug: FakeGcsPlug, port: port, ip: :loopback) do
          {:ok, pid} -> {port, pid}
          {:error, _} -> nil
        end
      end)

    %{base: "http://127.0.0.1:#{port}"}
  end

  defp with_env(key, value, fun) do
    prev = Application.get_env(:offloader, key)
    put_or_delete(key, value)

    try do
      fun.()
    after
      put_or_delete(key, prev)
    end
  end

  # put_env(key, nil) STORES nil (shadowing defaults); restore by deleting instead.
  defp put_or_delete(key, nil), do: Application.delete_env(:offloader, key)
  defp put_or_delete(key, value), do: Application.put_env(:offloader, key, value)

  # Start a private TokenCache with a controlled fetcher and point the Client at it.
  defp with_token_cache(fetcher, fun) do
    {:ok, cache} = TokenCache.start_link(name: nil, fetcher: fetcher)

    try do
      with_env(:gcs_token_cache, cache, fn -> fun.(cache) end)
    after
      GenServer.stop(cache)
    end
  end

  defp constant_token(token), do: fn -> {:ok, token, 3600} end

  describe "Token.fetch/0 chain" do
    test "an explicit env token wins and reports no lifetime" do
      with_env(:gcs_token, "env-token", fn ->
        assert {:ok, "env-token", nil} = Token.fetch()
      end)
    end

    test "falls through to the metadata server", %{base: base} do
      with_env(:gcs_token, nil, fn ->
        with_env(:gcs_metadata_token_url, base <> "/token", fn ->
          assert {:ok, "meta-token", 600} = Token.fetch()
        end)
      end)
    end
  end

  describe "TokenCache" do
    test "caches until expiry and serializes fetches" do
      parent = self()

      fetcher = fn ->
        send(parent, :fetched)
        {:ok, "tok-#{System.unique_integer([:positive])}", 3600}
      end

      {:ok, cache} = TokenCache.start_link(name: nil, fetcher: fetcher)

      {:ok, t1} = TokenCache.get(cache)
      {:ok, t2} = TokenCache.get(cache)
      assert t1 == t2
      assert_receive :fetched
      refute_receive :fetched, 50
      GenServer.stop(cache)
    end

    test "refresh forces a new token" do
      fetcher = fn -> {:ok, "tok-#{System.unique_integer([:positive])}", 3600} end
      {:ok, cache} = TokenCache.start_link(name: nil, fetcher: fetcher)

      {:ok, t1} = TokenCache.get(cache)
      {:ok, t2} = TokenCache.refresh(cache)
      refute t1 == t2
      GenServer.stop(cache)
    end

    test "a failed fetch surfaces the error and stays uncached" do
      {:ok, cache} = TokenCache.start_link(name: nil, fetcher: fn -> {:error, [:nope]} end)
      assert {:error, [:nope]} = TokenCache.get(cache)
      GenServer.stop(cache)
    end

    test "refresh_after_ms tracks the token TTL (floor 60s, cap 15m)" do
      # no token yet → the 60s floor
      {:ok, cache} = TokenCache.start_link(name: nil, fetcher: fn -> {:error, [:x]} end)
      assert TokenCache.refresh_after_ms(cache) == 60_000
      GenServer.stop(cache)

      # a 3600s token → (3600 - 300 buffer) capped at the 15-min ceiling
      {:ok, c2} = TokenCache.start_link(name: nil, fetcher: fn -> {:ok, "t", 3600} end)
      {:ok, _} = TokenCache.get(c2)
      assert TokenCache.refresh_after_ms(c2) == 900_000
      GenServer.stop(c2)

      # a 400s token → ~100s (400 - 300 buffer), above the floor, below the cap
      {:ok, c3} = TokenCache.start_link(name: nil, fetcher: fn -> {:ok, "t", 400} end)
      {:ok, _} = TokenCache.get(c3)
      assert TokenCache.refresh_after_ms(c3) in 95_000..105_000
      GenServer.stop(c3)
    end
  end

  describe "Client against the stub API" do
    setup %{base: base} do
      prev = Application.get_env(:offloader, :gcs_base_url)
      Application.put_env(:offloader, :gcs_base_url, base)
      on_exit(fn -> put_or_delete(:gcs_base_url, prev) end)
      :ok
    end

    test "list_objects paginates through nextPageToken" do
      with_token_cache(constant_token("good-token"), fn _cache ->
        assert {:ok, items} = Client.list_objects("bucket", "a/_committed_")
        assert Enum.map(items, & &1["name"]) == ["a/_committed_1", "a/_committed_2"]
      end)
    end

    test "get_object downloads media, URL-encoding the object name (GCS API form)" do
      with_token_cache(constant_token("good-token"), fn _cache ->
        # the stub sees the raw path segment — the slash must arrive encoded (%2F)
        assert {:ok, "media-of:a%2F_committed_1"} = Client.get_object("bucket", "a/_committed_1")
      end)
    end

    test "a 401 forces one token refresh and retry" do
      # First token is "expired" (the stub 401s it); the forced refresh gets a good one.
      {:ok, agent} = Agent.start_link(fn -> ["expired", "good-token"] end)

      fetcher = fn ->
        Agent.get_and_update(agent, fn
          [tok] -> {{:ok, tok, 3600}, [tok]}
          [tok | rest] -> {{:ok, tok, 3600}, rest}
        end)
      end

      with_token_cache(fetcher, fn _cache ->
        assert {:ok, items} = Client.list_objects("bucket", "a/_committed_")
        assert length(items) == 2
      end)

      Agent.stop(agent)
    end

    test "a token-chain failure propagates instead of calling the API" do
      with_token_cache(fn -> {:error, [:no_source]} end, fn _cache ->
        assert {:error, [:no_source]} = Client.list_objects("bucket", "a/")
      end)
    end
  end

  describe "object_url/2" do
    test "HTTPS (bearer/public) by default, gs:// under HMAC" do
      with_env(:object_store, nil, fn ->
        assert Client.object_url("b", "p/x.parquet") =~
                 "https://storage.googleapis.com/b/p/x.parquet"
      end)

      with_env(:object_store, %{type: "gcs", key_id: "k", secret: "s"}, fn ->
        assert Client.object_url("b", "p/x.parquet") == "gs://b/p/x.parquet"
      end)
    end
  end
end
