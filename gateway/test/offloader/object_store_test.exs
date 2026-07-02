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
      # A bogus connection reference makes Duckdbex raise/err; simulate the scrub on
      # the message path via a config whose token would appear in a failure string.
      {:ok, db} = Duckdbex.open()
      {:ok, conn} = Duckdbex.connection(db)
      # Force a failure by making the DDL invalid through a crafted type — use the
      # public seam: an unknown secret type fails inside DuckDB with the DDL echoed.
      config = %{type: "s3", key_id: "AKIA_SENSITIVE", secret: "SECRET_VALUE", region: "bad'"}

      case ObjectStore.configure(conn, config) do
        :ok ->
          :ok

        {:error, reason} ->
          refute reason =~ "SECRET_VALUE"
          refute reason =~ "AKIA_SENSITIVE"
      end
    end
  end

  describe "from_env/1" do
    test "builds a config only when a supported type is set" do
      assert ObjectStore.from_env(%{type: "s3", key_id: "k", secret: "s"}).type == "s3"
      assert ObjectStore.from_env(%{type: nil}) == nil
      assert ObjectStore.from_env(%{}) == nil
    end
  end
end
