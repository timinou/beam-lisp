# Canonical-only verification harness. BL_SEED_DIR can select a verified
# candidate floor without modifying the committed seed. No legacy host,
# quoted importer, or permissive collection adapter is installed.
Code.compiler_options(ignore_module_conflict: true, infer_signatures: false)
for path <- ["lib/beam_lisp/compiler_data.ex", "lib/beam_lisp/emit.ex",
             "lib/beam_lisp/link.ex", "lib/beam_lisp/compiler.ex",
             "lib/beam_lisp/record.ex", "lib/beam_lisp/native.ex",
             "lib/beam_lisp/aot.ex", "lib/beam_lisp/aot_cache.ex",
             "lib/beam_lisp/generation.ex", "lib/beam_lisp.ex",
             "lib/beam_lisp/dev_hotpatch.ex", "lib/beam_lisp/anf_interpreter.ex",
             "lib/beam_lisp/dev_change.ex"] do
  Code.compile_file(path)
end
seed = System.get_env("CANONICAL_SEED_DIR") || System.get_env("BL_SEED_DIR") || BeamLisp.Bootstrap.seed_dir()
nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
stage = Path.join(System.tmp_dir!(), "bl_canonical_stage_#{nonce}")
File.mkdir!(stage)
System.at_exit(fn _ -> File.rm_rf!(stage) end)
Process.put(:canonical_upgrade_cleanup, [stage])
Code.prepend_path(stage)
BeamLisp.AOTCache.reset_compiler_key()
BeamLisp.Bootstrap.install!(stage, seed_dir: seed)
{:ok, _} = Application.ensure_all_started(:beam_lisp)
BeamLisp.init()
%{op: _} = BeamLisp.Compiler.compile(BeamLisp.Reader.read_one("nil"), BeamLisp.Compiler.new_env("canonical-proof"))
IO.puts("CANONICAL_FLOOR: #{seed}")

case System.get_env("CANONICAL_HOTPATCH") do
  nil -> :ok
  "" -> :ok
  names -> BeamLisp.DevHotpatch.hotpatch!(names)
end
IO.inspect(BeamLisp.Generation.receipt(), label: "GENERATION_RECEIPT", limit: :infinity)

if System.get_env("PROFILE_CANONICAL_COMPILER") == "1" do
  Code.require_file("!tasks/artifacts/compiler-retention-probe.exs")
  CompilerRetentionProbe.run(:eager)
end

case System.get_env("CANONICAL_ACTION") do
  "seed" -> Code.require_file("!tasks/artifacts/canonical-seed-stage.exs")
  "docs" -> Code.require_file("!tasks/artifacts/docs-gate.exs")
  "research" -> Code.require_file("!tasks/artifacts/research-gate.exs")
  _ -> :ok
end

ExUnit.start(autorun: false)
extra_exunit = String.split(System.get_env("CANONICAL_EXTRA_EXUNIT", ""), ",", trim: true)
for path <- extra_exunit ++ ["test/beam_lisp/generation_semantics_test.exs",
                            "test/beam_lisp/anf_emit_test.exs",
                            "test/beam_lisp/direct_forms_test.exs",
                            "test/beam_lisp/wave24_records_test.exs",
                            "test/beam_lisp/native_test.exs"] do
  Code.require_file(path)
end
result = ExUnit.run()
IO.inspect(result, label: "CANONICAL_TEST_RESULT")
extra_bl = String.split(System.get_env("CANONICAL_EXTRA_BL", ""), ",", trim: true)
BeamLisp.run_file("priv/self/anf.bl")
module_result = BeamLisp.TestRT.run_suite(["test/bl/core_aot_test.bl" | extra_bl])
IO.inspect(module_result, label: "MODULE_CONTRACT_RESULT", limit: :infinity)
Enum.each(Process.get(:canonical_upgrade_cleanup, []), &File.rm_rf!/1)
System.halt(if result.failures == 0 and BeamLisp.TestRT.passed?(module_result), do: 0, else: 1)
