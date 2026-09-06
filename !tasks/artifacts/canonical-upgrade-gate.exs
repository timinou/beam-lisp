# Temporary old-seed upgrade driver. No seed or application source is written.
# Run via mix run --no-compile --no-start under a memory-capped scope.
Application.put_env(:beam_lisp, :lazy_cache_budget_bytes, 3 * 1024 * 1024 * 1024)

# The preceding host is only a bootstrap importer. Load it explicitly so this
# proof does not depend on whichever host generation happens to be in _build.
for path <- ["lib/beam_lisp/emit.ex", "lib/beam_lisp/link.ex", "lib/beam_lisp/compiler.ex", "lib/beam_lisp/aot.ex"] do
  {source, 0} = System.cmd("git", ["show", "440fb3b:" <> path])
  Code.compile_string(source, path)
end

# A populated _build may hold a newer coherent generation, which install!/1
# correctly preserves. This gate specifically proves the committed old seed
# can upgrade, so stage it into a fresh directory rather than mixed cached code.
stage = Path.join(System.tmp_dir!(), "bl_upgrade_seed_#{System.unique_integer([:positive])}")
File.mkdir_p!(stage)
System.at_exit(fn _ -> File.rm_rf!(stage) end)
Code.prepend_path(stage)
BeamLisp.Bootstrap.install!(stage)
{:ok, _} = Application.ensure_all_started(:beam_lisp)
IO.puts("UPGRADE: previous seed and explicit previous host loaded")

# Install the canonical consumer before changing the producer representation.
BeamLisp.DevHotpatch.hotpatch!(["anf", "lower"])
IO.puts("UPGRADE: canonical module consumer ready")

# Evaluate source through the old host's live definition route, not its quoted
# AOT module writer. It can install new clause data through the imported lowerer.
BeamLisp.run_file("priv/boot/compiler2.bl")
BeamLisp.run_file("priv/boot/compiler.bl")
apply(BeamLisp.Ns.Lower, :"normalize-generation-defs!", [])
IO.puts("UPGRADE: direct producer ready; definition store canonicalized")

for path <- ["lib/beam_lisp/emit.ex", "lib/beam_lisp/link.ex", "lib/beam_lisp/aot.ex", "lib/beam_lisp/compiler.ex", "lib/beam_lisp/record.ex", "lib/beam_lisp/native.ex"] do
  Code.compile_file(path)
end
IO.puts("UPGRADE: canonical host consumers loaded")

BeamLisp.DevHotpatch.hotpatch!(["compiler2", "compiler", "anf", "lower"])
IO.puts("UPGRADE: complete canonical generation emitted")
IO.inspect(BeamLisp.Generation.receipt(), label: "GENERATION_RECEIPT", limit: :infinity)

ExUnit.start()
for path <- ["test/beam_lisp/generation_semantics_test.exs", "test/beam_lisp/anf_emit_test.exs", "test/beam_lisp/direct_forms_test.exs", "test/beam_lisp/wave24_records_test.exs", "test/beam_lisp/native_test.exs"] do
  Code.require_file(path)
end
result = ExUnit.run()
IO.inspect(result, label: "CANONICAL_TEST_RESULT")
module_result = BeamLisp.TestRT.run_suite(["test/bl/core_aot_test.bl"])
IO.inspect(module_result, label: "MODULE_CONTRACT_RESULT", limit: :infinity)
System.halt(if result.failures == 0 and BeamLisp.TestRT.passed?(module_result), do: 0, else: 1)
