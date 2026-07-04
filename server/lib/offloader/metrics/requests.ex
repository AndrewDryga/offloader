defmodule Offloader.Metrics.Requests do
  @moduledoc """
  Per-endpoint request counters + a latency histogram, for the admin `/metrics` page.

  Unlike the snapshot gauges (rendered from the diagnostics map on scrape), request
  metrics accumulate over time, so we keep them in a `write_concurrency` ETS table and
  increment them from the `[:offloader, :request, :stop]` telemetry handler — which
  runs in the request process, so recording is a lock-free `:ets.update_counter`, never
  a GenServer hop. This GenServer only owns the table + handler lifecycle.

  Cardinality is bounded on purpose: labels are the endpoint NAME and a coarse status
  class (`ok` / `client_error` / `server_error` / `not_ready`) — never params, tenants,
  or request ids.
  """

  use GenServer

  @table :offloader_request_metrics
  @event [:offloader, :request, :stop]
  # Prometheus-style latency buckets in milliseconds (plus an implicit +Inf).
  @buckets [1, 2, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]

  # ── public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Record a served request. `status` is an atom class; `duration_ms` a number. Safe to
  call before the table exists (a no-op), so it never breaks a request.
  """
  @spec observe(String.t(), atom(), number()) :: :ok
  def observe(endpoint, status, duration_ms) do
    if :ets.whereis(@table) != :undefined do
      :ets.update_counter(
        @table,
        {:count, endpoint, status},
        {2, 1},
        {{:count, endpoint, status}, 0}
      )

      :ets.update_counter(
        @table,
        {:sum_ms, endpoint},
        {2, round(duration_ms)},
        {{:sum_ms, endpoint}, 0}
      )

      :ets.update_counter(@table, {:total, endpoint}, {2, 1}, {{:total, endpoint}, 0})

      for le <- @buckets, duration_ms <= le do
        :ets.update_counter(@table, {:bucket, endpoint, le}, {2, 1}, {{:bucket, endpoint, le}, 0})
      end
    end

    :ok
  end

  @doc "The status class for an HTTP status code (bounded label set)."
  @spec status_class(pos_integer()) :: atom()
  def status_class(code) when code in 200..299, do: :ok
  def status_class(503), do: :not_ready
  def status_class(code) when code in 400..499, do: :client_error
  def status_class(_code), do: :server_error

  @doc "Render the accumulated request metrics as Prometheus exposition text."
  @spec to_prometheus() :: String.t()
  def to_prometheus do
    case safe_tab2list() do
      [] -> ""
      rows -> render(rows)
    end
  end

  @doc "Clear all accumulated counters (tests)."
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    :telemetry.attach(
      "offloader-request-metrics",
      @event,
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach("offloader-request-metrics")
    :ok
  end

  @doc false
  def handle_event(@event, %{duration_ms: ms}, %{endpoint: endpoint, status: status}, _config) do
    observe(endpoint, status, ms)
  end

  # ── rendering ─────────────────────────────────────────────────────────────────

  defp safe_tab2list do
    if :ets.whereis(@table) == :undefined, do: [], else: :ets.tab2list(@table)
  end

  defp render(rows) do
    endpoints =
      rows |> Enum.map(&endpoint_of/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    data = Map.new(rows)

    [
      counter_lines(endpoints, data),
      histogram_lines(endpoints, data)
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp counter_lines(endpoints, data) do
    series =
      for ep <- endpoints,
          status <- ~w(ok client_error server_error not_ready)a,
          n = Map.get(data, {:count, ep, status}),
          not is_nil(n) do
        ~s(offloader_requests_total{endpoint="#{ep}",status="#{status}"} #{n})
      end

    if series == [],
      do: [],
      else: [
        "# HELP offloader_requests_total total requests served, by endpoint and status class",
        "# TYPE offloader_requests_total counter" | series
      ]
  end

  defp histogram_lines(endpoints, data) do
    header = [
      "# HELP offloader_request_duration_ms request serve latency in milliseconds",
      "# TYPE offloader_request_duration_ms histogram"
    ]

    body =
      for ep <- endpoints do
        total = Map.get(data, {:total, ep}, 0)
        sum = Map.get(data, {:sum_ms, ep}, 0)

        bucket_lines =
          for le <- @buckets do
            count = Map.get(data, {:bucket, ep, le}, 0)
            ~s(offloader_request_duration_ms_bucket{endpoint="#{ep}",le="#{le}"} #{count})
          end

        bucket_lines ++
          [
            ~s(offloader_request_duration_ms_bucket{endpoint="#{ep}",le="+Inf"} #{total}),
            ~s(offloader_request_duration_ms_sum{endpoint="#{ep}"} #{sum}),
            ~s(offloader_request_duration_ms_count{endpoint="#{ep}"} #{total})
          ]
      end

    if endpoints == [], do: [], else: header ++ List.flatten(body)
  end

  defp endpoint_of({{:count, ep, _status}, _}), do: ep
  defp endpoint_of({{:total, ep}, _}), do: ep
  defp endpoint_of({{:sum_ms, ep}, _}), do: ep
  defp endpoint_of({{:bucket, ep, _le}, _}), do: ep
  defp endpoint_of(_), do: nil
end
