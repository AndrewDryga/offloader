defmodule Offloader.S3.ClientTest do
  # The S3 config source against a local Bandit stub (path-style via :s3_base_url) — no network,
  # no AWS. async: false: it swaps global app-env (base url, object_store, clock).
  use ExUnit.Case, async: false

  alias Offloader.S3.Client

  defmodule FakeS3 do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      # Record the Authorization header so a test can prove the request was SigV4-signed.
      Agent.update(FakeS3.Auth, fn _ ->
        conn |> get_req_header("authorization") |> List.first()
      end)

      if conn.query_params["list-type"] == "2" do
        xml =
          "<ListBucketResult><Contents><Key>offloader/offloader.yml</Key>" <>
            "<Size>12</Size><LastModified>2026-07-01T00:00:00.000Z</LastModified></Contents>" <>
            "</ListBucketResult>"

        send_resp(conn, 200, xml)
      else
        send_resp(conn, 200, "body-of:" <> conn.request_path)
      end
    end
  end

  setup_all do
    {:ok, _} = Agent.start_link(fn -> nil end, name: FakeS3.Auth)

    {port, _server} =
      Enum.find_value(48_631..48_650, fn port ->
        case Bandit.start_link(plug: FakeS3, port: port, ip: :loopback) do
          {:ok, pid} -> {port, pid}
          {:error, _} -> nil
        end
      end)

    %{base: "http://127.0.0.1:#{port}"}
  end

  defp with_env(kvs, fun) do
    prev = Map.new(kvs, fn {k, _} -> {k, Application.get_env(:offloader, k)} end)
    Enum.each(kvs, fn {k, v} -> Application.put_env(:offloader, k, v) end)

    try do
      fun.()
    after
      Enum.each(prev, fn {k, v} ->
        if is_nil(v),
          do: Application.delete_env(:offloader, k),
          else: Application.put_env(:offloader, k, v)
      end)
    end
  end

  test "SigV4-signs list + get with credentials and parses the list XML", %{base: base} do
    creds = %{type: "s3", key_id: "AKIAEXAMPLE", secret: "sekret", region: "us-east-1"}

    with_env([s3_base_url: base, object_store: creds], fn ->
      assert {:ok, [%{"name" => "offloader/offloader.yml", "size" => "12"}]} =
               Client.list_objects("my-bucket", "offloader/")

      # A well-formed SigV4 Authorization header was sent (scope + 64-hex signature).
      auth = Agent.get(FakeS3.Auth, & &1)
      assert auth =~ ~r"^AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/\d{8}/us-east-1/s3/aws4_request,"
      assert auth =~ ~r"Signature=[0-9a-f]{64}$"

      assert {:ok, "body-of:/my-bucket/offloader/offloader.yml"} =
               Client.get_object("my-bucket", "offloader/offloader.yml")
    end)
  end

  test "goes out anonymous (no Authorization header) when no credentials are set", %{base: base} do
    with_env([s3_base_url: base, object_store: nil], fn ->
      assert {:ok, [%{"name" => "offloader/offloader.yml"}]} =
               Client.list_objects("my-bucket", "")

      assert Agent.get(FakeS3.Auth, & &1) == nil
    end)
  end
end
