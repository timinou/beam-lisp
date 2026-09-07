# Postlude for canonical-upgrade-gate.exs with CANONICAL_ACTION=seed.
# Build a candidate floor without modifying the committed seed.
output = System.fetch_env!("BL_SEED_EBIN") |> Path.expand()
seed = System.fetch_env!("BL_SEED_DIR") |> Path.expand()
File.mkdir_p!(output)
File.mkdir_p!(seed)
Code.compile_file("lib/beam_lisp/aot_cache.ex")
BeamLisp.AOTCache.reset_compiler_key()

priority = ~w(core sugar reader-node reader anf lower compiler)
boot = Path.wildcard("priv/boot/*.bl")
files = Enum.sort_by(boot, fn path ->
  ns = Path.basename(path, ".bl")
  {Enum.find_index(priority, &(&1 == ns)) || 100, ns}
end) ++ ["priv/std/multi.bl"]

for path <- files do
  ns = Path.basename(path, ".bl")
  before = BeamLisp.Env.ns_defs(ns)
  BeamLisp.AOT.compile_file(path, output_dir: output)
  after_compile = BeamLisp.Env.ns_defs(ns)
  # Every executed definition receives a fresh immutable body module. This
  # identifies declarations from this complete boot namespace, including
  # macro-generated definitions, without guessing from surface syntax.
  owned = Map.filter(after_compile, fn {name, entries} -> Map.get(before, name) != entries end)
  BeamLisp.Env.put_ns_defs(ns, owned)
  emitted = BeamLisp.AOT.compile_file(path, output_dir: output)
  IO.inspect(%{namespace: ns, definitions: map_size(owned), artifacts: length(emitted)}, label: "SEED_NAMESPACE")
end

System.put_env("BL_SEED_EBIN", output)
System.put_env("BL_SEED_DIR", seed)
Code.require_file("priv/bootstrap/gen_manifest.exs")
IO.inspect(BeamLisp.Generation.receipt(), label: "CANDIDATE_SEED_GENERATION", limit: :infinity)
IO.puts("CANDIDATE_SEED: #{seed}")
Enum.each(Process.get(:canonical_upgrade_cleanup, []), &File.rm_rf!/1)
System.halt(0)
