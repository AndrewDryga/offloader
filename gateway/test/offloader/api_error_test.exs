defmodule Offloader.ApiErrorTest do
  use ExUnit.Case, async: true

  alias Offloader.ApiError

  @families [:invalid_param, :unauthorized, :not_found, :not_ready, :internal]
  @statuses %{
    invalid_param: 422,
    unauthorized: 401,
    not_found: 404,
    not_ready: 503,
    internal: 500
  }

  describe "new/2" do
    test "builds a struct for every known family, carrying the message verbatim" do
      for family <- @families do
        assert %ApiError{family: ^family, message: "boom"} = ApiError.new(family, "boom")
      end
    end

    test "rejects an unknown family (guarded by the status map)" do
      assert_raise FunctionClauseError, fn -> ApiError.new(:teapot, "x") end
    end
  end

  describe "status/1" do
    test "maps each family to its HTTP status — from a bare atom and from a struct" do
      for {family, status} <- @statuses do
        assert ApiError.status(family) == status
        assert ApiError.status(ApiError.new(family, "m")) == status
      end
    end
  end
end
