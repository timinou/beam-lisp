# Native provisioning-mode acceptance. No ward/CLI/project path reset.
Application.load(:beam_lisp)
{:ok, dependencies} = :application.get_key(:beam_lisp, :applications)
Enum.each(dependencies, fn dep -> {:ok, _} = Application.ensure_all_started(dep) end)
IO.inspect(BeamLisp.Bootstrap.install!(System.fetch_env!("BL_EBIN")), label: "verified_floor")
BeamLisp.AOT.boot()
IO.puts("PROVISIONING_MODE_NO_INITIAL_SDK_LEASE")
root = System.fetch_env!("BL_PROBE_ROOT")
:ok = BeamLisp.Env.push_load_path(root <> "/beam/priv/std")
Enum.each(["reload.collection-constructor", "reload.generation"], fn ns ->
  expected = root <> "/beam/priv/std/" <> String.replace(ns, ".", "/") <> ".bl"
  actual = BeamLisp.Loader.source_path(ns)
  if actual != expected, do: raise("HOME source shadowed: #{inspect({ns, expected, actual})}")
  IO.inspect({ns, actual, Base.encode16(:crypto.hash(:sha256, File.read!(actual)), case: :lower)}, label: "IMMUTABLE_PRIVATE_SOURCE")
end)
BeamLisp.Loader.ensure_loaded("reload.collection-constructor")
BeamLisp.Loader.ensure_loaded("reload.generation")
namespace = "reload.collection-constructor-test"
file = root <> "/collection-constructor-direct.bl"
BeamLisp.Compiler.eval_string(File.read!(file), BeamLisp.Compiler.new_env(namespace), file)
marker = "BL_COLLECTION_CONSTRUCTOR_MUST_NOT_RUN"
before = System.get_env(marker)
functions = ["finite-projection-can-only-escape-after-materialization", "raw-storage-boundary-does-not-execute-callbacks", "shape-budgets-are-finite", "actual-compiled-expression-is-proved-without-running-it", "unchanged-immutable-initializer-prepares-through-private-proof", "callback-collection-and-shadowed-call-refuse-before-effects"]
crashes = Enum.flat_map(functions, fn name ->
  try do
    result = BeamLisp.Ns.Rt.invoke(BeamLisp.Env.fetch_exact!(namespace, name), [])
    IO.inspect({name, result}, label: "IMMUTABLE_DIRECT_CASE")
    []
  rescue
    error -> IO.inspect({name, error, __STACKTRACE__}, label: "IMMUTABLE_DIRECT_CRASH"); [name]
  catch
    kind, reason -> IO.inspect({name, kind, reason}, label: "IMMUTABLE_DIRECT_THROW"); [name]
  end
end)
report = BeamLisp.Ns.Rt.invoke(BeamLisp.Env.fetch_exact!(namespace, "direct-report"), [])
unchanged = before == System.get_env(marker)
IO.inspect(report, label: "IMMUTABLE_DIRECT_ASSERTIONS")
IO.inspect(%{candidate_effect_marker_unchanged: unchanged, crashes: crashes, expected_assertions: 24}, label: "IMMUTABLE_DIRECT_EVIDENCE")
passed = unchanged and crashes == [] and report[:assertions] == 24 and report[:pass] == 24 and BeamLisp.Vector.to_list(report[:failures]) == []
System.halt(if passed, do: 0, else: 1)
