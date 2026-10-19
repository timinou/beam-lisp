#!/usr/bin/env python3
"""Time fresh installs and require zero SDK source compilations at startup.

Run under a process-tree memory cap, on the same OTP/Elixir toolchain that
built the drop. HOME is preserved; each sample has private XDG directories.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('drop', type=Path)
parser.add_argument('--samples', type=int, default=3)
args = parser.parse_args()
artifact = args.drop.resolve()
if args.samples < 1:
    parser.error('--samples must be positive')


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
            {BeamLisp.AOT, :stage_sdk_dependency!, 3},
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
    print(json.dumps({'fresh_install_seconds': times,
                      'median_seconds': statistics.median(times)}), flush=True)
