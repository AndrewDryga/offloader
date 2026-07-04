defmodule Offloader.RuntimeNotReadyTest do
  # Before a runtime is published (or when the named server is dead), every read must answer
  # the documented "not ready" contract — endpoints 503, state reads nil/false — and never
  # crash. Existing Runtime tests always start a live runtime, so this branch is otherwise
  # unexercised. async: false because it also calls the default-arity heads (server defaults
  # to Offloader.Runtime, which no test registers).
  use ExUnit.Case, async: false

  alias Offloader.{ApiError, Runtime}

  # An atom no test ever registers → GenServer.whereis/1 is nil → the runtime has no context.
  @dead :offloader_runtime_absent

  test "authorize and serve answer :not_ready before a runtime exists" do
    assert {:error, %ApiError{family: :not_ready}} = Runtime.authorize(@dead, "tok", "ep")
    assert {:error, %ApiError{family: :not_ready}} = Runtime.serve(@dead, "ep", "t", %{}, "rid")
    # default-arity heads (server defaults to Offloader.Runtime, unregistered under test)
    assert {:error, %ApiError{family: :not_ready}} = Runtime.authorize("tok", "ep")
    assert {:error, %ApiError{family: :not_ready}} = Runtime.serve("ep", "t", %{}, "rid")
  end

  test "snapshot and catalog reads return nil before a runtime exists" do
    assert Runtime.snapshot_state(@dead, "ds") == nil
    assert Runtime.snapshot_active(@dead, "ds") == nil
    assert Runtime.catalog(@dead) == nil
    assert Runtime.catalog() == nil
  end

  test "readiness and public flags are false before a runtime exists" do
    refute Runtime.ready?(@dead)
    refute Runtime.public?(@dead)
    refute Runtime.ready?()
    refute Runtime.public?()
  end

  test "diagnostics before boot reports not-ready with the build version and no datasets" do
    diag = Runtime.diagnostics(@dead)
    assert diag.ready == false
    assert diag.datasets == []
    assert diag.build_version == Offloader.version()
    assert Runtime.diagnostics().ready == false
  end
end
