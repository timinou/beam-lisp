defmodule BeamLisp.Bootstrap do
  @moduledoc """
  Installs the committed self-hosted-compiler seed into a build's code path.

  beam-lisp's compiler is written in beam-lisp (`priv/boot/compiler.bl`) and there is
  no longer an Elixir genesis compiler to fall back on. So a fresh clone must
  boot the compiler from a PRE-BUILT artifact: the AOT-compiled closure of the
  `compiler` and `reader-node` namespaces, committed under
  `priv/bootstrap/seed/` with a manifest.

  This module copies that seed into the build's `ebin` BEFORE `BeamLisp.init/0`
  runs, so `enable_bl_backend/0` finds `BeamLisp.Ns.Compiler` on the code path
  and interns it from the beam (no compile, no genesis). The install is:

    * VERIFIED   — every beam's sha256 must match the manifest (a corrupt seed
      is fatal). The manifest's `compiler_key` is advisory: a MATCH means the
      seed beams are the finished, byte-identical compiler; a MISMATCH means the
      seed is a valid PREVIOUS-generation compiler, staged to bootstrap the
      rebuild (self-hosting: gen-N compiles gen-N+1). Either way the seed is
      installed — there is no Elixir genesis behind it.
    * REPAIRING  — it runs on every build and overwrites a missing or drifted
      copy, so a half-populated `ebin` self-heals.
    * ATOMIC-ish — each beam is written to a temp name and renamed into place.

  Once the build has compiled its own `.bl` sources (which re-emits the compiler
  beam under the current key), the copied seed and the freshly built beam are
  byte-identical for this toolchain, so the seed is simply the floor the first
  build stands on.
  """

  @seed_dir_rel "bootstrap/seed"
  @manifest_name "manifest.exs"

  @doc """
  Ensure the compiler seed is present and valid in `compile_path`'s ebin.

  Returns `:ok` when the seed is installed (or already current), or raises with
  an actionable message when the committed seed is missing, corrupt, or was
  built for a different toolchain. Best-effort only insofar as a NON-fresh build
  (one whose compiler beam already matches) is a cheap no-op; it never silently
  proceeds past a real mismatch, because there is no genesis fallback behind it.
  """
  def install!(compile_path) do
    seed_dir = seed_dir()

    manifest_path = Path.join(seed_dir, @manifest_name)

    unless File.exists?(manifest_path) do
      raise """
      beam-lisp bootstrap seed is missing: #{manifest_path} not found.

      The self-hosted compiler boots from a committed seed (the AOT-compiled
      `compiler`/`reader-node` closure). Without it there is no compiler to
      build the sources. If you are developing beam-lisp itself, rebuild and
      commit the seed (mix run priv/bootstrap/gen_manifest.exs after a keyed
      build); otherwise your checkout is incomplete.
      """
    end

    manifest = read_manifest!(manifest_path)
    ebin = to_string(compile_path)
    File.mkdir_p!(ebin)

    # The seed is a bootstrap FLOOR, not a mandate. Install it only when its
    # `compiler_key` matches this toolchain: a matching seed is a pre-built,
    # trustworthy `compiler` beam that lets a genesis-less tree boot with no
    # source compile. A MISMATCH (a different Elixir/OTP, or — as during active
    # development — a change to a hashed input since the seed was frozen) means
    # the committed beams would produce or intern the wrong code, so we do NOT
    # install them. We skip instead of raising: while the genesis seed still
    # exists, `compile.beam_lisp` rebuilds fresh, correctly-keyed `.bl` beams
    # from source, so a stale committed seed is simply unused, not fatal. When
    # genesis is finally deleted the seed becomes load-bearing and a mismatch
    # surfaces at compile time as a clear "compiler seed not loaded" error whose
    # fix is to regenerate the seed on this toolchain. Returns `:ok` when the
    # seed matched (finished compiler), `{:staged, reason}` when it was installed
    # as a previous-generation bootstrap stage for the rebuild.
    matches? = key_matches?(manifest)

    # ALWAYS install the committed seed beams — on a match AND on a mismatch.
    #
    # A MATCH means the seed beams are byte-identical to what this toolchain
    # produces, so they are the finished compiler: install and you are done.
    #
    # A MISMATCH (active development: compiler.bl or another hashed input changed
    # since the seed was frozen) does NOT mean the seed is unusable — it is still
    # a WORKING compiler of the PREVIOUS generation, and a self-hosted compiler
    # is bootstrapped by the previous generation of itself. So we STAGE it: the
    # gen-N seed is installed, boot interns it, and `compile.beam_lisp` uses it to
    # rebuild the whole tree — including a fresh, correctly-keyed gen-N+1 compiler
    # — from source. `stale?/2` (aot.ex) then sees the freshly built beams carry
    # the current key and serves them; the staged seed beams for `compiler`/
    # `reader` are overwritten by the rebuild. No Elixir genesis is needed on
    # EITHER path — the seed is the floor the tower stands on.
    #
    # Integrity (sha256) is verified regardless: a corrupt seed is fatal, a
    # merely-differently-keyed one is a valid bootstrap stage.
    Enum.each(manifest["modules"], fn {name, want_sha} ->
      src = Path.join(seed_dir, name)
      verify_seed_file!(src, name, want_sha)
      install_one(src, Path.join(ebin, name), want_sha)
    end)

    # Make the code server SEE the just-installed beams immediately. The build
    # boots in THIS VM; a module the code server already resolved to
    # `:non_existing` (before the seed was copied) stays cached as missing until
    # explicitly (re)loaded, so `AOT.ensure_loaded/1` would rule the fresh seed
    # beam absent and fall to the SOURCE path — which, with genesis gone, cannot
    # compile it. Purge + load each installed module so the freshly written
    # bytes are the live code before the first `ensure_loaded`.
    Enum.each(manifest["modules"], fn {name, _sha} ->
      mod = name |> Path.basename(".beam") |> String.to_atom()
      beam_path = Path.join(ebin, name)
      :code.purge(mod)
      :code.load_binary(mod, String.to_charlist(beam_path), File.read!(beam_path))
    end)

    if matches? do
      # A matching seed is the finished compiler; no staging trust needed.
      Application.delete_env(:beam_lisp, :bootstrap_staging)
      :ok
    else
      # A mismatched seed was installed as a PREVIOUS-generation bootstrap
      # stage. Record the namespaces it provides so the AOT drift gate trusts
      # THOSE staged beams for interning (they are a valid compiler; their
      # bytes need not match the current source — interning replays def VALUES,
      # it does not recompile). The rebuild then produces fresh, correctly-keyed
      # beams that supersede them, and the flag is cleared on the next matching
      # install. Without this, the gate would rule the staged seed stale, route
      # `compiler`/`reader-node` to the SOURCE path, and — with genesis gone —
      # have nothing to compile them with.
      staged_ns =
        manifest["modules"]
        |> Map.keys()
        |> Enum.map(&seed_module_to_ns/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      Application.put_env(:beam_lisp, :bootstrap_staging, staged_ns)
      {:staged, :compiler_key_mismatch}
    end
  end

  # Map a committed seed beam filename to the beam-lisp namespace it provides,
  # or nil for a companion module (Body.*/Init.*) that is not a namespace of
  # its own. `Elixir.BeamLisp.Ns.Compiler.beam` -> "compiler";
  # `Elixir.BeamLisp.Ns.Reader-node.beam` -> "reader-node". Only the top-level
  # `BeamLisp.Ns.<Name>` shims name a namespace; the drift gate keys on those.
  defp seed_module_to_ns(filename) do
    base = Path.basename(filename, ".beam")

    case base do
      "Elixir.BeamLisp.Ns." <> rest ->
        if String.contains?(rest, ".") do
          # Body.Compiler / Init.Compiler — companion module, not a namespace.
          nil
        else
          # `Compiler` -> "compiler"; `Reader-node` -> "reader-node". Underscore
          # each hyphen-separated CamelCase segment, then rejoin with hyphens,
          # so a compound namespace segment keeps its `-`.
          rest
          |> String.split("-")
          |> Enum.map_join("-", &Macro.underscore/1)
        end

      _ ->
        nil
    end
  end

  @doc "Absolute path to the committed seed directory (best-effort, dev + release)."
  def seed_dir do
    case :code.priv_dir(:beam_lisp) do
      dir when is_list(dir) -> Path.join(to_string(dir), @seed_dir_rel)
      _ -> Path.join(["priv", @seed_dir_rel])
    end
  end

  # Whether the committed seed's `compiler_key` matches this toolchain's. A seed
  # built for a different key cannot be trusted to intern correct code here, so
  # the installer skips it rather than seeding a foreign beam. (The genesis path,
  # while it exists, rebuilds fresh beams regardless; see `install!/1`.)
  defp key_matches?(manifest) do
    manifest["compiler_key"] == BeamLisp.AOTCache.compiler_key()
  end

  defp verify_seed_file!(src, name, want_sha) do
    unless File.exists?(src) do
      raise "beam-lisp bootstrap seed is incomplete: #{name} missing from #{seed_dir()}"
    end

    got = sha256(File.read!(src))

    unless got == want_sha do
      raise """
      beam-lisp bootstrap seed is corrupt: #{name} checksum mismatch.
        manifest: #{want_sha}
        on disk:  #{got}
      """
    end
  end

  # Copy the seed beam into ebin only when the destination is absent or drifted,
  # so a warm build does no work. Write-then-rename keeps a reader from ever
  # seeing a half-written beam.
  defp install_one(src, dst, want_sha) do
    current =
      case File.read(dst) do
        {:ok, bytes} -> sha256(bytes)
        _ -> nil
      end

    unless current == want_sha do
      tmp = dst <> ".tmp-#{:erlang.unique_integer([:positive])}"
      File.cp!(src, tmp)
      File.rename!(tmp, dst)
    end
  end

  defp read_manifest!(path) do
    {manifest, _binding} = Code.eval_file(path)
    manifest
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
