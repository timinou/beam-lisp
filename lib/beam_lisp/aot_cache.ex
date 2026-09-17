defmodule BeamLisp.AOTCache do
  @moduledoc """
  Global content-addressed cache for AOT-compiled `.beam` artifacts.

  `mix compile` pays the full AOT cost (eval every form, then the Erlang
  backend on one Body module per namespace) in EVERY build directory —
  every worktree, every `MIX_BUILD_PATH`, every consumer project. The
  output depends only on inputs we can hash: the source closure's content
  and the toolchain that compiled it. This module caches the emitted beams
  under `$XDG_CACHE_HOME/beam_lisp/aot/<compiler-key>/<closure-key>/` and
  hardlinks them into the local compile path on a hit, turning a repeat
  cold build into file copies.

  Keys:

    * `compiler_key/0` — the TOOLCHAIN tier (FEAT-030): beam_lisp's version,
      Elixir and OTP versions, the SHA-256 of the codegen modules' SOURCES
      (AOT/AtomGuard/CompilerData/Record/Emit/Link/Native — NOT the Compiler
      orchestration module, which does not affect emitted code) and
      every source in `priv/boot/` (the self-hosted compiler, the reader
      providers, and the ambient `core`/`sugar` prelude — not the whole
      `priv/**/*.bl`). A change to a tier-1 source invalidates every beam; a
      change to any OTHER source moves only its own per-namespace key
      (`BeamLisp.AOT.ns_closure_hash/1`) and its dependents'. Memoized in
      `:persistent_term` (a VM constant in normal use).
    * `closure_key/2` — the source: sha256 over the absolute path and
      content hash of the file plus its transitive `:require` closure.
      The absolute path is part of the key because emitted beams embed it
      in their line tables.

  Correctness rules:

    * A cache entry is complete iff its directory exists — `store/4`
      writes to a sibling temp dir and renames (atomic on POSIX), so a
      crashed writer can never publish a partial entry.
    * `fetch/3` verifies every expected beam materialised in the compile
      path; anything short is a miss.
    * Everything is best-effort: any cache error degrades to a normal
      compile, never a build failure.

  Disable with `BEAM_LISP_AOT_CACHE=off`; relocate with
  `BEAM_LISP_AOT_CACHE_DIR`.
  """

  @env_off "BEAM_LISP_AOT_CACHE"
  @env_dir "BEAM_LISP_AOT_CACHE_DIR"
  @gc_last_sweep_pt {__MODULE__, :gc_last_sweep}
  @gc_defaults [keep_generations: 8, max_age_days: 30, max_delete: 4, interval_ms: 3_600_000]

  # The host modules whose bytes can change EMITTED code. `BeamLisp.Compiler` is
  # deliberately ABSENT: the lowering now lives entirely in the self-hosted
  # `priv/boot/compiler.bl` (hashed below via the `priv/**/*.bl` prelude), so the
  # Elixir `BeamLisp.Compiler` is pure orchestration — the thin `compile/2`
  # delegator, `eval_form`, `new_env`, reader interop — that does not affect a
  # single emitted byte. Hashing it would make the seed's provenance depend on
  # orchestration edits (and, historically, on the now-deleted genesis body),
  # reopening the bootstrap cycle for no soundness gain. What DOES affect
  # emitted code — the reader, the emitter, linking, ns topology, atom interning,
  # native decls — stays hashed here; a real change to the compiler's behaviour
  # lives in `compiler.bl` and is caught by the `.bl` source hash.
  # Memoization slot for the toolchain key (a VM constant in normal use).
  @toolchain_key_pt {__MODULE__, :toolchain_key}
  # Memoization slot for the build-DRIVER key, kept separate on purpose: a
  # build-tool edit must not invalidate codegen beams. See `build_key/0`.
  @build_key_pt {__MODULE__, :build_key}

  # TIER-1 = `priv/boot/` (see BeamLisp.Tiers). Everything there can alter
  # EVERY emitted byte, so it hashes into `compiler_key/0` (invalidate all)
  # rather than a per-namespace closure. WHY each file is in the tier:
  #   compiler      — the self-hosted compiler; runs at compile time for every ns
  #   reader-node   — the compiler's reader dependency (compiler requires it)
  #   reader        — the self-hosted reader every later read goes through
  #   core, sugar   — ambient: referred into every ns for unqualified name
  #                    resolution (BeamLisp.Env fetch fallback), so any ns can
  #                    depend on them WITHOUT an explicit `:require` edge
  #   data-readers  — seeds the tagged-literal (`#tag …`) registry consulted by
  #                    the reader at READ time, again with no `:require` edge
  # These implicit (edge-less) dependencies are exactly why per-namespace
  # closure hashing cannot see them — hashing the tier globally is what keeps
  # the fine-grained tier sound. Moving a file INTO boot/ is how a namespace
  # becomes ambient; nothing else needs to change.
  # The Elixir modules whose BYTES affect emitted code, so a change to any of
  # them must rotate `compiler_key/0` (invalidate every AOT beam). These are the
  # genuine codegen host: AOT driver, atom guard, the emitter, linker, native
  # bridge, and the ns-module shell. `BeamLisp.Compiler` and `BeamLisp.Reader`
  # are NOT here: since the genesis cutover they are thin FACADES that delegate
  # to the self-hosted `BeamLisp.Ns.Compiler` / `BeamLisp.Ns.Reader` (whose
  # source, `priv/boot/{compiler,reader}.bl`, is already hashed as a tier-1
  # toolchain source below). Hashing the facades would rotate the key on a mere
  # doc/plumbing edit that cannot change a single emitted byte.
  # The Elixir modules whose SOURCES affect emitted code, so a change to any of
  # them must rotate `compiler_key/0` (invalidate every AOT beam). These are the
  # genuine codegen host: AOT driver, atom guard, the emitter, linker, native
  # bridge.
  #
  # SOURCES, NOT BEAMS — and that distinction is the whole of BUG-048. This list
  # used to be hashed as `:code.get_object_code/1` bytes, and those bytes are
  # written by TWO compilers in the same tree: `bin/bl`'s cold path compiles
  # `lib/**/*.ex` with `elixirc`, and `bl build`'s substrate stage compiles the
  # same files in process. Same source, different `debug_info`/metadata bytes,
  # different key — measured: every one of these modules had a different md5
  # after each compiler ran, with `lib/beam_lisp/*.ex` untouched. So the key was
  # a property of the compiler that LAST WROTE the beams rather than of the
  # toolchain, and it moved under beams that were stamped with the previous one:
  # the drift gate called them stale while the emitter called them current, no
  # re-emission happened, the gate routed the namespace to the source path, and
  # that path needs the reader to read the reader —
  # `undefined var: reader/delimiters`. A drop built from such a checkout was
  # born stale for the same reason.
  #
  # A source digest is compiler-independent, which is what a toolchain key has
  # always claimed to be. For an image that ships no `.ex` (a release drop) the
  # digest is read from `priv/codegen.sources`, baked by the checkout whenever it
  # computes the key — see `codegen_part/0`.
  #
  # `BeamLisp.Ns` used to be listed here and was DEAD: the module has no source
  # file anywhere in the tree (`lib/beam_lisp/ns.ex` does not exist) and no beam
  # is produced, so it contributed nothing to the key in every image while
  # implying it was covered.
  @codegen_modules [
    BeamLisp.AOT,
    BeamLisp.AtomGuard,
    BeamLisp.CompilerData,
    BeamLisp.Record,
    BeamLisp.Emit,
    BeamLisp.Link
  ]

  @doc "Whether the cache participates in compilation. Default on."
  def enabled? do
    System.get_env(@env_off) not in ["off", "0", "false"]
  end

  @doc false
  def enabled_off_env, do: @env_off

  @doc "Root of the cache: `$XDG_CACHE_HOME/beam_lisp/aot` or the override."
  def dir do
    case System.get_env(@env_dir) do
      nil -> :filename.basedir(:user_cache, ~c"beam_lisp") |> Path.join("aot")
      dir -> dir
    end
  end

  @doc """
  The body-module backend is `:core`: bl-ANF → Core Erlang → BEAM through
  the boot `lower` namespace. Other settings raise before boot or cache access.
  The self-hosted compiler emits ANF, not Elixir definition syntax, so the
  removed genesis backend cannot serve as a fallback.

  It lives here, not in `BeamLisp.AOT`, because `compiler_key/0` must fold it in
  (a Core-built beam and an Elixir-built beam of the same source are different
  bytes, so they MUST get different toolchain keys or the cache would serve one
  for the other) and this module computes the key before `BeamLisp.AOT` is even
  a concern. `BeamLisp.AOT` reads the same value so build and key agree.
  """
  def aot_backend do
    case Application.get_env(:beam_lisp, :aot_backend, :core) do
      :core -> :core
      backend ->
        raise ArgumentError,
              "unsupported AOT backend #{inspect(backend)}: the self-hosted compiler emits ANF; use :core"
    end
  end

  @doc """
  Hash of the toolchain that produced a beam. Any change to codegen, the
  runtime it links against, or the language/VM version yields a new key,
  so stale artifacts compiled by a different toolchain are never linked.
  """
  def compiler_key do
    case :persistent_term.get(@toolchain_key_pt, :undefined) do
      :undefined ->
        key = compute_compiler_key()
        :persistent_term.put(@toolchain_key_pt, key)
        key

      key ->
        key
    end
  end

  @doc """
  Compute the compiler key WITHOUT the persistent_term memo — the live value
  for the CURRENT toolchain sources on disk. `compiler_key/0` caches its first
  computation for the VM's life (correct: codegen + tier-1 sources are constant
  under a running node); the daemon uses THIS to detect that the checkout it
  serves has drifted from the sources it booted with, which must force a
  restart, not a stale reuse.
  """
  def current_compiler_key, do: compute_compiler_key()

  @doc "Like `current_compiler_key/0` for the build tier: the LIVE value, unmemoized."
  def current_build_key, do: compute_build_key()

  @doc """
  Hash of the BUILD DRIVER tier (`priv/build/`): `build`, `build-plan`,
  `source-graph`, `ns-interface`.

  These namespaces decide WHAT to build; they cannot change an emitted byte.
  Hashing them into `compiler_key/0` meant every build-tool edit moved the
  toolchain key and rebuilt every beam in the tree — measured as 8 key
  generations in 21h, each a full prelude rebuild to change a scheduler.

  The driver's own beams are compiled BY the codegen, so this key folds in
  `compiler_key/0`: a codegen change still invalidates the driver, while a
  driver change invalidates the driver alone.

  The driver is also the set the drift gate runs on, so it can never be vetted
  by interface closure — asking for `build-plan`'s closure would ask the gate to
  load the namespace it is vetting. A tier key is the only sound answer.
  """
  def build_key do
    case :persistent_term.get(@build_key_pt, :undefined) do
      :undefined ->
        key = compute_build_key()
        :persistent_term.put(@build_key_pt, key)
        key

      key ->
        key
    end
  end

  defp compute_build_key, do: hash_parts([compiler_key() | build_source_contents()])

  # Content of every build-driver source, sorted by path. Read DIRECTLY (no
  # reader, no Env) for the same reason `toolchain_source_contents/0` is: this
  # runs before `BeamLisp.init/0`. An unreadable file contributes nothing
  # rather than crashing the key computation.
  defp build_source_contents do
    BeamLisp.Tiers.build_dir()
    |> Path.join("**/*.bl")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, bytes} -> [bytes]
        _ -> []
      end
    end)
  end

  @doc """
  The key a SOURCE's beam is stamped with: the tier it belongs to.

  `boot/` and every ordinary source use the codegen key; `build/` uses
  `build_key/0`. The build manifest and the emitter both route through here, so
  a beam's stamp and the gate that judges it cannot disagree.
  """
  def key_for_source(path, root \\ BeamLisp.Tiers.priv_root()) do
    if BeamLisp.Tiers.build_source?(path, root), do: build_key(), else: compiler_key()
  end

  @doc "The key a NAMESPACE's beam is stamped with: `BeamLisp.Tiers.tier_of_ns/1`."
  def key_for_ns(ns) when is_binary(ns), do: key_for_tier(BeamLisp.Tiers.tier_of_ns(ns))

  @doc "The key for a tier: `:build` → `build_key/0`, anything else → `compiler_key/0`."
  def key_for_tier(:build), do: build_key()
  def key_for_tier(_tier), do: compiler_key()
  @doc false
  # Drop the memoized toolchain key so the next `compiler_key/0` recomputes it.
  # The key is a VM-constant in normal use (codegen beams + tier-1 sources do
  # not change under a running node), so this exists only for tests that mutate
  # a hashed input in-process and must observe the new key.
  def reset_compiler_key, do: :persistent_term.erase(@toolchain_key_pt)

  @doc false
  # Drop BOTH memoized tier keys, so the next `compiler_key/0` and `build_key/0`
  # recompute. Tests that mutate a hashed input in-process use this.
  def reset_keys do
    :persistent_term.erase(@toolchain_key_pt)
    :persistent_term.erase(@build_key_pt)
    :ok
  end

  defp compute_compiler_key do
    # Loading metadata does not start the app. Builds and ordinary startup
    # must not hash different versions merely because one ran before start.
    :application.load(:beam_lisp)
    vsn =
      case :application.get_key(:beam_lisp, :vsn) do
        {:ok, v} -> List.to_string(v)
        _ -> "unknown"
      end

    parts = [
      "beam_lisp:#{vsn}",
      "elixir:#{System.version()}",
      "otp:#{:erlang.system_info(:otp_release)}",
      # The BACKEND is part of the toolchain: a Core-built beam and an
      # Elixir-built beam of the same source are different bytes, so they must
      # land under different keys or the shared cache would serve one where the
      # other belongs. Flipping `:aot_backend` rotates every beam's key exactly
      # like a codegen change, which is what it is.
      "aot_backend:#{aot_backend()}"
    ]

    codegen = codegen_part()

    # TIER-1 sources: the self-hosted compiler, the reader providers, and the
    # ambient prelude — the whole `priv/boot/` tier. A change to ANY of
    # these can alter every emitted byte (they run at compile time for every
    # namespace, or provide the reader/tagged-literal machinery, or are referred
    # into every ns via `core`/`sugar` name resolution), so they invalidate ALL
    # beams and belong in the toolchain key rather than a per-namespace closure.
    # Everything ELSE in the prelude is keyed per namespace by
    # `BeamLisp.AOT.ns_closure_hash/1`, so editing a leaf source no longer
    # rotates this key. Resolved by DIRECT file reads (no reader, no Env): this
    # runs from `Bootstrap.install!/1` BEFORE `BeamLisp.init/0`.
    toolchain_sources = toolchain_source_contents()

    hash_parts(parts ++ codegen ++ toolchain_sources)
  end

  # --- the codegen contribution (BUG-048) ---

  # The codegen host's contribution to the toolchain key, as a LIST of hash
  # parts (the legacy branch splices in several binaries, exactly as it did).
  #
  # Three images, three answers, and the ORDER is the soundness argument:
  #
  #   live sources present -> hash them, and BAKE the digest for images that ship
  #                           none. A checkout is authoritative: an edit under
  #                           `lib/` must rotate the key, or the drift gate would
  #                           accept beams produced by a different codegen.
  #   baked digest present -> a release drop. It carries no `.ex`, so the digest
  #                           its packing checkout wrote is the only
  #                           compiler-independent answer — and it is the SAME
  #                           value that checkout computes, which is what makes a
  #                           drop built FROM a checkout boot instead of being
  #                           born stale.
  #   neither              -> beam BYTES, the pre-BUG-048 rule, kept so drops
  #                           built before `priv/codegen.sources` existed still
  #                           compute the key their beams were stamped with.
  #                           Without this branch every such drop would treat its
  #                           whole stdlib as stale (80s source boots).
  defp codegen_part do
    case live_codegen_digest() do
      {:ok, digest} ->
        bake_codegen_digest(digest)
        ["codegen-source:#{digest}"]

      :error ->
        case baked_codegen_digest() do
          {:ok, digest} -> ["codegen-source:#{digest}"]
          :error -> legacy_codegen_beam_bytes()
        end
    end
  end

  # sha256 over the codegen modules' source files, each named by its module so a
  # rename or a reordering cannot collide. `:error` when ANY source is missing: a
  # partial answer would describe a different toolchain than the one running.
  defp live_codegen_digest do
    parts =
      Enum.reduce_while(@codegen_modules, [], fn mod, acc ->
        case File.read(codegen_source_path(mod)) do
          {:ok, bytes} -> {:cont, [Atom.to_string(mod), bytes | acc]}
          _ -> {:halt, :missing}
        end
      end)

    case parts do
      :missing -> :error
      parts -> {:ok, hash_parts(["codegen" | Enum.reverse(parts)])}
    end
  end

  # `lib/beam_lisp/atom_guard.ex` for `BeamLisp.AtomGuard` — derived from the
  # module name rather than listed beside it, so a module added to
  # `@codegen_modules` cannot be silently uncovered. Nil when no candidate root
  # has it, which is what a release drop looks like (`:error` upstream).
  defp codegen_source_path(mod) do
    name = Enum.map_join(Module.split(mod), "/", &Macro.underscore/1) <> ".ex"
    Enum.find_value(codegen_source_roots(), fn root -> File.exists?(Path.join(root, name)) && Path.join(root, name) end) ||
      Path.join(hd(codegen_source_roots()), name)
  end

  # Where the codegen `.ex` sources live, in order of authority:
  #
  #   1. the source tree THIS MODULE WAS COMPILED FROM. Authoritative for a
  #      checkout, and the reason `Tiers.priv_root/0` cannot be used here: with
  #      the app-shaped image (`.bl/lib/beam_lisp-0.1.0/{ebin,priv}`) that a
  #      launcher builds, `priv_root/0` answers the IMAGE's priv, whose parent
  #      holds no `lib/` at all — measured: the digest came out `:error` and the
  #      key silently fell back to the legacy beam-bytes rule, which is the very
  #      instability BUG-048 is about.
  #   2. `lib/` beside the app's `priv/` — a checkout laid out as an OTP app.
  #
  # A release drop has neither: `__DIR__` names the PACKING machine's tree (the
  # path rides in debug_info), which on that machine may still exist. That reads
  # as "live sources" for a drop packed and run on the same box, and it is
  # harmless: the drop then hashes the sources it was built from — the key its
  # beams carry — and if that tree changed since packing, the drop merely re-emits
  # its own payload's tiers. It never accepts a beam from another toolchain, which
  # is the property the key exists for.
  defp codegen_source_roots do
    [Path.expand("../../lib", __DIR__), Path.join(Path.dirname(BeamLisp.Tiers.priv_root()), "lib")]
  end

  # Where the digest is baked, for images that ship no `.ex`. Beside the tiers in
  # `priv/` because assembling a drop copies `priv/` wholesale.
  defp baked_codegen_sources_path do
    Path.join(BeamLisp.Tiers.priv_root(), "codegen.sources")
  end

  defp baked_codegen_digest do
    with {:ok, text} <- File.read(baked_codegen_sources_path()),
         digest when is_binary(digest) <- text |> String.split("\n") |> List.first(),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
      {:ok, digest}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Best-effort and atomic. This runs inside key computation, which is reached
  # from boot paths that must never fail on a cache: a read-only image ignores
  # the failure (it already carries the file, or it is a checkout that will try
  # again on the next command).
  defp bake_codegen_digest(digest) do
    path = baked_codegen_sources_path()

    current =
      case File.read(path) do
        {:ok, text} -> String.trim(text)
        _ -> nil
      end

    if current != digest do
      tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"
      File.write!(tmp, digest <> "\n")
      File.rename!(tmp, path)
    end

    :ok
  rescue
    _ -> :ok
  end

  # The pre-BUG-048 rule, kept verbatim for images built under it.
  defp legacy_codegen_beam_bytes do
    Enum.flat_map(@codegen_modules, fn mod ->
      # `:code.get_object_code/1` answers the module's bytes wherever the
      # code server found them — a real ebin OR an escript archive. Reading
      # `:code.which/1`'s path with `File.read` fails inside an escript (the
      # path is virtual), which silently dropped every codegen beam from the
      # key, so a packaged `bl` computed a DIFFERENT key from the build that
      # stamped its beams and treated its whole stdlib as stale — 80s boots
      # from source, or a refusal under BEAM_LISP_AOT_STRICT. Degrade (never
      # crash) when a module is genuinely absent.
      case :code.get_object_code(mod) do
        {^mod, bin, _path} -> [bin]
        _ -> []
      end
    end)
  end

  # Content of every tier-1 source: everything under `priv/boot/`, sorted by
  # path for determinism. The boot tier is closed under `:require` (the
  # compiler needs only `reader-node`; core/sugar/data-readers need nothing),
  # so hashing the DIRECTORY is the closure — no header parse, no graph walk,
  # nothing that could want the reader or Env this runs before. A missing boot
  # dir contributes nothing (degrade, never crash) — the missing compiler then
  # surfaces as a compile error downstream, not here.
  defp toolchain_source_contents do
    boot =
      BeamLisp.Tiers.boot_dir()
      |> Path.join("**/*.bl")
      |> Path.wildcard()

    # The bl-ANF vocabulary + lowering graduated to `priv/boot/` (anf.bl +
    # lower.bl, PLAN-086 E1) and are hashed by the boot glob above. What
    # remains in `priv/self/` is the interp oracle (self.anf) and the legacy
    # quoted lowering (self.core, dies in E5); while the quoted path still
    # serves, keep self/ tier-1 so an edit there invalidates all Core beams.
    # Under `:elixir` the self/ tier does not run, so it is left out (its
    # edits are then correctly irrelevant to the Elixir toolchain key).
    self =
      if aot_backend() == :core do
        BeamLisp.Tiers.priv_root()
        |> Path.join("self/**/*.bl")
        |> Path.wildcard()
      else
        []
      end

    (boot ++ self)
    |> Enum.sort()
    |> Enum.map(&File.read!/1)
  end

  # Prelude bodies remain toolchain inputs: macros and compiler helpers can
  # execute ordinary core functions while producing code. An interface-only
  # key is unsafe without tracking those transitive compile-time dependencies.

  @doc """
  Hash of one source's closure: its absolute path + content hash and those
  of every transitive `:require` target within the build's source set.

  `deps` maps source path → required source paths (as built by the compile
  task); `hashes` maps source path → content hash. Requires outside the
  source set (the core prelude) are covered by `compiler_key/0`.
  """
  def closure_key(path, deps, hashes) do
    closure = closure_walk(path, deps, MapSet.new()) |> Enum.sort()

    entries =
      Enum.map(closure, fn p -> "#{p}:#{Map.fetch!(hashes, p)}" end)

    hash_parts(entries)
  end

  defp closure_walk(path, deps, seen) do
    if MapSet.member?(seen, path) do
      seen
    else
      seen = MapSet.put(seen, path)
      Enum.reduce(Map.get(deps, path, []), seen, &closure_walk(&1, deps, &2))
    end
  end

  @doc """
  Link a cached entry's beams into `compile_path`. Returns
  `{:ok, modules}` when the entry existed and every beam materialised,
  `:miss` otherwise (absent entry, or any link/copy failure — the caller
  compiles instead).
  """
  def fetch(compiler_key, closure_key, compile_path) do
    entry = entry_dir(compiler_key, closure_key)

    with {:ok, modules} <- valid_entry(entry),
         :ok <- link_beams(entry, compile_path, modules) do
      {:ok, modules}
    else
      _ -> :miss
    end
  end

  @doc """
  Publish the beams for `modules` (already in `compile_path`) under the
  given keys. Atomic via temp-dir + rename; failures are ignored.
  """
  def store(compiler_key, closure_key, compile_path, modules) do
    final = entry_dir(compiler_key, closure_key)
    tmp = "#{final}.tmp-#{System.unique_integer([:positive])}"

    try do
      File.mkdir_p!(tmp)

      Enum.each(modules, fn mod ->
        File.cp!(Path.join(compile_path, beam_file(mod)), Path.join(tmp, beam_file(mod)))
      end)

      digests = Map.new(modules, fn mod ->
        {mod, Path.join(tmp, beam_file(mod)) |> File.read!() |> then(&:crypto.hash(:sha256, &1))}
      end)
      File.write!(Path.join(tmp, "manifest.term"),
        :erlang.term_to_binary(%{version: 2, modules: modules, digests: digests}))

      :global.trans({{@toolchain_key_pt, :publish, final}, self()}, fn ->
        case valid_entry(final) do
          {:ok, _} -> File.rm_rf!(tmp)
          :miss ->
            # Old or damaged cache entries are disposable, unlike source.
            File.rm_rf!(final)
            File.rename!(tmp, final)
        end
      end, [node()])

      maybe_cleanup_obsolete_generations(compiler_key)
      :ok
    rescue
      _ ->
        File.rm_rf(tmp)
        :ok
    end
  end

  defp valid_entry(entry) do
    with {:ok, binary} <- File.read(Path.join(entry, "manifest.term")),
         %{version: 2, modules: modules, digests: digests} <- safe_term(binary),
         true <- is_list(modules),
         true <- Enum.all?(modules, fn mod ->
           case File.read(Path.join(entry, beam_file(mod))) do
             {:ok, bytes} -> :crypto.hash(:sha256, bytes) == Map.get(digests, mod)
             _ -> false
           end
         end) do
      {:ok, modules}
    else
      _ -> :miss
    end
  rescue
    _ -> :miss
  end

  @doc """
  Remove obsolete compiler-key generations from the configured cache root.

  The active generation is always retained. Only real directories whose names
  are lowercase SHA-256 keys are candidates; symlinks and all other entries are
  ignored. Cleanup is bounded by `:max_delete` per call and is best-effort.

  Retention defaults can be overridden with
  `config :beam_lisp, :aot_cache_gc, keep_generations: 8, max_age_days: 30,
  max_delete: 4, interval_ms: 3_600_000`. Explicit options override config.
  """
  def cleanup_obsolete_generations(active_key, opts \\ []) when is_binary(active_key) do
    options = gc_options(opts)
    root = dir()

    with {:ok, entries} <- File.ls(root) do
      generations =
        entries
        |> Enum.filter(&valid_compiler_key?/1)
        |> Enum.reject(&(&1 == active_key))
        |> Enum.flat_map(&generation_info(root, &1))
        |> Enum.sort_by(& &1.mtime, :desc)

      now = System.os_time(:second)
      keep = max(options[:keep_generations] - 1, 0)
      age_limit = options[:max_age_days] * 86_400

      candidates =
        generations
        |> Enum.with_index()
        |> Enum.filter(fn {generation, index} ->
          index >= keep or now - generation.mtime > age_limit
        end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort_by(& &1.mtime)
        |> Enum.take(options[:max_delete])

      deleted =
        Enum.flat_map(candidates, fn generation ->
          case File.rm_rf(generation.path) do
            {:ok, _} -> [generation.name]
            {:error, _, _} -> []
          end
        end)

      {:ok, deleted}
    else
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:ok, []}
  end

  @doc false
  def reset_cleanup_throttle, do: :persistent_term.erase(@gc_last_sweep_pt)

  defp maybe_cleanup_obsolete_generations(active_key) do
    # Parallel build workers share one sweep budget. Recheck inside the lock
    # so a cold wave cannot multiply max_delete by its worker count.
    :global.trans({@gc_last_sweep_pt, self()}, fn ->
      options = gc_options([])
      now = System.monotonic_time(:millisecond)
      root = dir()
      last = :persistent_term.get(@gc_last_sweep_pt, nil)

      due? =
        case last do
          {^root, at} -> now - at >= options[:interval_ms]
          _ -> true
        end

      if due? do
        :persistent_term.put(@gc_last_sweep_pt, {root, now})
        cleanup_obsolete_generations(active_key, options)
      end
    end)

    :ok
  end

  defp gc_options(overrides) do
    configured = Application.get_env(:beam_lisp, :aot_cache_gc, [])

    @gc_defaults
    |> Keyword.merge(if(Keyword.keyword?(configured), do: configured, else: []))
    |> Keyword.merge(overrides)
    |> then(fn options ->
      [
        keep_generations:
          positive_integer(options[:keep_generations], @gc_defaults[:keep_generations]),
        max_age_days: positive_integer(options[:max_age_days], @gc_defaults[:max_age_days]),
        max_delete: positive_integer(options[:max_delete], @gc_defaults[:max_delete]),
        interval_ms: non_negative_integer(options[:interval_ms], @gc_defaults[:interval_ms])
      ]
    end)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp valid_compiler_key?(name), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, name)

  defp generation_info(root, name) do
    path = Path.join(root, name)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, mtime: mtime}} ->
        [%{name: name, path: path, mtime: mtime}]

      _ ->
        []
    end
  end

  # --- internals ---

  @doc """
  Reproduce a fresh compile's runtime side effects for a cache hit.

  Compiling a source evaluates its forms, which interns value defs into
  the live VM's `BeamLisp.Env`. A fetch links beams without evaluating,
  so same-VM consumers (tests calling a var the compile would have
  interned) see `undefined var` unless the namespace's init runs — the
  same hook a fresh-VM boot uses (`BeamLisp.AOT.ensure_loaded/1`).

  `__bl_init__/0` lives on the namespace SHIM module (`BeamLisp.Ns.<Ns>`);
  the companion `BeamLisp.Ns.Init.<Ns>` only holds `__bl_init_values__/0`,
  which the shim calls. Match on the export, not the name. Idempotent per
  the AOT contract.
  """
  def run_init_modules(modules, compile_path) do
    # Load EVERYTHING first: a shim's __bl_init__ calls its companion's
    # __bl_init_values__, so iteration order must not decide availability.
    Enum.each(modules, &ensure_module_loaded(&1, compile_path))

    for mod <- modules, function_exported?(mod, :__bl_init__, 0) do
      mod.__bl_init__()
    end

    :ok
  end

  defp ensure_module_loaded(mod, compile_path) do
    case Code.ensure_loaded(mod) do
      {:module, _} ->
        {:module, mod}

      {:error, _} ->
        beam = Path.join(compile_path, beam_file(mod))

        with {:ok, bin} <- File.read(beam) do
          :code.load_binary(mod, String.to_charlist(beam), bin)
        end
    end
  end

  defp entry_dir(compiler_key, closure_key) do
    unless Enum.all?([compiler_key, closure_key], &is_binary/1) and
             Enum.all?([compiler_key, closure_key], &Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, &1)),
      do: raise(ArgumentError, "cache keys must be safe path components")
    generation = Path.join(dir(), compiler_key)
    case File.lstat(generation) do
      {:ok, %{type: :symlink}} -> raise ArgumentError, "cache generation cannot be a symlink"
      _ -> Path.join(generation, closure_key)
    end
  end

  defp beam_file(mod), do: Atom.to_string(mod) <> ".beam"

  defp link_beams(entry, compile_path, modules) do
    File.mkdir_p!(compile_path)

    Enum.reduce_while(modules, :ok, fn mod, :ok ->
      src = Path.join(entry, beam_file(mod))
      dst = Path.join(compile_path, beam_file(mod))

      cond do
        not File.exists?(src) ->
          {:halt, :error}

        true ->
          File.rm(dst)

          case File.ln(src, dst) do
            # Hardlink first (same inode, no copy); across filesystems
            # (cache on /home, build on /tmp) fall back to a real copy.
            :ok -> {:cont, :ok}
            {:error, _} -> {:cont, copy(src, dst)}
          end
      end
    end)
  end

  defp copy(src, dst) do
    case File.cp(src, dst) do
      :ok -> :ok
      {:error, _} -> :error
    end
  end

  defp safe_term(bin) do
    # is_map-ok: cache manifest written by store/4 via term_to_binary;
    # never user input. A malformed entry degrades to a miss.
    case :erlang.binary_to_term(bin) do
      %{modules: mods} = term when is_list(mods) -> term
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp hash_parts(parts) do
    :crypto.hash(:sha256, IO.iodata_to_binary(Enum.intersperse(parts, 0)))
    |> Base.encode16(case: :lower)
  end
end
