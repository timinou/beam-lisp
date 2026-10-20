#!/usr/bin/env python3
"""Exercise the checkout's real native client and VM in an isolated project.
Run under systemd-run MemoryMax/MemorySwapMax; all spawned VMs are cleaned up.
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--root', default=Path(__file__).resolve().parents[2], type=Path)
parser.add_argument('--max-start-seconds', type=float,
                    help='fail if starting and answering the first request exceeds this budget')
args = parser.parse_args()
launcher = str(args.root.resolve() / 'bin/bl')
with tempfile.TemporaryDirectory(prefix='bl-checkout-transport-') as scratch:
    project = Path(scratch)
    runtime = project / '.runtime'
    runtime.mkdir(mode=0o700)
    (project / 'env.bl').write_text('{:name "checkout-transport-test" :schedules '
                                    '[{:id "not-started" :every [1 :hours] :run "unused/run"}]}')
    (project / 'value.bl').write_text('(println "VALUE 1")')
    (project / 'analysis.bl').write_text('(ns transport.analysis) (defn answer [x] (+ x 1))')
    (project / 'argv.bl').write_text('(println (str "ARGS " (count (BeamLisp/argv)) " " (Enum/join (BeamLisp/argv) "|")))')
    (project / 'index.bl.md').write_text('# Checkout transport\n')
    nested = project / 'nested'
    nested.mkdir()
    env = {**os.environ, 'XDG_RUNTIME_DIR': str(runtime),
           'XDG_STATE_HOME': str(project / '.state')}
    # Never inherit a cold-child bypass from a caller's VM.
    env.pop('BL_CHECKOUT_COLD', None)
    timings = {}

    def run(label, *argv, cwd=project, extra=None, success=True):
        start = time.monotonic()
        result = subprocess.run([launcher, *argv], cwd=cwd,
                                env={**env, **(extra or {})},
                                text=True, capture_output=True, timeout=420 if label == "first" else 180)
        timings[label] = round(time.monotonic() - start, 3)
        print(f"{label}: {timings[label]}s", file=sys.stderr, flush=True)
        if success and result.returncode:
            for log in project.rglob('*.log'):
                print(f"{log.name}:\n{log.read_text(errors='replace')[-12000:]}", file=sys.stderr)
        assert (result.returncode == 0) == success, (label, result.stdout, result.stderr)
        return result.stdout

    def owner(label, *flags, **kwargs):
        output = run(label, *flags, 'eval', '(println (str "OWNER " (System/pid)))', **kwargs)
        return int(next(line[6:] for line in output.splitlines() if line.startswith('OWNER ')))

    def cleanup():
        for proc in Path('/proc').iterdir():
            if not proc.name.isdigit():
                continue
            try:
                if f'XDG_RUNTIME_DIR={runtime}'.encode() + b'\0' in (proc / 'environ').read_bytes():
                    cmd = (proc / 'cmdline').read_bytes()
                    if b'BeamLisp' in cmd:
                        os.kill(int(proc.name), signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                pass

    try:
        first = owner('first', extra={'BL_TRANSPORT_TEST_VALUE': 'daemon-boot-only'})
        second = owner('reuse')
        assert first == second, 'second command started a different VM'
        assert Path(f'/proc/{first}').exists(), 'command ran in a temporary VM'
        output = run('no-idle-shutdown', 'eval',
                     '(println (nil? (erlang/apply :persistent_term :get (list (tuple :vm_session :idle) nil))))')
        assert 'true' in output.splitlines(), 'automatic VM armed an idle shutdown watcher'
        cgroup = Path(f'/proc/{first}/cgroup')
        if cgroup.exists():
            relative = next((line[3:] for line in cgroup.read_text().splitlines() if line.startswith('0::')), None)
            if relative and Path(relative).name.startswith('bl-checkout-') and relative.endswith('.scope'):
                group = Path('/sys/fs/cgroup') / relative.lstrip('/')
                assert (group / 'memory.max').read_text().strip() == str(4 * 1024**3)
                assert (group / 'memory.swap.max').read_text().strip() == str(512 * 1024**2)
        assert '3' in run('eval', 'eval', '(+ 1 2)').splitlines()
        lazy_probe = '(println (and (= false (code/is_loaded :Elixir.BeamLisp.Ns.Vm.Sched)) (= false (code/is_loaded :Elixir.BeamLisp.Ns.Vm.Http)) (= false (code/is_loaded :Elixir.BeamLisp.Ns.Vm.Inspect)) (= false (code/is_loaded :Elixir.BeamLisp.Ns.Code.Index))))'
        assert 'true' in run('lazy-session', 'eval', lazy_probe).splitlines()
        checked = run('first-sdk-check', 'check', 'analysis.bl', '--json')
        assert '"unreadable": false' in checked or '"unreadable":false' in checked, checked
        run('repeat-sdk-check', 'check', 'analysis.bl', '--json')
        analysis_lazy = ('(println (and (= false (code/is_loaded :Elixir.BeamLisp.Ns.Codebase)) '
                         '(= false (code/is_loaded :Elixir.BeamLisp.Ns.System.Linear)) '
                         '(= false (code/is_loaded :Elixir.BeamLisp.Ns.Z3))))')
        assert 'true' in run('analysis-stays-light', 'eval', analysis_lazy).splitlines()
        assert 'true' in run('unset-environment', 'eval',
                             '(println (nil? (System/get_env "BL_TRANSPORT_TEST_VALUE")))').splitlines()
        for value in ['first-client', 'second-client']:
            output = run('environment-' + value, 'eval',
                         '(println (System/get_env "BL_TRANSPORT_TEST_VALUE"))',
                         extra={'BL_TRANSPORT_TEST_VALUE': value})
            assert value in output.splitlines(), output
        assert owner('nested-owner', cwd=nested) == first
        output = run('cwd', 'eval', '(println (BeamLisp/cwd))', cwd=nested)
        assert str(nested) in output.splitlines(), output
        assert 'ARGS 2 first|second' in run('argv', 'run', 'argv.bl', '--', 'first', 'second').splitlines()
        assert 'ARGS 0' in [line.strip() for line in run('argv-cleared', 'run', 'argv.bl').splitlines()]
        assert 'true' in run('eval-argv', 'eval', '(println (= "eval" (first (BeamLisp/argv))))').splitlines()
        for n in range(2):
            run(f'doc-{n}', 'doc', 'build', 'index.bl.md', '--out', '.preview')
            assert (project / '.preview/index.html').is_file()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(owner, f'concurrent-{n}') for n in range(2)]
            assert [f.result() for f in futures] == [first, first]
            values = ['concurrent-client-A', 'concurrent-client-B']
            futures = [pool.submit(run, 'concurrent-env-' + value, 'eval',
                                   '(println (System/get_env "BL_TRANSPORT_TEST_VALUE"))',
                                   extra={'BL_TRANSPORT_TEST_VALUE': value}) for value in values]
            for value, future in zip(values, futures):
                assert value in future.result().splitlines()
        run('failure', 'eval', '(throw "checkout-test-failure")', success=False)
        assert owner('after-failure') == first
        assert owner('cold', '--cold') != first
        assert owner('after-cold') == first
        assert 'VALUE 1' in run('source-before', 'run', 'value.bl').splitlines()
        (project / 'value.bl').write_text('(println "VALUE 2")')
        assert 'VALUE 2' in run('source-after', 'run', 'value.bl').splitlines()
        updated = owner('after-edit')
        assert owner('after-edit-nested', cwd=nested) == updated
        assert updated == first, 'a project edit discarded the compiler VM'
        provider = project / 'transport/value.bl'
        provider.parent.mkdir()
        provider.write_text('(ns transport.value) (defn value [] 1)')
        query = ('(BeamLisp.Loader/ensure_loaded "transport.value") '
                 '(println (str "PROVIDER " (BeamLisp.Ns.Rt/invoke '
                 '(BeamLisp.Env/fetch_exact! "transport.value" "value") (list))))')
        assert 'PROVIDER 1' in run('provider-before', 'eval', query).splitlines()
        provider.write_text('(ns transport.value) (defn value [] 2)')
        assert 'PROVIDER 2' in run('provider-after', 'eval', query).splitlines()
        assert owner('after-provider-edit') == first, 'provider replacement discarded the compiler'
        print(json.dumps({'same_owner': True, 'source_edit_reused_runtime': True,
                          'owner': first, 'updated_owner': updated, 'seconds': timings}), flush=True)
        if args.max_start_seconds is not None:
            assert timings['first'] <= args.max_start_seconds, timings
    finally:
        cleanup()
