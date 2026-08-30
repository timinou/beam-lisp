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
      # `beam_lisp` AOT-compiles its OWN `priv/` sources — core, datom,
      # optics, specter — into real BEAM modules, so a consumer loads them
      # from disk instead of reading and compiling them at every boot.
      #
      # Measured on a project that requires `datom` (seventeen files): ~30s
      # of runtime compilation per VM start, which is not merely slow. It is
      # the difference between a durability test that spawns two child VMs
      # and one that times out, and it is paid by every `mix run` of every
      # script in every downstream project.
      #
      # AFTER :elixir for the usual bootstrap reason: a Mix compiler task
      # must itself be compiled before Mix can find it.
      compilers: Mix.compilers() ++ [:beam_lisp_native, :beam_lisp],
      # Per-project, NOT `config :beam_lisp` — the compiler is recursive, so
      # an app that depends on this one would otherwise impose its own
      # source dir here and `priv/` would never be compiled.
      # `priv/` (core, datom, optics) — the language libraries. The
      # contract/view stack lives in the :interface app of the spell repo
      # since the extraction; beam-lisp is the language again.
      beam_lisp: [source_dirs: ["priv"]],
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
      extra_applications: [:logger, :ssh],
      mod: {BeamLisp.Application, []}
    ]
  end

  defp deps do
    [
      {:tidewave, "~> 0.5", only: :dev},
      # Bandit backs the dev-only Tidewave playground (lib/dev/dev_server.ex).
      # `only: :dev` again: the spell endpoint it used to serve moved to the
      # spell repo with the extraction.
      {:bandit, "~> 1.5", only: :dev},
      # file_system drives the live-reload watcher (lib/beam_lisp/reload_watcher.ex):
      # it emits filesystem events for `.bl` saves, which the watcher stages into
      # the reload bundle. Dev + test only — production trusts compiled beams and
      # runs no watcher (the guarantee lives in the running image, not the build).
      {:file_system, "~> 1.0", only: [:dev, :test]},
      # examples/datom/live/06-projector.bl starts a PubSub as its broadcast
      # transport; the examples run only under `mix test`.
      {:phoenix_pubsub, "~> 2.1", only: :test},
      # Rustler is a Rust-side dependency of native/datom_redb (see its
      # Cargo.toml). It is NOT needed as a Mix dep: `defnative` builds
      # and loads the crate itself, via the :beam_lisp_native compiler.
      {:rustler, "~> 0.38", runtime: false},
      # Explorer (Polars) is the DataFrame surface `datom.frame/q-df` maps a
      # query result onto — the Session-A analytical backend. It is OPTIONAL at
      # runtime: `datom/q` and the whole datalog core never touch it, and
      # `q-df` degrades to a clear "add :explorer" error when it is absent, so a
      # deployment that only wants set-valued datalog carries no Polars weight.
      {:explorer, "~> 0.12"}
    ]
  end
end
