# Regenerate priv/bootstrap/seed/manifest.exs from the beams currently in
# priv/bootstrap/seed/.
#
# Run AFTER you have (1) rebuilt the compiler-closure beams under the current
# compiler_key and (2) copied them into priv/bootstrap/seed/. Usage:
#
#     mix run priv/bootstrap/gen_manifest.exs
#
# The manifest records the compiler_key the seed was built under, the
# Elixir/OTP versions, and a sha256 per beam — everything the installer
# (Mix.Tasks.Compile.BeamLisp) needs to verify the committed seed is intact and
# admissible before it is copied into the build's ebin.
seed_dir = "priv/bootstrap/seed"

files = seed_dir |> Path.join("*.beam") |> Path.wildcard() |> Enum.sort()

if files == [] do
  Mix.raise("no beams in #{seed_dir} — build + copy the compiler closure first")
end

entries =
  Map.new(files, fn f ->
    {Path.basename(f), :crypto.hash(:sha256, File.read!(f)) |> Base.encode16(case: :lower)}
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
    "# Regenerate: mix run priv/bootstrap/gen_manifest.exs (after a keyed rebuild).\n" <>
    inspect(manifest, pretty: true, limit: :infinity) <> "\n"

File.write!(Path.join(seed_dir, "manifest.exs"), content)

IO.puts(
  "wrote #{seed_dir}/manifest.exs: key=#{String.slice(manifest["compiler_key"], 0, 16)}… " <>
    "modules=#{map_size(entries)}"
)
