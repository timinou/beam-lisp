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
      # The tiered source tree (see BeamLisp.Tiers): priv/boot is the toolchain,
      # priv/std the stdlib, priv/lib the batteries, priv/build the build itself.
      beam_lisp: [source_dirs: ["priv/boot", "priv/std", "priv/lib", "priv/build"]],
      # `beam_lisp_native` builds the Rust crates that `defnative`
      # namespaces load. It runs BEFORE :elixir so a NIF is present
      # before anything tries to load it.

      # `beam_lisp_native` builds the Rust crates that `defnative`
      # namespaces load. It runs BEFORE :elixir so a NIF is present
      # before anything tries to load it.

      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # `bl` — the language's own executable. An escript is the BEAM's
      # native single-file packaging (an archive of .beam files behind an
      # #! header, loaded by any OTP installation). The main_module is the
      # AOT-compiled CLI namespace ITSELF — no Elixir floor: the escript
      # apply enters BeamLisp.Ns.Bl.Cli.main/1, which boots the substrate
      # (AOT.boot) and dispatches, all in beam-lisp (priv/std/bl/cli.bl).
      # Native accelerators (the defnative Rust crates, Explorer/Polars,
      # z3) are NIFs and cannot ride in an escript archive — pure-language
      # code is unaffected; those paths degrade or need a checkout/release.
      escript: [name: "bl", main_module: BeamLisp.Ns.Bl.Cli],
      # `mix release` — the ERTS-carrying packaging tier (the `bl` escript
      # needs an OTP install; a release does not). Default settings, no
      # Burrito step: wrap only if the self-extracting UX is wanted.
      releases: [bl: [
        include_executables_for: [:unix],
        # Do NOT strip beams: stripping re-stamps every module, so the AOT
        # drift gate (aot.ex stale?/2) rightly reads them as built by a
        # different toolchain and refuses them — every AOT namespace would
        # fall back to recompiling source on each boot. Ship the beams the
        # compiler emitted; the gate then passes and boot stays on the fast
        # __bl_init__ path.
        strip_beams: false
      ]]
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
      # Rustler is a Rust-side dependency of the native datom crates (datom_fjall, datom_vector, datom_datalog).
      # It is NOT needed as a Mix dep: `defnative` builds
      # and loads the crate itself, via the :beam_lisp_native compiler.
      {:rustler, "~> 0.38", runtime: false},
      # Explorer (Polars) is the DataFrame surface `datom.frame/q-df` maps a
      # query result onto — the Session-A analytical backend. It is OPTIONAL at
      # runtime: `datom/q` and the whole datalog core never touch it, and
      # `q-df` degrades to a clear "add :explorer" error when it is absent, so a
      # deployment that only wants set-valued datalog carries no Polars weight.
      {:explorer, "~> 0.12"},
      # datom/blob-s3.bl signs AWS Signature V4 with aws_signature and speaks
      # HTTP with Req. Both were previously transitive (via explorer); they are
      # the S3 blob tier's direct deps now — a transitive dep vanishing must
      # not be a silent S3 outage.
      {:req, "~> 0.7"},
      {:aws_signature, "~> 0.4"}
    ]
  end
end
