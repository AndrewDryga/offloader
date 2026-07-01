defmodule Offloader.AuthTest do
  use ExUnit.Case, async: true

  alias Offloader.{ApiError, Auth}
  alias Offloader.Catalog.Key

  defp key(attrs) do
    base = %Key{
      id: "k",
      hash: hash("secret"),
      tenant: "tenant_a",
      endpoints: ["ep_a"],
      status: "active"
    }

    struct(base, attrs)
  end

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  describe "authenticate/2" do
    test "returns the active key whose token hashes to a stored hash" do
      keys = [key(id: "k1", hash: hash("t1")), key(id: "k2", hash: hash("t2"))]
      assert {:ok, %Key{id: "k2"}} = Auth.authenticate(keys, "t2")
    end

    test "an unknown token is unauthorized" do
      assert {:error, %ApiError{family: :unauthorized}} = Auth.authenticate([key([])], "wrong")
    end

    test "a revoked key never matches, even with the right token" do
      keys = [key(hash: hash("t"), status: "revoked")]
      assert {:error, %ApiError{family: :unauthorized}} = Auth.authenticate(keys, "t")
    end

    test "a non-string token is unauthorized, not a crash" do
      assert {:error, %ApiError{family: :unauthorized}} = Auth.authenticate([key([])], nil)
    end
  end

  describe "authorize/2" do
    test "grants an endpoint in the key's allowlist and returns the bound tenant" do
      assert {:ok, "tenant_a"} = Auth.authorize(key(endpoints: ["ep_a", "ep_b"]), "ep_a")
    end

    test "an endpoint outside the allowlist is not_found (no existence leak)" do
      assert {:error, %ApiError{family: :not_found}} =
               Auth.authorize(key(endpoints: ["ep_a"]), "ep_secret")
    end
  end
end
