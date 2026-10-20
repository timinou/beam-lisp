#!/usr/bin/env python3
"""Time fresh installs and require zero SDK source compilations at startup.

Run under a process-tree memory cap, on the same OTP/Elixir toolchain that
built the drop. HOME is preserved; each sample has private XDG directories.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('drop', type=Path)
parser.add_argument('--samples', type=int, default=3)
parser.add_argument('--max-seconds', type=float,
                    help='fail if any fresh install or cold VM exceeds this wall-clock budget')
args = parser.parse_args()
artifact = args.drop.resolve()
if args.samples < 1:
    parser.error('--samples must be positive')
if args.max_seconds is not None and args.max_seconds <= 0:
    parser.error('--max-seconds must be positive')


def run(command, cwd, env):
    start = time.monotonic()
    result = subprocess.run(command, cwd=cwd, env=env, text=True,
                            capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    assert '42' in result.stdout.splitlines(), result.stdout
    return time.monotonic() - start, result.stdout


with tempfile.TemporaryDirectory(prefix='bl-drop-startup-') as temporary:
    scratch = Path(temporary)
    times = []
    cold_vm_times = []
    for sample in range(args.samples):
        directory = scratch / str(sample)
        directory.mkdir()
        env = dict(os.environ)
        for key in ('BL_ROOT', 'BL_EBIN', 'BL_BIN', 'BEAM_LISP_EBIN',
                    'BL_CHECKOUT_COLD', 'BEAM_LISP_AOT_CACHE_DIR', 'DROP_STORE_ROOT'):
            env.pop(key, None)
        for name in ('CACHE', 'DATA', 'STATE', 'CONFIG', 'RUNTIME'):
            path = directory / name.lower()
            path.mkdir(mode=0o700)
            env[f'XDG_{name}_HOME' if name != 'RUNTIME' else 'XDG_RUNTIME_DIR'] = str(path)
        env['BL_DAEMON'] = 'off'
        env['DROP_STORE_ROOT'] = str(directory / 'data/drop')
        hello = directory / 'hello.bl'
        hello.write_text('(ns drop-startup.probe (:require [datom.vector]))\n(println (+ 40 2))\n')
        elapsed, _ = run([str(artifact), '--cold', 'run', str(hello)], directory, env)
        times.append(round(elapsed, 3))
        print(f'fresh-install-{sample + 1}: {elapsed:.3f}s', flush=True)
        # Reuse only extracted files: --cold still starts a new BEAM. This
        # separates VM readiness from the first install's decompression work.
        elapsed, _ = run([str(artifact), '--cold', 'run', str(hello)], directory, env)
        cold_vm_times.append(round(elapsed, 3))
        print(f'cold-vm-{sample + 1}: {elapsed:.3f}s', flush=True)

    # Instrument the extracted image before the actual release entry starts
    # the app. Counting calls avoids a trace mailbox and its timing overhead.
    image = next((directory / 'data/drop').glob('*/lib/beam_lisp-*/ebin'))
    library = image.parent.parent
    probe = directory / 'startup.exs'
    probe.write_text('''
Code.ensure_loaded!(BeamLisp.AOT)
Code.ensure_loaded!(BeamLisp.Loader)
patterns = [{BeamLisp.AOT, :compile_file, 2},
            {BeamLisp.AOT, :compile_source, 2},
            {BeamLisp.AOT, :constructor_compile_sdk_unit!, 2},
            {BeamLisp.Loader, :do_load, 3}]
for pattern <- patterns, do: :erlang.trace_pattern(pattern, true, [:local, :call_count])
halt = fn status ->
  counts = Map.new(patterns, fn {m, f, a} = pattern ->
    {:call_count, count} = :erlang.trace_info(pattern, :call_count)
    {"#{m}.#{f}/#{a}", count}
  end)
  IO.puts("STARTUP-AOT " <> Jason.encode!(counts))
  System.halt(if status == 0 and Enum.all?(counts, fn {_, n} -> n == 0 end), do: 0, else: 1)
end
BeamLisp.Launcher.start_app!(["run", Path.join(__DIR__, "hello.bl")], %{halt: halt})
''')
    command = ['elixir']
    for ebin in sorted(library.glob('*/ebin')):
        command.extend(['-pa', str(ebin)])
    command.append(str(probe))
    _, output = run(command, directory, env)
    print(next(line for line in output.splitlines() if line.startswith('STARTUP-AOT ')), flush=True)

    # The first default command must already run in the persistent VM. A
    # background start plus a temporary cold command would discard that state.
    (directory / 'env.bl').write_text('{:name "drop-startup-transport" :paths []}')
    owners = []
    default_times = []
    try:
        for _ in range(2):
            start = time.monotonic()
            result = subprocess.run(
                [str(artifact), 'eval', '(println (str "OWNER " (System/pid)))'],
                cwd=directory, env=env, text=True, capture_output=True, timeout=180)
            assert result.returncode == 0, result.stdout + result.stderr
            owner = int(next(line[6:] for line in result.stdout.splitlines()
                             if line.startswith('OWNER ')))
            owners.append(owner)
            default_times.append(round(time.monotonic() - start, 3))
            assert Path(f'/proc/{owner}').exists(), 'first result came from a temporary VM'
        assert owners[0] == owners[1], 'default commands discarded the first VM'
        print(json.dumps({'default_request_seconds': default_times,
                          'first_request_reused_runtime': True}), flush=True)
    finally:
        # Limit cleanup to this fixture's exact private runtime directory,
        # including a daemon whose first request failed before returning a pid.
        marker = f'XDG_RUNTIME_DIR={env["XDG_RUNTIME_DIR"]}'.encode() + b'\0'
        for proc in Path('/proc').iterdir():
            if proc.name.isdigit():
                try:
                    if marker in (proc / 'environ').read_bytes() and b'BeamLisp' in (proc / 'cmdline').read_bytes():
                        os.kill(int(proc.name), signal.SIGTERM)
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    pass
    print(json.dumps({'fresh_install_seconds': times,
                      'median_seconds': statistics.median(times),
                      'cold_vm_seconds': cold_vm_times,
                      'cold_vm_median_seconds': statistics.median(cold_vm_times)}), flush=True)
    if args.max_seconds is not None:
        assert max(times + cold_vm_times) <= args.max_seconds, (times, cold_vm_times, args.max_seconds)
        assert default_times[0] <= args.max_seconds, (default_times, args.max_seconds)
