defmodule Offloader.ObjectStoreTest do
  use ExUnit.Case, async: true

  alias Offloader.ObjectStore

  describe "remote_path?/1" do
    test "recognizes remote schemes DuckDB reads over the network" do
      assert ObjectStore.remote_path?("s3://bucket/a.parquet")
      assert ObjectStore.remote_path?("gs://bucket/a.parquet")
      assert ObjectStore.remote_path?("https://host/a.parquet")
    end

    test "treats local paths and junk as not-remote" do
      refute ObjectStore.remote_path?("/data/a.parquet")
      refute ObjectStore.remote_path?("data/a.parquet")
      refute ObjectStore.remote_path?(nil)
    end
  end

  describe "secret_ddl/1" do
    test "S3 renders the full field set and drops empty fields" do
      ddl =
        ObjectStore.secret_ddl(%{
          type: "s3",
          key_id: "AKIA",
          secret: "shh",
          region: "us-east-1",
          endpoint: "s3.example.com",
          url_style: "path",
          use_ssl: true,
          session_token: nil
        })

      assert ddl =~ "CREATE OR REPLACE SECRET offloader_store"
      assert ddl =~ "TYPE S3"
      assert ddl =~ "KEY_ID 'AKIA'"
      assert ddl =~ "SECRET 'shh'"
      assert ddl =~ "REGION 'us-east-1'"
      assert ddl =~ "ENDPOINT 's3.example.com'"
      assert ddl =~ "URL_STYLE 'path'"
      assert ddl =~ "USE_SSL true"
      # empty/nil fields are omitted, not rendered blank
      refute ddl =~ "SESSION_TOKEN"
    end

    test "S3 provider credential_chain uses the instance role — no static keys, bareword provider" do
      ddl =
        ObjectStore.secret_ddl(%{
          type: "s3",
          provider: "credential_chain",
          region: "us-east-1",
          key_id: "SHOULD_NOT_APPEAR",
          secret: "SHOULD_NOT_APPEAR"
        })

      assert ddl =~ "TYPE S3"
      assert ddl =~ "PROVIDER credential_chain"
      assert ddl =~ "REGION 'us-east-1'"
      # the point: no static credential FIELDS in the DDL (the SECRET keyword is fine), and
      # PROVIDER is a bareword not a quoted string
      refute ddl =~ "KEY_ID"
      refute ddl =~ "SECRET '"
      refute ddl =~ "SHOULD_NOT_APPEAR"
      refute ddl =~ "PROVIDER 'credential_chain'"
    end

    test "GCS renders only KEY_ID/SECRET under TYPE GCS" do
      ddl = ObjectStore.secret_ddl(%{type: "gcs", key_id: "GOOG", secret: "hmac"})
      assert ddl =~ "TYPE GCS"
      assert ddl =~ "KEY_ID 'GOOG'"
      assert ddl =~ "SECRET 'hmac'"
      refute ddl =~ "REGION"
    end

    test "single quotes in a credential are escaped, not injected" do
      ddl = ObjectStore.secret_ddl(%{type: "s3", key_id: "a'b", secret: "x"})
      assert ddl =~ "KEY_ID 'a''b'"
    end

    test "gcs_bearer renders an HTTP secret carrying the bearer token" do
      ddl = ObjectStore.secret_ddl(%{type: "gcs_bearer", token: "ya29.abc"})
      assert ddl =~ "TYPE HTTP"
      assert ddl =~ "BEARER_TOKEN 'ya29.abc'"
    end
  end

  describe "configure/2" do
    test "is a no-op in local mode (nil config)" do
      assert ObjectStore.configure(:ignored, nil) == :ok
    end

    test "applies a gcs_bearer secret to a live connection (no network needed)" do
      {:ok, db} = Duckdbex.open()
      {:ok, conn} = Duckdbex.connection(db)
      assert :ok = ObjectStore.configure(conn, %{type: "gcs_bearer", token: "test-token"})
      # re-apply (rotation path) is idempotent
      assert :ok = ObjectStore.configure(conn, %{type: "gcs_bearer", token: "rotated"})
    end

    test "an error never echoes the credential values" do
      {:ok, db} = Duckdbex.open()
      {:ok, conn} = Duckdbex.connection(db)
      config = %{type: "s3", key_id: "AKIA_SENSITIVE", secret: "SECRET_VALUE", region: "bad'"}

      case ObjectStore.configure(conn, config) do
        :ok -> :ok
        {:error, reason} -> refute reason =~ "SECRET_VALUE" or reason =~ "AKIA_SENSITIVE"
      end
    end
  end

  describe "redact/2 (credential scrubbing for object-store errors)" do
    test "redacts an S3 key_id/secret/session_token that appears in a message" do
      config = %{type: "s3", key_id: "AKIAXX", secret: "s3cr3t", session_token: "sess"}
      msg = "CREATE SECRET ... KEY_ID 'AKIAXX' SECRET 's3cr3t' SESSION_TOKEN 'sess' failed"
      out = ObjectStore.redact(msg, config)
      for leak <- ["AKIAXX", "s3cr3t", "sess"], do: refute(out =~ leak)
      assert out =~ "[redacted]"
    end

    test "redacts a resolved GCS bearer token (the production path the scrub protects)" do
      # This is the regression: bearer mode resolves the token into the map the DDL
      # embeds; redaction must run against THAT map, not the pre-resolution config.
      config = %{type: "gcs_bearer", token: "ya29.LIVE_ACCESS_TOKEN"}
      msg = "... BEARER_TOKEN 'ya29.LIVE_ACCESS_TOKEN' ... Connection Error"
      out = ObjectStore.redact(msg, config)
      refute out =~ "ya29.LIVE_ACCESS_TOKEN"
      assert out =~ "[redacted]"
    end

    test "a non-string reason (or one with no credentials) passes through" do
      assert ObjectStore.redact({:some, :atom}, %{type: "s3"}) == {:some, :atom}
      assert ObjectStore.redact("plain error", %{type: "gcs_bearer"}) == "plain error"
    end
  end

  describe "bearer boot resilience" do
    test "configure defers (returns :ok) when the GCS token source is down — no crash-loop" do
      # A token cache that always fails, injected via the same seam the client uses.
      {:ok, cache} =
        Offloader.Gcs.TokenCache.start_link(name: nil, fetcher: fn -> {:error, [:down]} end)

      prev = Application.get_env(:offloader, :gcs_token_cache)
      Application.put_env(:offloader, :gcs_token_cache, cache)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:offloader, :gcs_token_cache, prev),
          else: Application.delete_env(:offloader, :gcs_token_cache)

        if Process.alive?(cache), do: GenServer.stop(cache)
      end)

      {:ok, db} = Duckdbex.open()
      {:ok, conn} = Duckdbex.connection(db)

      # Deferred, NOT an error — so the engine boots instead of crash-looping.
      assert :ok = ObjectStore.configure(conn, %{type: "gcs_bearer"})
    end
  end
end
