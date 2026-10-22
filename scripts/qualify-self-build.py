#!/usr/bin/env python3
"""Check an assembled drop's default transport in its own ordinary project."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def stop_owned(runtime):
    owned = []
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            if (f'XDG_RUNTIME_DIR={runtime}'.encode() + b'\0' in (proc / 'environ').read_bytes()
                    and b'beamlisp' in (proc / 'cmdline').read_bytes().lower()):
                os.kill(int(proc.name), signal.SIGTERM)
                owned.append(int(proc.name))
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    deadline = time.monotonic() + 3
    while owned and time.monotonic() < deadline:
        owned = [pid for pid in owned if Path(f'/proc/{pid}').exists()]
        if owned:
            time.sleep(0.05)
    for pid in owned:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, help='check an existing drop instead of rebuilding')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='bl-self-qualify-') as scratch:
        scratch = Path(scratch)
        runtime, state, project = [scratch / name for name in ('runtime', 'state', 'project')]
        for path in (runtime, state, project):
            path.mkdir(mode=0o700)
        (project / 'env.bl').write_text('{:name "artifact-self-check"}\n')
        env = {**os.environ, 'XDG_RUNTIME_DIR': str(runtime), 'XDG_STATE_HOME': str(state)}
        for name in ('BL_ROOT', 'BL_BIN', 'BL_DAEMON', 'BL_USE', 'BL_CHECKOUT_ROOT',
                     'BL_CHECKOUT_COLD', 'BL_CHECKOUT_GENERATION', 'BL_CHECKOUT_SOURCE_GENERATION'):
            env.pop(name, None)
        candidate = args.candidate.resolve() if args.candidate else scratch / 'bl-self'
        try:
            if not args.candidate:
                subprocess.run([str(ROOT / 'bin/bl'), '--cold', 'self-build', '--bin',
                                str(ROOT / 'tooling/drop/target/release/drop-launcher'),
                                '--out', str(candidate)], cwd=ROOT, env=env, check=True, timeout=1200)

            def run(*argv):
                result = subprocess.run([str(candidate), *argv], cwd=project, env=env,
                                        text=True, capture_output=True, timeout=420)
                if result.returncode:
                    raise RuntimeError(f'{argv}: {result.stdout}\n{result.stderr}')
                return result.stdout.strip().splitlines()

            print('\n'.join(run('version')), flush=True)
            assert '42' in run('eval', '(println (+ 40 2))')
            first = run('eval', '(println (str "OWNER " (System/pid)))')
            second = run('eval', '(println (str "OWNER " (System/pid)))')
            owner1 = next(line for line in first if line.startswith('OWNER '))
            owner2 = next(line for line in second if line.startswith('OWNER '))
            assert owner1 == owner2, (owner1, owner2)
            print('SELF_BUILD_DEFAULT_TRANSPORT_READY ' + owner1, flush=True)
        except BaseException:
            for log in state.rglob('*.log'):
                print(f'{log.name}:\n{log.read_text(errors="replace")[-16000:]}', flush=True)
            raise
        finally:
            stop_owned(runtime)


if __name__ == '__main__':
    main()
