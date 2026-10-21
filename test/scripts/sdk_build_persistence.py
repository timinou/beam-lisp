#!/usr/bin/env python3
"""Exercise persistent SDK production in fresh VMs before a full SDK build.

--image may name a private check-runtime-hosts image to qualify a source batch
without regenerating the floor. The test never runs bin/bl or rebuilds the SDK.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DRIVER = r'''
root = System.fetch_env!("BL_ROOT")
work = System.fetch_env!("PROBE_WORK")
phase = System.fetch_env!("PROBE_PHASE")
{:ok, [floor]} = :file.consult(String.to_charlist(Path.join(root, "priv/bootstrap/seed/manifest.term")))
:persistent_term.put({BeamLisp.AOTCache, :toolchain_key}, floor["compiler_key"])
tag = "erts#{:erlang.system_info(:version)}-elixir#{System.version()}"
for path <- :code.get_path() do
  name = List.to_string(path)
  if String.contains?(name, "/beam_lisp/ebin/") and not String.ends_with?(name, "-#{tag}/ebin"), do: :code.del_path(path)
end
Application.ensure_all_started(:crypto)
Application.load(:beam_lisp)
for app <- Application.spec(:beam_lisp, :applications) || [], do: Application.ensure_all_started(app)
{:ok, _} = Supervisor.start_link([BeamLisp.Env, BeamLisp.Loader.Server], strategy: :one_for_one, name: BeamLisp.Supervisor)
overlay = Path.join(root, "host-overlay/Elixir.BeamLisp.AOT.beam")
bootstrap = System.get_env("PROBE_BOOTSTRAP")
install = fn bytes ->
  name = "Elixir.BeamLisp.AOT.beam"
  seed = Path.join(root, "priv/bootstrap/seed")
  {:ok, [manifest]} = :file.consult(String.to_charlist(Path.join(seed, "manifest.term")))
  manifest = put_in(manifest, ["modules", name], Base.encode16(:crypto.hash(:sha256, bytes), case: :lower))
  File.write!(Path.join(seed, name), bytes)
  File.write!(Path.join(root, "ebin/" <> name), bytes)
  File.write!(Path.join(seed, "manifest.term"), :io_lib.format(~c"~tp.~n", [manifest]))
  {:module, BeamLisp.AOT} = :code.load_binary(BeamLisp.AOT, ~c"probe-host", bytes)
end
if bootstrap, do: install.(File.read!(Path.join(bootstrap, "ebin/Elixir.BeamLisp.AOT.beam")))
BeamLisp.AOT.boot()
if bootstrap do
  BeamLisp.AOT.bootstrap_sdk_native_hosts!()
  install.(File.read!(overlay))
end
BeamLisp.Env.retain_sdk_runtime!()
# Pin the bootstrap case too: forward declarations are compile-time scaffolding
# for native hosts, while ordinary namespace artifacts must replay them.
pinned = Path.join(work, "pinned-host.bl")
File.write!(pinned, "(ns sdkbuild-pinned) (declare value) (defn value [] 7)")
BeamLisp.AOT.compile_host_file(pinned, module: BeamLisp.BuildProofHost, output_dir: Path.join(work, "driver"))
if BeamLisp.BuildProofHost.value() != 7, do: raise("pinned declaration compilation failed")
# Build the actual edited driver under private namespace names, preserving
# the compiler identity/source snapshot of the SDK used to run this probe.
for leaf <- ["build-plan.bl", "build-log.bl", "build.bl"] do
  src = Path.join(work, leaf)
  BeamLisp.AOT.compile_file(src, output_dir: Path.join(work, "driver"), mark_loaded?: true)
end
run = BeamLisp.Env.fetch_exact!("sdk-build-driver", "run")
files = Path.wildcard(Path.join(work, "sources/*.bl"))
if phase == "first" do
  # The loader uses strict Erlang booleans. Missing compiler evidence must be
  # false rather than nil, especially for units containing arbitrary effects.
  false = BeamLisp.AOT.replayable_cached_source?("sdkbuild-effects", Path.join(work, "sources/sdkbuild-effects.bl"))
end
patterns = %{build_parses: {BeamLisp.BuildPlan, :"build-content-parts", 1}, compilations: {BeamLisp.AOT, :compile_file, 2},
             source_initializations: {BeamLisp.AOT, :load_unit, 2},
             artifact_restorations: {BeamLisp.AOTCache, :restore_prepared, 2},
             artifact_preparations: {BeamLisp.AOTCache, :prepare_fetch, 2},
             initializer_guard_entries: {BeamLisp.Loader, :assert_initializer_execution_allowed!, 1},
             inventory_walks: {BeamLisp.AOT, :sdk_runtime_inventory!, 1}}
for {_, mfa} <- patterns, do: :erlang.trace_pattern(mfa, true, [:local, :call_count])
# Count namespace initializer replays, including modules loaded later. Source
# evaluation during compilation initializes a namespace too and is counted
# separately above. The total includes both paths, not merely __bl_init__.
:erlang.trace_pattern(:on_load, true, [:local, :call_count])
started = System.monotonic_time(:microsecond)
opts = %{:"log-path" => Path.join(work, "build.log"), sources: files, root: Path.join(work, "sources"), out: Path.join(work, "units"),
  manifest: Path.join(work, "manifest"), jobs: 2}
if phase == "corrupt" do
  # Keep a valid BEAM, its module identity, attributes and executable code;
  # change only CInf. Compiler stamps alone would incorrectly accept this.
  mod = BeamLisp.Emit.module_for("sdkbuild-base")
  path = Path.join(work, "units/" <> Atom.to_string(mod) <> ".beam")
  {:ok, ^mod, chunks} = :beam_lib.all_chunks(File.read!(path))
  chunks = Enum.map(chunks, fn
    {~c"CInf", info} -> {~c"CInf", :erlang.term_to_binary([{:probe_corruption, true} | :erlang.binary_to_term(info)])}
    chunk -> chunk
  end)
  {:ok, changed} = :beam_lib.build_module(chunks)
  File.write!(path, changed)
end
invoke = fn -> BeamLisp.Ns.Rt.invoke(run, [opts]) end
r = if phase == "contended" do
  manifest = :erlang.binary_to_term(File.read!(Path.join(work, "manifest")))
  for {path, entry} <- manifest, Path.basename(path) in ["sdkbuild-base.bl", "sdkbuild-macros.bl"], mod <- entry.modules do
    File.rm!(Path.join(work, "units/" <> Atom.to_string(mod) <> ".beam"))
  end
  me = self()
  holder = spawn_link(fn ->
    :global.trans({:bl_build_unit_publication, self()}, fn ->
      send(me, {:held, self()})
      receive do :release -> :ok end
    end, [node()])
  end)
  receive do {:held, ^holder} -> :ok after 1000 -> raise("publication lock not acquired") end
  :erlang.trace_pattern({:global, :set_lock, 4},
    [{[{:bl_build_unit_publication, :_}, :_, :_, :_], [], []}], [:local])
  :erlang.trace(:new, true, [:call, {:tracer, self()}])
  task = Task.async(BeamLisp.Env.convey(invoke))
  try do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case :erlang.trace_info(patterns.artifact_preparations, :call_count) do
        {:call_count, n} when n >= 2 -> {:halt, :prepared}
        _ -> Process.sleep(10); {:cont, nil}
      end
    end) == :prepared || raise("immutable preparation waited for publication lock")
    # A second attempt proves the publisher actually failed to acquire the
    # held lock. Merely releasing after preparation can miss the contention.
    receive do
      {:trace, _, :call, {:global, :set_lock, [{:bl_build_unit_publication, _}, _, _, attempts]}}
        when attempts >= 2 -> :ok
    after
      3000 -> raise("publisher never retried the held publication lock")
    end
    for key <- [:compilations, :artifact_restorations] do
      if :erlang.trace_info(patterns[key], :call_count) != {:call_count, 0},
        do: raise("publication ran while another process held the global lock")
    end
  after
    :erlang.trace(:new, false, [:call])
    :erlang.trace(:all, false, [:call])
    :erlang.trace_pattern({:global, :set_lock, 4}, false, [:local])
    send(holder, :release)
  end
  Task.await(task, 30_000)
else
  invoke.()
end
# Exercise disposable assembly and metadata creation in the measured turn.
for name <- ["assemble-outputs!", "write-precompiled-index!"] do
  function = BeamLisp.Env.fetch_exact!("sdk-build-driver", name)
  args = if name == "assemble-outputs!",
    do: [r.manifest, Path.join(work, "units"), Path.join(work, "release")],
    else: [r.manifest, Path.join(work, "release"), Path.join(work, "release/precompiled.term")]
  BeamLisp.Ns.Rt.invoke(function, args)
end
BeamLisp.AOT.write_sdk_inventory!(Path.join(work, "sources"), r.manifest,
  Path.join(work, "release"), Path.join(work, "release/sdk-code.term"))
metrics = Map.new(patterns, fn {key, mfa} -> {key, elem(:erlang.trace_info(mfa, :call_count), 1)} end)
initializers = Enum.reduce(["base", "custom", "macros", "consumer", "effects", "macro-effects"], 0, fn leaf, n ->
  mod = BeamLisp.Emit.module_for("sdkbuild-" <> leaf)
  case :erlang.trace_info({mod, :__bl_init__, 0}, :call_count) do
    {:call_count, count} when is_integer(count) -> n + count
    _ -> n
  end
end)
metrics = Map.merge(metrics, %{assembled_units: map_size(r.manifest), initializer_replays: initializers,
  initializer_executions: initializers + metrics.source_initializations, phase: phase, lock_wait_us: r[:"lock-wait-us"], compiled: r.compiled, restored: r.cached,
  elapsed_ms: (System.monotonic_time(:microsecond)-started)/1000})
IO.puts("SDK-BUILD-PROBE " <> Jason.encode!(metrics))
if Enum.any?(r.errors), do: raise(inspect(r.errors))
if phase == "unchanged" do
  if metrics.compilations != 0 or metrics.initializer_executions != 0 or metrics.build_parses != 0 or r.built != 0,
    do: raise("unchanged build performed executable work")
  for ns <- ["sdkbuild-base", "sdkbuild-custom", "sdkbuild-macros", "sdkbuild-consumer", "sdkbuild-effects", "sdkbuild-macro-effects"] do
    if BeamLisp.Env.loaded_ns?(ns), do: raise("packaging initialized #{ns}")
  end
end
if phase == "restore" do
  if r.compiled != 2 or r.cached != 4, do: raise("expected four restored declarations and two uncached arbitrary effects")
  if not BeamLisp.Env.loaded_ns?("sdkbuild-macros"), do: raise("compiling the macro effect failed to initialize its macro provider")
  for ns <- ["sdkbuild-base", "sdkbuild-custom", "sdkbuild-consumer"] do
    if BeamLisp.Env.loaded_ns?(ns), do: raise("restoring artifacts initialized #{ns}")
  end
end
if phase == "corrupt" and (r.compiled != 0 or r.cached != 1 or initializers != 0),
  do: raise("damaged completed unit was not restored without initialization")
if phase == "contended" and (r.compiled != 0 or r.cached != 2 or initializers != 0),
  do: raise("contended artifact restoration performed executable work")
if phase == "changed" do
  if r.compiled != 1, do: raise("changed consumer recompiled dependencies")
  if BeamLisp.Env.fetch_exact!("sdkbuild-consumer", "answer") != 49, do: raise("restored value provider lost semantics")
  if not BeamLisp.Env.local_var?("sdkbuild-base", "missing"), do: raise("declare was lost on replay")
  box = BeamLisp.Ns.Rt.invoke(BeamLisp.Env.fetch_exact!("sdkbuild-base", "->Box"), [49])
  if Map.get(box, :value) != 49, do: raise("complete record unit was lost on restoration")
end
System.halt(0)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path)
    parser.add_argument('--bootstrap-image', type=Path, help='frozen image for a check-runtime-hosts overlay')
    args = parser.parse_args()
    image = args.image.resolve()
    with tempfile.TemporaryDirectory(prefix='bl-sdk-persistence-') as temporary:
        work = args.work_dir.resolve() if args.work_dir else Path(temporary)
        work.mkdir(parents=True, exist_ok=True)
        if any(work.iterdir()):
            raise SystemExit('probe work directory must be empty')
        sources = work / 'sources'
        sources.mkdir()
        for leaf in ('build-plan.bl', 'build-log.bl', 'build.bl'):
            source = (ROOT / 'priv/build' / leaf).read_text()
            source = source.replace('(ns build-plan\n', '(ns sdk-build-plan\n')
            source = source.replace('[build-plan :as plan]', '[sdk-build-plan :as plan]')
            source = source.replace('(ns build-log)', '(ns sdk-build-log)')
            source = source.replace('(ns build\n', '(ns sdk-build-driver\n')
            source = source.replace('[build-log :as blog]', '[sdk-build-log :as blog]')
            (work / leaf).write_text(source)
        (sources / 'sdkbuild-macros.bl').write_text('(ns sdkbuild-macros) (defmacro value [name n] (list \'def name n)) (defmacro action [path] (list \'do (list \'File/write! path "m" (list \'list :append)) true))\n')
        (sources / 'sdkbuild-base.bl').write_text('(ns sdkbuild-base) (declare f missing) (defn f [] 7) (defrecord Box [value])\n')
        (sources / 'sdkbuild-custom.bl').write_text('(ns sdkbuild-custom (:require [sdkbuild-macros :as m])) (m/value answer 42)\n')
        (sources / 'sdkbuild-consumer.bl').write_text('(ns sdkbuild-consumer (:require [sdkbuild-base :as b] [sdkbuild-custom :as c])) (defn result [] (+ (b/f) c/answer))\n')
        marker = json.dumps(str(work / 'effect-count'))
        (sources / 'sdkbuild-effects.bl').write_text(f'(ns sdkbuild-effects) (File/write! {marker} "x" (list :append)) (defn result [] true)\n')
        macro_marker = json.dumps(str(work / 'macro-effect-count'))
        (sources / 'sdkbuild-macro-effects.bl').write_text(f'(ns sdkbuild-macro-effects (:require [sdkbuild-macros :as m])) (m/action {macro_marker})\n')
        driver = work / 'probe.exs'
        driver.write_text(DRIVER)
        deps = (sorted(image.parent.glob('*/ebin')) if image.parent.name == 'lib'
                else sorted((Path.home() / '.cache/beam_lisp/ebin').glob('*/ebin')))
        use_systemd = bool(shutil.which('systemd-run') and shutil.which('systemctl')
            and subprocess.run(['systemctl', '--user', 'show-environment'], capture_output=True).returncode == 0)
        executable = shutil.which('elixir')
        if not executable:
            raise SystemExit('elixir is not on PATH')
        command = [executable]
        for dep in deps:
            command += ['-pa', str(dep)]
        command += ['-pa', str(image / 'ebin'), str(driver)]
        for phase in ('first', 'unchanged', 'restore', 'changed', 'corrupt', 'contended'):
            if phase == 'restore':
                shutil.rmtree(work / 'units')
            if phase == 'changed':
                (sources / 'sdkbuild-consumer.bl').write_text('(ns sdkbuild-consumer (:require [sdkbuild-base :as b] [sdkbuild-custom :as c])) (def answer (+ (b/f) c/answer))\n')
            env = {**os.environ, 'BL_ROOT': str(image), 'PROBE_WORK': str(work), 'PROBE_PHASE': phase,
                   'BEAM_LISP_AOT_CACHE_DIR': str(work / 'cache'), 'BL_DAEMON': 'off',
                   'ELIXIR_ERL_OPTIONS': '+S 4:4 +SDcpu 2:2 +SDio 1:1'}
            cap = ['systemd-run', '--user', '--collect', '--wait', '--pipe', '--quiet',
                   f'--unit=bl-sdk-probe-{os.getpid()}-{phase}', f'--working-directory={image}',
                   '--property=MemoryMax=6G', '--property=MemorySwapMax=0', '--property=RuntimeMaxSec=300']
            if args.bootstrap_image:
                env['PROBE_BOOTSTRAP'] = str(args.bootstrap_image.resolve())
                cap += [f"--setenv=PROBE_BOOTSTRAP={env['PROBE_BOOTSTRAP']}"]
            # The user manager predates setup-beam/asdf/Nix's shell PATH.
            # Elixir also resolves its erl child through that same PATH.
            for key in ('PATH', 'BL_ROOT', 'PROBE_WORK', 'PROBE_PHASE', 'BEAM_LISP_AOT_CACHE_DIR', 'BL_DAEMON', 'ELIXIR_ERL_OPTIONS'):
                cap += [f'--setenv={key}={env[key]}']
            try:
                subprocess.run((cap if use_systemd else []) + command, env=env, check=True, timeout=300)
            finally:
                if use_systemd:
                    subprocess.run(['systemctl', '--user', 'stop', f'bl-sdk-probe-{os.getpid()}-{phase}'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            expected = 'x' if phase in ('first', 'unchanged') else 'xx'
            assert (work / 'effect-count').read_text() == expected, 'packaging repeated or lost arbitrary effects'
            assert (work / 'macro-effect-count').read_text() == expected.replace('x', 'm'), 'custom macro action was incorrectly admitted'


if __name__ == '__main__':
    main()
