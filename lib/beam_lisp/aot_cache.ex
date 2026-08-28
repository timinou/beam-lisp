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

    * `compiler_key/0` — the toolchain: beam_lisp's version, Elixir and
      OTP versions, the contents of the codegen modules' beams
      (Compiler/AOT/Emit/Link/Ns/Reader/AtomGuard/Native) and of
      beam_lisp's own `priv/**/*.bl` (the core prelude is evaluated
      against every compile).
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

  @codegen_modules [
    BeamLisp.AOT,
    BeamLisp.AtomGuard,
    BeamLisp.Compiler,
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
          path when is_list(path) -> [File.read!(path)]
          _ -> []
        end
      end)

    prelude =
      case :code.priv_dir(:beam_lisp) do
        dir when is_list(dir) ->
          dir |> Path.join("**/*.bl") |> Path.wildcard() |> Enum.sort() |> Enum.map(&File.read!/1)

        _ ->
          []
      end

    hash_parts(parts ++ beams ++ prelude)
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
