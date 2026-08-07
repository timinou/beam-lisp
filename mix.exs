defmodule BeamLisp.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_lisp,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # lib/dev holds the Tidewave endpoint; its deps exist only in :dev.
  # test/support compiles only under :test so `BeamLisp.Test.realize/1`
  # (the lazy-aware comparison helper) is available to the ExUnit suites.
  defp elixirc_paths(:dev), do: ["lib", "lib/dev"]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {BeamLisp.Application, []}
    ]
  end

  defp deps do
    [
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.5", only: :dev}
    ]
  end
end
