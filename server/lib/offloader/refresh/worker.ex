defmodule Offloader.Refresh.Worker do
  @moduledoc """
  One dataset's refresh loop, isolated in its own process: on every tick (and for a
  manual `Runtime.refresh/3`) it resolves the dataset's latest snapshot and runs the
  full `Offloader.Refresh` sequence HERE — so a slow or wedged source delays only
  this dataset, never its siblings or the serving path. The outcome is handed to the
  Runtime (`{:apply_refresh, ...}`), which stays the single writer of snapshot state.

  Intervals: `source.interval_seconds` > the runtime's `:refresh_interval_ms` >
  300s for source-datasets. A static dataset polls only when the runtime interval is
  set (boot + manual otherwise). Manual refreshes force re-materialization; polls
  skip when the snapshot id is unchanged.

  Workers register in `Offloader.Refresh.Registry` under `{runtime_pid, dataset_id}`
  so concurrently-running runtimes (tests) never collide.
  """

  use GenServer

  alias Offloader.Refresh

  @source_default_interval_ms :timer.seconds(300)

  def start_link(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    dataset = Keyword.fetch!(opts, :dataset)
    name = {:via, Registry, {Offloader.Refresh.Registry, {runtime, dataset.id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The worker for `dataset_id` under `runtime`, or nil."
  def whereis(runtime, dataset_id) do
    case Registry.lookup(Offloader.Refresh.Registry, {runtime, dataset_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Run a manual (forced) refresh now. `manifest_path` overrides a static path."
  def refresh(worker, manifest_path \\ nil),
    do: GenServer.call(worker, {:refresh, manifest_path}, 180_000)

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      runtime: Keyword.fetch!(opts, :runtime),
      dataset: Keyword.fetch!(opts, :dataset),
      engine: Keyword.fetch!(opts, :engine),
      config_dir: Keyword.fetch!(opts, :config_dir),
      interval_ms: interval_ms(Keyword.fetch!(opts, :dataset), opts[:refresh_interval_ms])
    }

    # The Runtime does the initial (boot) load synchronously; the worker owns only the
    # ongoing poll loop, scheduled at the dataset's interval.
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:refresh, manifest_path}, _from, state) do
    how =
      case {manifest_path, state.dataset.source} do
        {path, _} when is_binary(path) -> {:static, path}
        {nil, nil} -> {:static, default_manifest_path(state)}
        {nil, source} -> {:source, source}
      end

    outcome = run(state, how, force: true)

    reply =
      case outcome do
        {:swapped, snap, _attempt} -> {:ok, snap.snapshot_id}
        {:unchanged, attempt} -> {:ok, attempt.snapshot_id}
        {status, _attempt} -> {:error, status}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    _outcome = run(state, poll_how(state), force: false)
    schedule(state)
    {:noreply, state}
  end

  # An out-of-band kick from the Runtime (a hot-added or re-pointed dataset): refresh once
  # now, but do NOT arm a timer — the init-scheduled poll stays the sole cadence. Sending a
  # plain `:poll` here would spawn a second self-perpetuating timer chain, so the dataset
  # would poll at 2× its configured interval forever.
  @impl true
  def handle_info(:refresh_now, state) do
    _outcome = run(state, poll_how(state), force: false)
    {:noreply, state}
  end

  # ── internals ─────────────────────────────────────────────────────────────────

  defp poll_how(state) do
    case state.dataset.source do
      nil -> {:static, default_manifest_path(state)}
      source -> {:source, source}
    end
  end

  # Perform the refresh HERE (slow), then let the Runtime apply the bookkeeping
  # (fast). The synchronous apply means a manual caller reads its own write.
  defp run(state, how, opts) do
    entry = Offloader.Runtime.snapshot_state(state.runtime, state.dataset.id) || %{}
    opts = Keyword.put_new(opts, :quarantined, Map.get(entry, :quarantined))
    outcome = Refresh.perform(state.engine, state.dataset, Map.get(entry, :active), how, opts)
    :ok = GenServer.call(state.runtime, {:apply_refresh, state.dataset.id, outcome}, 30_000)
    outcome
  end

  defp default_manifest_path(state),
    do: Path.join(state.config_dir, state.dataset.manifest)

  defp interval_ms(dataset, runtime_interval_ms) do
    cond do
      dataset.source && dataset.source.interval_seconds ->
        :timer.seconds(dataset.source.interval_seconds)

      is_integer(runtime_interval_ms) and runtime_interval_ms > 0 ->
        runtime_interval_ms

      dataset.source ->
        @source_default_interval_ms

      true ->
        nil
    end
  end

  defp schedule(%{interval_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :poll, ms)

  defp schedule(_state), do: :ok
end
