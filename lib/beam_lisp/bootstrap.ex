defmodule BeamLisp.Bootstrap do
  @moduledoc """
  Installs the committed self-hosted-compiler seed into a build's code path.

  beam-lisp's compiler is written in beam-lisp (`priv/compiler.bl`) and there is
  no longer an Elixir genesis compiler to fall back on. So a fresh clone must
  boot the compiler from a PRE-BUILT artifact: the AOT-compiled closure of the
  `compiler` and `reader-node` namespaces, committed under
  `priv/bootstrap/seed/` with a manifest.

  This module copies that seed into the build's `ebin` BEFORE `BeamLisp.init/0`
  runs, so `enable_bl_backend/0` finds `BeamLisp.Ns.Compiler` on the code path
  and interns it from the beam (no compile, no genesis). The install is:

    * VERIFIED   — every beam's sha256 must match the manifest, and the
      manifest's `compiler_key` must match this toolchain's key. A mismatch
      is a hard, actionable error, never a silent boot into a broken state.
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

    verify_key!(manifest)

    Enum.each(manifest["modules"], fn {name, want_sha} ->
      src = Path.join(seed_dir, name)
      verify_seed_file!(src, name, want_sha)
      install_one(src, Path.join(ebin, name), want_sha)
    end)

    :ok
  end

  @doc "Absolute path to the committed seed directory (best-effort, dev + release)."
  def seed_dir do
    case :code.priv_dir(:beam_lisp) do
      dir when is_list(dir) -> Path.join(to_string(dir), @seed_dir_rel)
      _ -> Path.join(["priv", @seed_dir_rel])
    end
  end

  # A seed built for a different toolchain (Elixir/OTP, or a real compiler
  # change) cannot be trusted to produce correct code here. Fail loud: the fix
  # is to rebuild the seed on this toolchain, not to boot on a foreign one.
  defp verify_key!(manifest) do
    want = manifest["compiler_key"]
    have = BeamLisp.AOTCache.compiler_key()

    unless want == have do
      raise """
      beam-lisp bootstrap seed was built for a different toolchain.

        seed compiler_key: #{want}
        this  compiler_key: #{have}
        seed elixir/otp:   #{manifest["elixir"]} / #{manifest["otp"]}
        this elixir/otp:   #{System.version()} / #{:erlang.system_info(:otp_release)}

      The committed seed is pinned to the toolchain it was built on. Rebuild the
      seed on this toolchain (mix run priv/bootstrap/gen_manifest.exs after a
      keyed build), or build on the pinned Elixir/OTP.
      """
    end
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
