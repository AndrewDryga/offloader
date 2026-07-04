defmodule Offloader.SqlTest do
  use ExUnit.Case, async: true

  alias Offloader.Sql

  describe "resolve_path/2" do
    test "expands a local path from the manifest dir" do
      assert Sql.resolve_path("data.parquet", "/snapshots/x") == "/snapshots/x/data.parquet"
    end

    test "passes a remote URL through verbatim (httpfs reads it directly)" do
      assert Sql.resolve_path("s3://bucket/a.parquet", "/ignored") == "s3://bucket/a.parquet"
      assert Sql.resolve_path("gs://bucket/a.parquet", "/ignored") == "gs://bucket/a.parquet"
      assert Sql.resolve_path("https://host/a.parquet", "/x") == "https://host/a.parquet"
    end
  end

  describe "read_files_expr/2" do
    test "uses read_parquet with the remote URL unmodified" do
      sql = Sql.read_files_expr([%{"path" => "s3://b/a.parquet", "format" => "parquet"}], "/dir")
      assert sql == "SELECT * FROM read_parquet('s3://b/a.parquet')"
    end

    test "expands and reads a local csv" do
      sql = Sql.read_files_expr([%{"path" => "f.csv", "format" => "csv"}], "/d")
      assert sql == "SELECT * FROM read_csv_auto('/d/f.csv')"
    end

    test "single-quotes in a path are escaped" do
      sql = Sql.read_files_expr([%{"path" => "s3://b/a'b.parquet", "format" => "parquet"}], "/d")
      assert sql =~ "read_parquet('s3://b/a''b.parquet')"
    end
  end
end
