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
      Elixir and OTP versions, the contents of the codegen modules' beams
      (AOT/Emit/Link/Ns/Reader/AtomGuard/Native — NOT the Compiler
      orchestration module, whose bytes no longer affect emitted code) and
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
  @codegen_modules [
    BeamLisp.AOT,
    BeamLisp.AtomGuard,
    BeamLisp.Emit,
    BeamLisp.Link,
    BeamLisp.Native,
    BeamLisp.Ns,
    BeamLisp.Reader
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

  @doc false
  # Drop the memoized toolchain key so the next `compiler_key/0` recomputes it.
  # The key is a VM-constant in normal use (codegen beams + tier-1 sources do
  # not change under a running node), so this exists only for tests that mutate
  # a hashed input in-process and must observe the new key.
  def reset_compiler_key, do: :persistent_term.erase(@toolchain_key_pt)

  defp compute_compiler_key do
    vsn =
      case :application.get_key(:beam_lisp, :vsn) do
        {:ok, v} -> List.to_string(v)
        _ -> "unknown"
      end

    parts = [
      "beam_lisp:#{vsn}",
      "elixir:#{System.version()}",
      "otp:#{:erlang.system_info(:otp_release)}"
    ]

    beams =
      Enum.flat_map(@codegen_modules, fn mod ->
        case :code.which(mod) do
          path when is_list(path) ->
            # An escript's :code.which/1 reports a VIRTUAL archive path
            # (`<script>/<app>/ebin/M.beam`) that no filesystem backs —
            # same shape as the missing-priv_dir fallback below. Degrade
            # the key instead of crashing the compile.
            case File.read(path) do
              {:ok, bin} -> [bin]
              _ -> []
            end

          _ ->
            []
        end
      end)

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

    hash_parts(parts ++ beams ++ toolchain_sources)
  end

  # Content of every tier-1 source: everything under `priv/boot/`, sorted by
  # path for determinism. The boot tier is closed under `:require` (the
  # compiler needs only `reader-node`; core/sugar/data-readers need nothing),
  # so hashing the DIRECTORY is the closure — no header parse, no graph walk,
  # nothing that could want the reader or Env this runs before. A missing boot
  # dir contributes nothing (degrade, never crash) — the missing compiler then
  # surfaces as a compile error downstream, not here.
  defp toolchain_source_contents do
    BeamLisp.Tiers.boot_dir()
    |> Path.join("**/*.bl")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&File.read!/1)
  end

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

    with true <- File.dir?(entry),
         {:ok, bin} <- File.read(Path.join(entry, "manifest.term")),
         %{modules: modules} <- safe_term(bin),
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

      File.write!(Path.join(tmp, "manifest.term"), :erlang.term_to_binary(%{modules: modules}))

      if File.dir?(final) do
        File.rm_rf!(tmp)
      else
        File.rename(tmp, final)
      end

      :ok
    rescue
      _ ->
        File.rm_rf(tmp)
        :ok
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

  defp entry_dir(compiler_key, closure_key), do: Path.join([dir(), compiler_key, closure_key])

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
    :crypto.hash(:sha256, IO.iodata_to_binary(Enum.intersperse(parts, 0))) |> Base.encode16(case: :lower)
  end
end
