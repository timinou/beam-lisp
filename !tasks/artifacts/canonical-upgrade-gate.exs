# Temporary old-seed upgrade driver. No seed or application source is written.
# Run via mix run --no-compile --no-start under a memory-capped scope.
Application.put_env(:beam_lisp, :lazy_cache_budget_bytes, 3 * 1024 * 1024 * 1024)
# Old compiler bodies can still produce lazy intermediates while the new
# namespace is being installed. Keep that adaptation only in this old-seed
# upgrade driver; the production helper is strict and replaces it below.
helper_source = File.read!("lib/beam_lisp/compiler_data.ex")
legacy_helper = String.replace(helper_source,
  "  def eager_to_list(_), do: invalid_input!()",
  "  def eager_to_list(%BeamLisp.LazySeq{} = old), do: BeamLisp.LazySeq.to_list(old)\n  def eager_to_list(_), do: invalid_input!()")
if legacy_helper == helper_source, do: raise("bootstrap helper anchor changed")
Code.compile_string(legacy_helper, "bootstrap_compiler_data.ex")

Code.compile_file("lib/beam_lisp/dev_hotpatch.ex")
baseline_ref = System.get_env("PROFILE_BASELINE_COMMIT")
source_root = if baseline_ref do
  nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  root = Path.join(System.tmp_dir!(), "bl_baseline_source_#{nonce}")
  File.mkdir_p!(root)
  System.at_exit(fn _ -> File.rm_rf!(root) end)
  for ns <- ["anf", "lower", "compiler2", "compiler"] do
    {source, 0} = System.cmd("git", ["show", "#{baseline_ref}:priv/boot/#{ns}.bl"])
    File.write!(Path.join(root, "#{ns}.bl"), source)
  end
  root
else
  "priv/boot"
end

# The preceding host is only a bootstrap importer. Load it explicitly so this
# proof does not depend on whichever host generation happens to be in _build.
for path <- ["lib/beam_lisp/emit.ex", "lib/beam_lisp/link.ex", "lib/beam_lisp/compiler.ex", "lib/beam_lisp/aot.ex"] do
  {source, 0} = System.cmd("git", ["show", "440fb3b:" <> path])
  Code.compile_string(source, path)
end

# A populated _build may hold a newer coherent generation, which install!/1
# correctly preserves. This gate specifically proves the committed old seed
# can upgrade, so stage it into a fresh directory rather than mixed cached code.
stage_nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
stage = Path.join(System.tmp_dir!(), "bl_upgrade_seed_#{stage_nonce}")
File.mkdir_p!(stage)
System.at_exit(fn _ -> File.rm_rf!(stage) end)
Process.put(:canonical_upgrade_cleanup, if(baseline_ref, do: [stage, source_root], else: [stage]))
IO.puts("BOOTSTRAP_STAGE: #{stage}")
Code.prepend_path(stage)
BeamLisp.Bootstrap.install!(stage)
{:ok, _} = Application.ensure_all_started(:beam_lisp)
IO.puts("UPGRADE: previous seed and explicit previous host loaded")

# Install the canonical consumer before changing the producer representation.
BeamLisp.DevHotpatch.hotpatch!(["anf", "lower"], source_root: source_root)
IO.puts("UPGRADE: canonical module consumer ready")

# Evaluate source through the old host's live definition route, not its quoted
# AOT module writer. It can install new clause data through the imported lowerer.
BeamLisp.run_file(Path.join(source_root, "compiler2.bl"))
BeamLisp.run_file(Path.join(source_root, "compiler.bl"))
apply(BeamLisp.Ns.Lower, :"normalize-generation-defs!", [])
IO.puts("UPGRADE: direct producer ready; definition store canonicalized")

for path <- ["lib/beam_lisp/emit.ex", "lib/beam_lisp/link.ex", "lib/beam_lisp/aot.ex", "lib/beam_lisp/compiler.ex", "lib/beam_lisp/record.ex", "lib/beam_lisp/native.ex"] do
  Code.compile_file(path)
end
IO.puts("UPGRADE: canonical host consumers loaded")

BeamLisp.DevHotpatch.hotpatch!(["compiler2", "compiler", "anf", "lower"], source_root: source_root)
if baseline_ref do
  Code.require_file("!tasks/artifacts/compiler-retention-probe.exs")
  baseline_hashes = CompilerRetentionProbe.run(:baseline, require_eager: false)
  Code.compile_string(legacy_helper, "bootstrap_compiler_data.ex")
  BeamLisp.DevHotpatch.hotpatch!(["compiler2", "compiler", "anf", "lower"])
  Code.compile_file("lib/beam_lisp/compiler_data.ex")
  CompilerRetentionProbe.run(:eager, expected_hashes: baseline_hashes)
end
Code.compile_file("lib/beam_lisp/compiler_data.ex")
IO.puts("UPGRADE: complete canonical generation emitted; strict eager helper restored")
IO.inspect(BeamLisp.Generation.receipt(), label: "GENERATION_RECEIPT", limit: :infinity)

Code.compile_file("lib/beam_lisp/anf_interpreter.ex")
Code.compile_file("lib/beam_lisp/dev_change.ex")
BeamLisp.run_file("priv/self/anf.bl")
if System.get_env("MIGRATE_CANONICAL_FIXTURES") == "1" do
  Code.require_file("!tasks/artifacts/migrate-canonical-corpus.exs")
end

if System.get_env("PROFILE_CANONICAL_COMPILER") == "1" and is_nil(baseline_ref) do
  Code.require_file("!tasks/artifacts/compiler-retention-probe.exs")
  CompilerRetentionProbe.run(:eager)
end

case System.get_env("CANONICAL_ACTION") do
  "spell" -> Code.require_file("!tasks/artifacts/spell-change-gate.exs")
  "seed" -> Code.require_file("!tasks/artifacts/canonical-seed-stage.exs")
  _ -> :ok
end

unless System.get_env("CANONICAL_SETUP_ONLY") == "1" do
  ExUnit.start()
  extra_exunit = String.split(System.get_env("CANONICAL_EXTRA_EXUNIT", ""), ",", trim: true)
  for path <- extra_exunit ++ ["test/beam_lisp/generation_semantics_test.exs", "test/beam_lisp/anf_emit_test.exs", "test/beam_lisp/direct_forms_test.exs", "test/beam_lisp/wave24_records_test.exs", "test/beam_lisp/native_test.exs"] do
    Code.require_file(path)
  end
  result = ExUnit.run()
  IO.inspect(result, label: "CANONICAL_TEST_RESULT")
  extra_bl = String.split(System.get_env("CANONICAL_EXTRA_BL", ""), ",", trim: true)
  module_result = BeamLisp.TestRT.run_suite(["test/bl/core_aot_test.bl" | extra_bl])
  IO.inspect(module_result, label: "MODULE_CONTRACT_RESULT", limit: :infinity)
  Enum.each(Process.get(:canonical_upgrade_cleanup, []), &File.rm_rf!/1)
  System.halt(if result.failures == 0 and BeamLisp.TestRT.passed?(module_result), do: 0, else: 1)
end
