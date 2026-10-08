#!/usr/bin/env python3
"""Fresh process acceptance for optional loader telemetry; owns its process group."""
import argparse, json, os, resource, signal, subprocess, tempfile, time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--bin', default=str(Path(__file__).resolve().parents[3] / 'bin/bl'))
parser.add_argument('--cwd', default=str(Path(__file__).resolve().parents[3]))
parser.add_argument('--timeout', type=float, default=120)
parser.add_argument('--rss-mb', type=int, default=1024)
a = parser.parse_args()
scratch = Path.home() / '.tmp' / 'beam-lisp-loader-startup'
scratch.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, TMPDIR=str(scratch), ERL_FLAGS='+S 4:4 +SDcpu 2 +SDio 2', BL_DAEMON='off')
def cap():
    resource.setrlimit(resource.RLIMIT_AS, (8 * 1024**3, 8 * 1024**3))
def memory(pid):
    pending, rss, swap = [pid], 0, 0
    while pending:
        current = pending.pop()
        try:
            status = (Path('/proc') / str(current) / 'status').read_text()
            fields = {line.split(':', 1)[0]: line.split(':', 1)[1].strip() for line in status.splitlines() if ':' in line}
            rss += int(fields.get('VmRSS', '0 kB').split()[0])
            swap += int(fields.get('VmSwap', '0 kB').split()[0])
            children = Path('/proc') / str(current) / 'task' / str(current) / 'children'
            pending.extend(map(int, children.read_text().split()))
        except (OSError, ValueError):
            pass
    return rss, swap
with tempfile.TemporaryFile(dir=scratch) as stdout, tempfile.TemporaryFile(dir=scratch) as stderr:
    started = time.monotonic()
    p = subprocess.Popen([a.bin, 'eval', '(println :loader-boot-ready)'], cwd=a.cwd,
                         env=env, stdout=stdout, stderr=stderr, start_new_session=True, preexec_fn=cap)
    peak_rss = peak_swap = 0
    stopped = None
    try:
        while p.poll() is None:
            rss, swap = memory(p.pid)
            peak_rss, peak_swap = max(peak_rss, rss), max(peak_swap, swap)
            if rss > a.rss_mb * 1024:
                stopped = 'rss-budget'
            elif time.monotonic() - started > a.timeout:
                stopped = 'deadline'
            if stopped:
                break
            time.sleep(.1)
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
    stdout.seek(0); stderr.seek(0)
    out, err = stdout.read().decode(errors='replace'), stderr.read().decode(errors='replace')
    result = dict(returncode=p.returncode, elapsed_seconds=time.monotonic() - started,
                  peak_rss_kb=peak_rss, peak_swap_kb=peak_swap, stopped=stopped,
                  sentinel=':loader-boot-ready' in out, stdout_tail=out[-4096:], stderr_tail=err[-4096:])
    print(json.dumps(result))
    raise SystemExit(0 if p.returncode == 0 and result['sentinel'] and stopped is None else 1)
