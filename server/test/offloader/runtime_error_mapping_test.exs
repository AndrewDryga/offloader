defmodule Offloader.RuntimeErrorMappingTest do
  # A saturated read pool is transient backpressure, not a bug: it must surface as a
  # retryable 503 (docs/public-serving.md, docs/operator.md), while every other engine
  # fault stays a 500. This pins that mapping so the docs can't drift from the code.
  use ExUnit.Case, async: true

  alias Offloader.{ApiError, Runtime}
  alias Offloader.Engine.Error, as: EngineError

  test "pool saturation maps to a retryable 503" do
    err =
      Runtime.engine_fault(%EngineError{
        reason: :pool_busy,
        message: "all read connections are busy"
      })

    assert %ApiError{family: :not_ready} = err
    assert ApiError.status(err) == 503
  end

  test "any other engine fault maps to a 500 the operator should investigate" do
    for reason <- [:query_failed, :engine_unavailable, :timeout, :settings_failed] do
      err = Runtime.engine_fault(%EngineError{reason: reason, message: "x"})
      assert %ApiError{family: :internal} = err, "#{reason} should be internal/500"
      assert ApiError.status(err) == 500
    end
  end
end
