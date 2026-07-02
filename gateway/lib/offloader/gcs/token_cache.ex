defmodule Offloader.Gcs.TokenCache do
  @moduledoc """
  Caches the GCS access token and serializes fetches, so a burst of callers (pool
  reconnects, a refresh cycle, resolver listings) produces one token fetch, not many.

  The token is cached until its reported `expires_in` minus a safety buffer (the
  metadata server hands out shared, already-aged tokens); sources that report no
  lifetime get a conservative default. `refresh/1` force-fetches — call it when GCS
  rejects the cached token (401) mid-operation.
  """

  use GenServer
  require Logger

  # Refresh 5 minutes before expiry; assume 55 minutes when the source reports none.
  @safety_seconds 300
  @default_ttl_seconds 3_300

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The cached token, fetching (once) if missing or expired."
  @spec get(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def get(server \\ __MODULE__), do: GenServer.call(server, :get, 30_000)

  @doc "Force a fresh token (bypassing the cache) — for a 401 mid-operation."
  @spec refresh(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 30_000)

  @doc """
  Milliseconds until the cached token should be re-registered — how long the current
  token stays valid (per its own TTL), floored so a caller never busy-loops and
  capped so a token with no reported lifetime is still re-checked periodically. Lets
  the engine drive its writer secret-refresh cadence off the REAL token lifetime
  instead of a fixed timer (a metadata-server token can have only minutes left).
  """
  @spec refresh_after_ms(GenServer.server()) :: pos_integer()
  def refresh_after_ms(server \\ __MODULE__), do: GenServer.call(server, :refresh_after_ms)

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    fetcher = Keyword.get(opts, :fetcher, &Offloader.Gcs.Token.fetch/0)
    {:ok, %{fetcher: fetcher, token: nil, expires_at: 0}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    if state.token && now() < state.expires_at do
      {:reply, {:ok, state.token}, state}
    else
      fetch_and_reply(state)
    end
  end

  @impl true
  def handle_call(:refresh, _from, state), do: fetch_and_reply(state)

  @impl true
  def handle_call(:refresh_after_ms, _from, state) do
    # Time until the cached token needs refetching; at least 60s (no busy loop), at
    # most 15 min (re-check even a long-lived token). No token cached → the 60s floor
    # (monotonic time can be negative, so use the token, not expires_at, as the guard).
    ms =
      if is_nil(state.token) do
        60_000
      else
        seconds = state.expires_at |> Kernel.-(now()) |> max(0) |> min(900) |> max(60)
        seconds * 1000
      end

    {:reply, ms, state}
  end

  defp fetch_and_reply(state) do
    case state.fetcher.() do
      {:ok, token, expires_in} ->
        ttl = max((expires_in || @default_ttl_seconds) - @safety_seconds, 60)
        {:reply, {:ok, token}, %{state | token: token, expires_at: now() + ttl}}

      {:error, reasons} ->
        Logger.warning("GCS token fetch failed: #{inspect(reasons)}")
        {:reply, {:error, reasons}, %{state | token: nil, expires_at: 0}}
    end
  end

  defp now, do: System.monotonic_time(:second)
end
