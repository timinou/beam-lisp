# Regenerate priv/bootstrap/seed/ (beams + manifest) from the current _build.
#
# The seed is the checked-in, Core-Erlang-built bootstrap floor: the compiled
# beam closure of the BOOT PRELUDE the self-hosted compiler needs to RUN, so a
# genesis-less tree loads it from bytes (no compile) and then rebuilds itself.
#
# Run AFTER a keyed build (mix compile.beam_lisp) so _build holds current beams:
#
#     mix run priv/bootstrap/gen_manifest.exs
#
# It copies the boot-closure beams out of _build into priv/bootstrap/seed/,
# writes a manifest recording the compiler_key they were built under, the
# Elixir/OTP versions, and a sha256 per beam, and reports what it wrote.

seed_dir = System.get_env("BL_SEED_DIR", "priv/bootstrap/seed")
ebin = System.get_env("BL_SEED_EBIN") || Mix.Project.compile_path()
File.mkdir_p!(seed_dir)

# The bootstrap floor is the CODEGEN tier: every namespace under `priv/boot/` —
# the self-hosting toolchain (compiler, reader, reader-node), the ambient
# prelude the compiler resolves its vars against (core, sugar), the
# tagged-literal registry (data-readers), and the Core-Erlang backend
# (anf, lower). Seeding this closed set is what breaks EVERY bootstrap loop: a
# genesis-less tree loads the entire COMPILER from these committed
# Core-Erlang beams (no compile), and then compiles everything else with it.
#
# The BUILD DRIVER (`priv/build/`) is deliberately NOT seeded. Codegen floored
# from a previous generation is a bootstrap (gen-N compiles gen-N+1); a driver
# floored from a previous generation is a MIXED TOOLCHAIN — the caller
# (`mix compile.beam_lisp` → `build/run`) depends on the current contract, and
# staged driver bytes would silently outlive the source they were written from.
# The driver is read or compiled from the current tree, always. `multi` is not
# a tier file (it is a prelude layer loaded by init) but the compiler needs it
# too, so include it.
boot_ns =
  "priv/boot/*.bl"
  |> Path.wildcard()
  |> Enum.map(&(Path.basename(&1, ".bl") |> Macro.camelize()))

closure_ns = (boot_ns ++ ["Multi"]) |> Enum.uniq()
variants = fn ns -> ["Ns.#{ns}", "Ns.Body.#{ns}", "Ns.Init.#{ns}"] end

wanted =
  closure_ns
  |> Enum.flat_map(variants)
  |> Enum.map(&"Elixir.BeamLisp.#{&1}.beam")
  |> Enum.filter(&File.exists?(Path.join(ebin, &1)))

if wanted == [] do
  Mix.raise("no boot-closure beams in #{ebin} — run mix compile.beam_lisp first")
end

# A seed whose manifest key and beam stamps disagree is a LIE that crashes
# genesis-less boots circularly: the drift gate reads each beam's provenance
# key, finds it != compiler_key, routes `reader` to the source path — which
# needs the reader. Copied beams must therefore be PROVEN built under the
# current key, not assumed: `_build` can hold older-keyed beams (e.g. after a
# failed compile left a stale ebin). Refuse loudly instead.
# TWO keys, because the seed spans both toolchain tiers: codegen beams carry
# `compiler_key`; the build driver carries `build_key`.
compiler_key = BeamLisp.AOTCache.current_compiler_key()
build_key = BeamLisp.AOTCache.current_build_key()

# Only the top-level Ns.<Name> shims carry `__bl_provenance__/0`; Body/Init
# companions are unchecked (they share the shim's build by construction).
shim_beams = Enum.filter(wanted, fn name ->
  base = Path.basename(name, ".beam")
  not (String.contains?(base, ".Body.") or String.contains?(base, ".Init."))
end)

ns_of = fn name ->
  name
  |> Path.basename(".beam")
  |> String.replace_prefix("Elixir.BeamLisp.Ns.", "")
  |> String.split("-")
  |> Enum.map_join("-", &Macro.underscore/1)
end

Enum.each(shim_beams, fn name ->
  path = Path.join(ebin, name)
  mod = name |> Path.basename(".beam") |> String.to_atom()
  :code.purge(mod)
  :code.delete(mod)
  {:module, _} = :code.load_binary(mod, ~c"gen_manifest", File.read!(path))

  # The stamp is the beam's TIER key: `build_key` for the driver, `compiler_key`
  # for codegen. The same routing the emitter uses (`AOTCache.key_for_ns/1`), so
  # a beam's stamp and this check cannot disagree about which tier it is in.
  expected = if BeamLisp.Tiers.tier_of_ns(ns_of.(name)) == :build, do: build_key, else: compiler_key

  case mod.__bl_provenance__() do
    {_src, ^expected} ->
      :ok

    {_src, beam_key} ->
      Mix.raise("""
      refusing to seed a stale beam: #{name}
        beam provenance key: #{String.slice(beam_key, 0, 16)}…
        expected tier key:   #{String.slice(expected, 0, 16)}…
      The ebin beams were built under a different toolchain. Rebuild first:
        mix clean && mix compile   then re-run gen_manifest.
      """)
  end
end)

# Clear stale seed beams, then copy the current closure in.
seed_dir |> Path.join("*.beam") |> Path.wildcard() |> Enum.each(&File.rm!/1)

Enum.each(wanted, fn name ->
  File.cp!(Path.join(ebin, name), Path.join(seed_dir, name))
end)

entries =
  Map.new(wanted, fn name ->
    {name, :crypto.hash(:sha256, File.read!(Path.join(seed_dir, name))) |> Base.encode16(case: :lower)}
  end)

manifest = %{
  "schema" => "beam-lisp-bootstrap-seed-v2",
  "compiler_key" => compiler_key,
  "build_key" => build_key,
  "elixir" => System.version(),
  "otp" => List.to_string(:erlang.system_info(:otp_release)),
  "modules" => entries
}

content =
  "# beam-lisp bootstrap seed manifest — generated, do not edit by hand.\n" <>
    "# Regenerate: mix run priv/bootstrap/gen_manifest.exs (after a keyed build).\n" <>
    inspect(manifest, pretty: true, limit: :infinity) <> "\n"

if BeamLisp.AOTCache.current_compiler_key() != compiler_key or
     BeamLisp.AOTCache.current_build_key() != build_key do
  Mix.raise("toolchain sources changed during seed assembly; refusing to publish its manifest")
end

File.write!(Path.join(seed_dir, "manifest.exs"), content)

IO.puts(
  "wrote #{seed_dir}: codegen=#{String.slice(compiler_key, 0, 12)}… " <>
    "driver=#{String.slice(build_key, 0, 12)}… " <>
    "modules=#{map_size(entries)} (#{Enum.join(closure_ns, ", ")})"
)
