defmodule Offloader.MixProject do
  use Mix.Project

  # Source-available under the Functional Source License 1.1 (FSL-1.1-ALv2); each release
  # converts to Apache-2.0 two years after it ships. See LICENSE at the repository root.
  def project do
    [
      app: :offloader,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # An explicit floor (the tool's default is 90) so `mix test --cover` is a real
      # gate: red means coverage regressed, not that no threshold was ever chosen.
      test_coverage: [summary: [threshold: 78]],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases()
    ]
  end

  # The production release bundles ERTS, so the runtime image needs no Erlang/Elixir —
  # only the C libraries the DuckDB NIF and crypto depend on. Config is read at boot
  # from env vars (config/runtime.exs), never baked into the image.
  defp releases do
    [
      offloader: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  # OTP application. Two Phoenix endpoints (API + admin) are supervised by
  # Offloader.Application; there is no database (config-backed keys, DuckDB data).
  def application do
    [
      mod: {Offloader.Application, []},
      # inets/ssl: the GCS client (Offloader.Gcs.Client) speaks HTTP via :httpc.
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:duckdbex, "~> 0.4"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
