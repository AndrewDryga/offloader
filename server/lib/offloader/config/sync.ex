defmodule Offloader.Config.Sync do
  @moduledoc """
  Optional hot config auto-sync. On an interval it re-checks `OFFLOADER_CONFIG`'s cheap
  change-token (`Config.Loader.digest/1` — a single LIST for a remote config, no download) and,
  when it changed, fetches + validates the project and hands it to `Offloader.Runtime.reload/2`
  (zero downtime, even across a dataset schema change).

  A bad sync (network / invalid YAML / validation error) is LOGGED and the running config is
  KEPT — the live service is never dropped for a bad fetch. The slow list/download runs HERE,
  off the Runtime's mailbox, so a slow bucket can't block serving.

  Enabled only when `OFFLOADER_CONFIG_SYNC_INTERVAL > 0`.
  """

  use GenServer
  require Logger

  alias Offloader.Config
  alias Offloader.Config.Loader

  @table :offloader_config_sync

  defstruct [:config_path, :cache_dir, :interval_ms, :runtime, :loader, :last_digest, :status]

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The last sync outcome, authoritative (a GenServer call). Used in tests."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  The last published sync status, read LOCK-FREE from ETS — safe from the diagnostics/metrics
  request path, which must never block behind a slow sync tick.
  """
  @spec published_status() :: map()
  def published_status do
    with tid when tid != :undefined <- :ets.whereis(@table),
         [{:status, status}] <- :ets.lookup(@table, :status) do
      status
    else
      _ -> %{result: :init}
    end
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      config_path: opts[:config_path] || Config.config_path(),
      cache_dir: opts[:cache_dir] || Config.cache_dir(),
      interval_ms: Keyword.get(opts, :interval_ms, Config.config_sync_interval_ms()),
      runtime: opts[:runtime] || Offloader.Runtime,
      loader: opts[:loader] || Loader,
      last_digest: nil,
      status: %{last_checked: nil, last_applied: nil, digest: nil, result: :init}
    }

    ensure_table()
    publish(state.status)

    # Baseline the current config's digest so the first tick doesn't re-apply an unchanged config.
    state =
      case state.loader.digest(state.config_path) do
        {:ok, digest} -> %{state | last_digest: digest}
        {:error, _} -> state
      end

    schedule(state)
    {:ok, state}
  end

  # A named ETS table the diagnostics/metrics path reads lock-free (created idempotently so a
  # supervised restart reuses it). Owned by this GenServer.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
  end

  defp publish(status), do: :ets.insert(@table, {:status, status})

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info(:tick, state) do
    # The tick must never crash the syncer: a raise (e.g. a bang FS op in the loader when
    # the cache disk fills or is read-only) would, at a low interval, trip the supervisor's
    # restart intensity and take the whole app down — the opposite of "a bad sync keeps the
    # running config." Any failure becomes the log-and-keep-running path instead.
    state =
      try do
        sync(state)
      rescue
        e ->
          Logger.error(
            "config sync tick crashed (keeping running config): #{Exception.message(e)}"
          )

          put_status(state, %{last_checked: DateTime.utc_now(), result: {:error, :sync_crashed}})
      catch
        kind, reason ->
          Logger.error("config sync tick #{kind} (keeping running config): #{inspect(reason)}")
          put_status(state, %{last_checked: DateTime.utc_now(), result: {:error, :sync_crashed}})
      end

    schedule(state)
    {:noreply, state}
  end

  # ── internals ────────────────────────────────────────────────────────────────

  defp sync(state) do
    now = DateTime.utc_now()

    case state.loader.digest(state.config_path) do
      {:ok, digest} when digest == state.last_digest ->
        put_status(state, %{last_checked: now, result: :unchanged})

      {:ok, digest} ->
        apply_change(state, digest, now)

      {:error, reason} ->
        Logger.warning("config sync check failed (keeping running config): #{inspect(reason)}")
        put_status(state, %{last_checked: now, result: {:error, reason}})
    end
  end

  defp apply_change(state, digest, now) do
    # Runtime restarting — skip this tick (retry next); don't even fetch.
    if runtime_alive?(state.runtime) do
      case state.loader.load(state.config_path, state.cache_dir) do
        {:ok, catalog} ->
          :ok = Offloader.Runtime.reload(state.runtime, catalog)
          Logger.info("config sync applied a new config revision")

          %{state | last_digest: digest}
          |> put_status(%{last_checked: now, last_applied: now, digest: digest, result: :applied})

        {:error, reason} ->
          Logger.warning(
            "config sync fetch/validate failed (keeping running config): #{inspect(reason)}"
          )

          put_status(state, %{last_checked: now, result: {:error, reason}})
      end
    else
      put_status(state, %{last_checked: now, result: :runtime_down})
    end
  end

  defp runtime_alive?(runtime), do: is_pid(GenServer.whereis(runtime))

  defp put_status(state, fields) do
    status = Map.merge(state.status, fields)
    publish(status)
    %{state | status: status}
  end

  defp schedule(%{interval_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :tick, ms)

  defp schedule(_state), do: :ok
end
