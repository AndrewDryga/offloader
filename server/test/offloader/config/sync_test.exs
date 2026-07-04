defmodule Offloader.Config.SyncTest do
  # Config auto-sync loop: baseline the digest, and on each tick reload only when it changed —
  # keeping the running config on any error, and skipping while the Runtime is down.
  # async: false — the stub loader is a named Agent.
  use ExUnit.Case, async: false

  alias Offloader.Catalog
  alias Offloader.Config.Sync

  @example Path.expand("../../../../examples/customer-analytics/offloader.yml", __DIR__)

  defp catalog do
    {:ok, c} = Catalog.load(@example)
    c
  end

  # A loader driven by a named Agent so a test can change the digest/load result after init.
  defmodule StubLoader do
    def start(opts), do: Agent.start_link(fn -> Map.new(opts) end, name: __MODULE__)
    def set(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
    def digest(_path), do: Agent.get(__MODULE__, &Map.get(&1, :digest))
    def load(_path, _cache), do: Agent.get(__MODULE__, &Map.get(&1, :load))
  end

  # Records the catalogs Runtime.reload/2 was asked to apply.
  defmodule RecRuntime do
    use GenServer
    def start_link, do: GenServer.start_link(__MODULE__, [])
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:reload, cat}, _from, state), do: {:reply, :ok, [cat | state]}
    def handle_call(:reloads, _from, state), do: {:reply, state, state}
  end

  defp start_stub(opts) do
    {:ok, agent} = StubLoader.start(opts)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
  end

  defp start_sync(runtime) do
    {:ok, sync} =
      Sync.start_link(
        name: nil,
        loader: StubLoader,
        runtime: runtime,
        interval_ms: nil,
        config_path: "gs://bucket/proj",
        cache_dir: "/tmp"
      )

    on_exit(fn -> if Process.alive?(sync), do: GenServer.stop(sync) end)
    sync
  end

  defp start_rec do
    {:ok, rec} = RecRuntime.start_link()
    on_exit(fn -> if Process.alive?(rec), do: GenServer.stop(rec) end)
    rec
  end

  # a :status call flushes the mailbox, so the preceding :tick has been fully handled
  defp tick(sync) do
    send(sync, :tick)
    Sync.status(sync)
  end

  test "an unchanged digest does not reload" do
    rec = start_rec()
    start_stub(digest: {:ok, "d0"}, load: {:ok, catalog()})
    sync = start_sync(rec)

    assert %{result: :unchanged} = tick(sync)
    assert GenServer.call(rec, :reloads) == []
  end

  test "a changed digest with a valid config reloads the runtime" do
    rec = start_rec()
    start_stub(digest: {:ok, "d0"}, load: {:ok, catalog()})
    sync = start_sync(rec)

    StubLoader.set(:digest, {:ok, "d1"})
    assert %{result: :applied} = tick(sync)
    assert [%Catalog{}] = GenServer.call(rec, :reloads)
  end

  test "a tick that RAISES is caught — the syncer stays alive and keeps the running config" do
    rec = start_rec()
    start_stub(digest: {:ok, "d0"}, load: {:ok, catalog()})
    sync = start_sync(rec)

    # A malformed loader return makes sync/1 raise (no case clause) — simulating a bang
    # FS op blowing up when the cache disk fills. Without the tick's rescue this crashes
    # the GenServer and the following status call would fail.
    StubLoader.set(:digest, :kaboom)
    status = tick(sync)

    assert Process.alive?(sync)
    assert {:error, :sync_crashed} = status.result
    assert GenServer.call(rec, :reloads) == []
  end

  test "a changed digest with an INVALID config keeps the running config (no reload)" do
    rec = start_rec()
    start_stub(digest: {:ok, "d0"}, load: {:ok, catalog()})
    sync = start_sync(rec)

    StubLoader.set(:digest, {:ok, "d1"})
    StubLoader.set(:load, {:error, {:config_invalid, [:boom]}})

    assert %{result: {:error, {:config_invalid, _}}} = tick(sync)
    assert GenServer.call(rec, :reloads) == []
  end

  test "a check error keeps the running config and reloads nothing" do
    rec = start_rec()
    start_stub(digest: {:ok, "d0"}, load: {:ok, catalog()})
    sync = start_sync(rec)

    StubLoader.set(:digest, {:error, :unauthorized})
    assert %{result: {:error, :unauthorized}} = tick(sync)
    assert GenServer.call(rec, :reloads) == []
  end

  test "a tick while the Runtime is down is a no-op (retries next tick)" do
    start_stub(digest: {:ok, "d0"}, load: {:ok, catalog()})
    sync = start_sync(:sync_test_absent_runtime)

    StubLoader.set(:digest, {:ok, "d1"})
    assert %{result: :runtime_down} = tick(sync)
  end
end
