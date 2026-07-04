defmodule Offloader.Metrics.RequestsTest do
  # async: false — the Requests accumulator is a named singleton with a shared ETS
  # table; tests reset it between cases.
  use ExUnit.Case, async: false

  alias Offloader.Metrics.Requests

  setup do
    Requests.reset()
    on_exit(&Requests.reset/0)
    :ok
  end

  test "status_class buckets HTTP codes into a bounded label set" do
    assert Requests.status_class(200) == :ok
    assert Requests.status_class(422) == :client_error
    assert Requests.status_class(404) == :client_error
    assert Requests.status_class(503) == :not_ready
    assert Requests.status_class(500) == :server_error
  end

  test "observe accumulates counters + histogram, rendered as Prometheus text" do
    Requests.observe("champ", :ok, 3)
    Requests.observe("champ", :ok, 40)
    Requests.observe("champ", :client_error, 1)

    text = Requests.to_prometheus()

    assert text =~ ~s(offloader_requests_total{endpoint="champ",status="ok"} 2)
    assert text =~ ~s(offloader_requests_total{endpoint="champ",status="client_error"} 1)

    # histogram: cumulative buckets. 3 requests total; le=5 catches the 3ms + 1ms = 2.
    assert text =~ ~s(offloader_request_duration_ms_bucket{endpoint="champ",le="5"} 2)
    assert text =~ ~s(offloader_request_duration_ms_bucket{endpoint="champ",le="50"} 3)
    assert text =~ ~s(offloader_request_duration_ms_bucket{endpoint="champ",le="+Inf"} 3)
    assert text =~ ~s(offloader_request_duration_ms_count{endpoint="champ"} 3)
    assert text =~ ~s(offloader_request_duration_ms_sum{endpoint="champ"} 44)
  end

  test "the telemetry event drives the accumulator" do
    :telemetry.execute(
      [:offloader, :request, :stop],
      %{duration_ms: 12},
      %{endpoint: "via_event", status: :ok}
    )

    # handler runs synchronously in this process
    assert Requests.to_prometheus() =~
             ~s(offloader_requests_total{endpoint="via_event",status="ok"} 1)
  end

  test "empty state renders nothing (no stray series)" do
    assert Requests.to_prometheus() == ""
  end

  test "concurrent observations are counted exactly (atomic ETS counters)" do
    1..500
    |> Task.async_stream(fn _ -> Requests.observe("hot", :ok, 7) end, max_concurrency: 50)
    |> Stream.run()

    assert Requests.to_prometheus() =~
             ~s(offloader_requests_total{endpoint="hot",status="ok"} 500)
  end
end
