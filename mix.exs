defmodule BeamLisp.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_lisp,
      # Release version. CI stamps this from the tag, normalized to a valid
      # `Version` (`v2026.0` → `2026.0.0`), so the tag is the single source of
      # truth for an artifact; a local build keeps the source default.
      # `bl version` reads it back from `:beam_lisp`'s vsn at runtime.
      version: System.get_env("BL_VERSION") || "0.1.0",
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
      # The tiered source tree (see BeamLisp.Tiers): priv/boot is the CODEGEN
      # (its own key — a change here rebuilds every beam), priv/build is the
      # build DRIVER (its own key — a change here rebuilds the driver only),
      # priv/std the stdlib, priv/lib the batteries.
      beam_lisp: [source_dirs: ["priv/boot", "priv/std", "priv/lib", "priv/compat", "priv/build"]],
      # `beam_lisp_native` builds the Rust crates that `defnative`
      # namespaces load. It runs BEFORE :elixir so a NIF is present
      # before anything tries to load it.

      # `beam_lisp_native` builds the Rust crates that `defnative`
      # namespaces load. It runs BEFORE :elixir so a NIF is present
      # before anything tries to load it.

      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # PACKAGING — `mix release` is the ONE supported tier. escript is
      # DEPRECATED and intentionally not configured: an escript is a single
      # BEAM archive behind a #! header with NO way to carry native artifacts,
      # and a full beam-lisp ships native extensions (defnative → Rust crate
      # NIFs, Explorer/Polars, z3, drop-packed binaries). Only a release
      # packages the whole language — ERTS + priv/ + the native artifacts —
      # so it is the only build that yields a complete, runnable `bl`.
      #
      # `mix release bl` — the ERTS-carrying packaging tier (self-contained;
      # no host OTP install needed). Default settings, no Burrito step: wrap
      # only if the self-extracting UX is wanted.
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
      # Bandit is the HTTP server behind `web/serve` and therefore `bl serve`
      # (and the dev-only Tidewave playground, lib/dev/dev_server.ex). It ships
      # in the release: a drop that advertises `bl serve` must be able to run it.
      {:bandit, "~> 1.5"},
      # websock_adapter answers the upgrade bandit hands it: bandit depends on
      # `websock` (the behaviour) but NOT on the adapter (the `upgrade/4` call),
      # so `web.upgrade` — and with it every live.app socket — dies in a release
      # without this line. It ships for the same reason bandit does: a drop that
      # advertises `bl serve` serves live pages, and a page whose every intent
      # rides the socket is dead without it.
      {:websock_adapter, "~> 0.5"},
      # file_system drives the live-reload watcher (lib/beam_lisp/reload_watcher.ex)
      # behind `bl watch` and `bl monitor`: it emits filesystem events for `.bl`
      # saves, which the watcher stages into the reload bundle. Ships in the
      # release for the same reason as bandit.
      {:file_system, "~> 1.0"},
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
