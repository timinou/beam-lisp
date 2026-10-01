#!/usr/bin/env python3
"""Fresh-process post-fix CLI measurements; never benchmarks an old floor.

CPU is the delta of child user/system time across each completed command.
child_maxrss_kb is cumulative peak across commands in this driver, not a
per-command retention measurement. Wall samples include shell/VM startup.
"""
import json
import os
import resource
import subprocess
import time

commands = [('version', ['version']) for _ in range(3)]
commands += [('--version', ['--version']), ('eval', ['eval', '(+ 1 2)']),
             ('strict-version', ['version']), ('seed-check', ['seed', '--check', '--ebin', os.path.join(os.getcwd(), 'build')])]
for sample, (label, args) in enumerate(commands, 1):
    env = dict(os.environ)
    if label == 'strict-version':
        env['BEAM_LISP_AOT_STRICT'] = '1'
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    result = subprocess.run(['bin/bl', *args], env=env)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    print('POSTFIX ' + json.dumps({'command': label, 'sample': sample, 'exit': result.returncode,
          'wall_s': round(time.monotonic()-start, 6),
          'user_s': round(after.ru_utime-before.ru_utime, 6),
          'sys_s': round(after.ru_stime-before.ru_stime, 6),
          'child_maxrss_kb': after.ru_maxrss}), flush=True)
    if result.returncode != 0:
        raise SystemExit(result.returncode)
