# research/selfbuild/gen1.exs — build generation 1: the release tree, then a
# compound sealed with the STOCK Rust launcher. This is the last artefact the
# Rust tooling produces; every generation after it comes from `bl self-build`.
#
# Run: mix run research/selfbuild/gen1.exs

BeamLisp.init()
BeamLisp.Loader.ensure_loaded("release")
BeamLisp.Loader.ensure_loaded("drop")

tree = System.get_env("BL_TREE") || "/tmp/beam_lisp_release_tree"
out = System.get_env("BL_OUT") || "/tmp/bl-gen1"
launcher = System.get_env("BL_LAUNCHER") || "/home/user/.cache/cargo-target/release/drop-launcher"

value = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("release", "value"), [:beam_lisp])
a = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("release", "assemble"), [value, tree])
IO.puts("assemble: ok?=#{a[:ok?]} apps=#{a[:apps]} errors=#{inspect(a[:errors])}")

p = BeamLisp.Drop.pack(tree, launcher, out)
IO.puts("pack:     ok?=#{p[:ok?]} out=#{out} offset=#{p[:offset]} len=#{p[:len]}")

v = BeamLisp.Drop.verify(out)
IO.puts("verify:   ok?=#{v.ok?} arithmetic=#{v.arithmetic}")

size = File.stat!(out).size
IO.puts("gen1:     #{size} bytes")
