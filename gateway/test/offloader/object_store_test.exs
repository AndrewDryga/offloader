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
  end

  describe "configure/2" do
    test "is a no-op in local mode (nil config)" do
      assert ObjectStore.configure(:ignored, nil) == :ok
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
