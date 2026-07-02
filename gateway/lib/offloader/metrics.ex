defmodule Offloader.Metrics do
  @moduledoc """
  Renders the operator diagnostics map (`Offloader.Runtime.diagnostics/1`) as
  Prometheus text-format metrics for the admin `/metrics` endpoint. The gauges are
  the ones operators alert on: snapshot age/staleness, refresh health, source
  reachability, DuckDB status, and disk. No labels carry secrets — only dataset ids.
  """

  @doc "Render a diagnostics map as Prometheus exposition text."
  @spec to_prometheus(map()) :: String.t()
  def to_prometheus(diag) do
    [
      gauge("offloader_up", "1 if the gateway process is serving", "1"),
      gauge("offloader_ready", "1 if every dataset has an active snapshot", bool(diag[:ready])),
      gauge(
        "offloader_duckdb_up",
        "1 if DuckDB answers a trivial query",
        bool(diag[:duckdb_status] == "ok")
      ),
      info("offloader_build_info", "build version", %{
        version: diag[:build_version],
        config_version: to_string(diag[:config_version])
      }),
      pool_gauges(diag),
      disk_gauge(diag),
      dataset_gauges(diag)
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # The DuckDB read pool: how many connections and how many are busy right now — the
  # signal for "am I shedding load as 503s?" (busy == connections under sustained load).
  defp pool_gauges(%{pool: %{connections: conns, busy: busy}})
       when is_integer(conns) and is_integer(busy) do
    gauge("offloader_pool_connections", "DuckDB read-pool size", to_string(conns)) ++
      gauge("offloader_pool_busy", "DuckDB read-pool connections in use", to_string(busy))
  end

  defp pool_gauges(_diag), do: []

  defp dataset_gauges(diag) do
    datasets = diag[:datasets] || []

    [
      gauge_series(
        "offloader_snapshot_age_seconds",
        "age of the active snapshot in seconds",
        datasets,
        fn d ->
          {d.dataset, get_in(d, [:active_snapshot, :age_seconds])}
        end
      ),
      gauge_series(
        "offloader_snapshot_stale",
        "1 if the active snapshot is stale",
        datasets,
        fn d ->
          {d.dataset, bool_or_nil(d[:stale])}
        end
      ),
      gauge_series(
        "offloader_refresh_ok",
        "1 if the last refresh attempt succeeded",
        datasets,
        fn d ->
          {d.dataset, bool(d[:manifest_valid])}
        end
      ),
      gauge_series(
        "offloader_source_reachable",
        "1 if the dataset source is reachable",
        datasets,
        fn d ->
          {d.dataset, bool(d[:source_reachable])}
        end
      )
    ]
  end

  defp disk_gauge(diag) do
    case get_in(diag, [:disk, :cache_dir_free_bytes]) do
      n when is_integer(n) ->
        gauge(
          "offloader_cache_disk_free_bytes",
          "free bytes on the cache filesystem",
          to_string(n)
        )

      _ ->
        []
    end
  end

  defp gauge(name, help, value) do
    ["# HELP #{name} #{help}", "# TYPE #{name} gauge", "#{name} #{value}"]
  end

  defp gauge_series(name, help, datasets, extract) do
    lines =
      datasets
      |> Enum.map(extract)
      |> Enum.reject(fn {_ds, v} -> is_nil(v) end)
      |> Enum.map(fn {ds, v} -> ~s(#{name}{dataset="#{ds}"} #{v}) end)

    if lines == [], do: [], else: ["# HELP #{name} #{help}", "# TYPE #{name} gauge" | lines]
  end

  defp info(name, help, labels) do
    label_str = labels |> Enum.map_join(",", fn {k, v} -> ~s(#{k}="#{escape(v)}") end)
    ["# HELP #{name} #{help}", "# TYPE #{name} gauge", "#{name}{#{label_str}} 1"]
  end

  defp bool(true), do: "1"
  defp bool(_), do: "0"

  defp bool_or_nil(nil), do: nil
  defp bool_or_nil(true), do: "1"
  defp bool_or_nil(_), do: "0"

  defp escape(v),
    do: v |> to_string() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
end
