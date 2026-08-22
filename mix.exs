defmodule BeamLisp.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_lisp,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # AFTER :elixir, not before. A Mix compiler task must itself be
      # compiled before Mix can find it, so putting it first made a
      # clean checkout (or a fresh MIX_ENV) fail with "the task could
      # not be found" — the classic bootstrap trap, and one that only
      # appears when `_build` is empty, which is exactly when a new
      # contributor meets it.
      #
      # Running after :elixir is also correct on the merits: the NIF is
      # loaded lazily by `defnative` at namespace-require time, not at
      # module-compile time, so it only has to exist before the first
      # CALL.
      compilers: Mix.compilers() ++ [:beam_lisp_native],
      # `beam_lisp_native` builds the Rust crates that `defnative`
      # namespaces load. It runs BEFORE :elixir so a NIF is present
      # before anything tries to load it.

      # `beam_lisp_native` builds the Rust crates that `defnative`
      # namespaces load. It runs BEFORE :elixir so a NIF is present
      # before anything tries to load it.

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
      # :inets/:ssl are the AGENT cluster's transport. Without them declared,
      # Mix leaves them off the code path entirely -- `:code.lib_dir(:inets)`
      # returns {:error, :bad_name}, and `:inets.start()` succeeds anyway
      # because it only starts what it can find. The failure then surfaces
      # LATER and misleadingly, as `:http_util.timestamp/0 is undefined`,
      # which reads like a broken OTP install rather than a missing dep.
      # (Recorded in PLAN-017 as "the :httpc-under-mix open question".)
      extra_applications: [:logger, :inets, :ssl, :crypto],
      mod: {BeamLisp.Application, []}
    ]
  end

  defp deps do
    [
      {:tidewave, "~> 0.5", only: :dev},
      # Bandit is the endpoint's adapter (config/config.exs), so it is no
      # longer dev-only: the seam's server half needs an HTTP server wherever
      # spell runs.
      {:bandit, "~> 1.5"},
      # The seam's server half: the emitted page declares `@host $chat :
      # live("SpellWeb.ChatLive")` and its signals ride the LiveView channel
      # (window.__stLiveBridge). Phoenix is a LIBRARY here — the endpoint
      # joins this app's own supervision tree; there is no second app.
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      # Rustler is a Rust-side dependency of native/datom_redb (see its
      # Cargo.toml). It is NOT needed as a Mix dep: `defnative` builds
      # and loads the crate itself, via the :beam_lisp_native compiler.
      {:rustler, "~> 0.38", runtime: false}
    ]
  end
end
