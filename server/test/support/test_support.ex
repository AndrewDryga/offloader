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

  @doc """
  `File.rm_rf!/1` for test cleanup. A stopped engine's DuckDB database closes when the dead
  process's references are freed, after `GenServer.stop/1` has returned, and the close can
  write into its directory while it is being removed. Retry briefly instead of failing a test
  whose assertions passed; raise the same error if the directory never goes away.
  """
  def rm_rf!(path, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      {:error, reason, file} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          rm_rf!(path, deadline)
        else
          raise File.Error,
            reason: reason,
            action: "remove files and directories recursively from",
            path: file
        end
    end
  end
end
