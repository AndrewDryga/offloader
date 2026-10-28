defmodule Offloader.TestSupport do
  @moduledoc false

  @doc """
  Stops a process from an `on_exit` callback.

  `on_exit` runs after the test process has exited. A process the test started with
  `start_link` is linked to it, so it may already be shutting down when the callback
  runs, and stopping it then races that exit. A process that is already gone or exits
  with `:shutdown` counts as stopped; any other exit reason still fails the test.
  """
  def stop_if_alive(pid) do
    GenServer.stop(pid)
  catch
    # Already gone before the stop request.
    :exit, {:noproc, {GenServer, :stop, _}} ->
      :ok

    # Accepted the stop request, then exited with the link's :shutdown instead.
    :exit, {:shutdown, {GenServer, :stop, _}} ->
      :ok

    # Exited with :shutdown while the stop request was still being delivered.
    :exit, {{:shutdown, {:sys, :terminate, _}}, {GenServer, :stop, _}} ->
      :ok
  end
end
