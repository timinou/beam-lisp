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

seed_dir = "priv/bootstrap/seed"
ebin = Mix.Project.compile_path()
File.mkdir_p!(seed_dir)

# The bootstrap floor is the WHOLE boot tier: every namespace under
# `priv/boot/` — the self-hosting toolchain (compiler, reader, reader-node),
# the language prelude the compiler resolves its vars against (core, multi via
# init, sugar), the tagged-literal registry (data-readers), AND the build
# system + drift-gate namespaces (build, build-plan, source-graph,
# ns-interface) that the loader's freshness check itself runs on. Seeding this
# closed set is what breaks EVERY bootstrap loop: a genesis-less tree loads the
# entire toolchain from these committed Core-Erlang beams (no compile), then
# rebuilds itself. `priv/boot/` is already the tier-1 toolchain key input, so it
# is the principled, self-consistent floor. `multi` is not a boot file (it is a
# prelude layer loaded by init) but the compiler needs it too, so include it.
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
  "schema" => "beam-lisp-bootstrap-seed-v1",
  "compiler_key" => BeamLisp.AOTCache.compiler_key(),
  "elixir" => System.version(),
  "otp" => List.to_string(:erlang.system_info(:otp_release)),
  "modules" => entries
}

content =
  "# beam-lisp bootstrap seed manifest — generated, do not edit by hand.\n" <>
    "# Regenerate: mix run priv/bootstrap/gen_manifest.exs (after a keyed build).\n" <>
    inspect(manifest, pretty: true, limit: :infinity) <> "\n"

File.write!(Path.join(seed_dir, "manifest.exs"), content)

IO.puts(
  "wrote #{seed_dir}: key=#{String.slice(manifest["compiler_key"], 0, 16)}… " <>
    "modules=#{map_size(entries)} (#{Enum.join(closure_ns, ", ")})"
)
