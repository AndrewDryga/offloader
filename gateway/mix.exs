defmodule Offloader.MixProject do
  use Mix.Project

  def project do
    [
      app: :offloader,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # OTP application. Two Phoenix endpoints (API + admin) are supervised by
  # Offloader.Application; there is no database (config-backed keys, DuckDB data).
  def application do
    [
      mod: {Offloader.Application, []},
      extra_applications: [:logger, :runtime_tools]
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
      {:yaml_elixir, "~> 2.9"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
