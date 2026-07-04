defmodule Offloader.CredentialRedactionTest do
  # The credentials-never-in-logs promise on the ONE path prior redaction missed: a
  # GenServer's crash-report state. format_status/1 must scrub secrets before OTP logs
  # the state on an abnormal exit.
  use ExUnit.Case, async: true

  alias Offloader.Engine
  alias Offloader.Gcs.TokenCache

  test "TokenCache.format_status redacts the bearer token" do
    status = %{state: %{fetcher: fn -> :x end, token: "ya29.SUPER_SECRET", expires_at: 999}}
    assert %{state: %{token: "[redacted]"}} = TokenCache.format_status(status)
  end

  test "TokenCache.format_status leaves an empty token alone" do
    status = %{state: %{fetcher: fn -> :x end, token: nil, expires_at: 0}}
    assert %{state: %{token: nil}} = TokenCache.format_status(status)
  end

  test "Engine.format_status redacts object-store credentials in the state" do
    os = %{type: "gcs", key_id: "GOOGABC", secret: "s3cr3t", session_token: "tok", region: "us"}
    status = %{state: %Engine{pool: %{table: :t, size: 1, object_store: os}}}

    assert %{state: %Engine{pool: %{object_store: red}}} = Engine.format_status(status)
    assert red.secret == "[redacted]"
    assert red.session_token == "[redacted]"
    assert red.key_id == "[redacted]"
    # non-secret fields survive
    assert red.type == "gcs"
    assert red.region == "us"
  end

  test "Engine.format_status is a no-op when there are no object-store credentials" do
    status = %{state: %Engine{pool: %{table: :t, size: 1, object_store: nil}}}
    assert %{state: %Engine{pool: %{object_store: nil}}} = Engine.format_status(status)
  end
end
