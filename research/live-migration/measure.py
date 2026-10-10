#!/usr/bin/env python3
"""Real HTTP continuity probe; artifacts and scratch stay under HOME."""
import argparse
import concurrent.futures as futures
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import threading
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--selection", choices=("serialized", "prepared"), default="prepared")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
root = Path.home() / "tmp/live-migration" / f"http-{time.time_ns()}"
root.mkdir(parents=True, mode=0o700)
(root / "env.bl").write_text(
    '{:paths [' + json.dumps(str(repo / "priv/std")) + ' ' + json.dumps(str(repo / "priv/lib")) +
    '] :env {"BEAM_LISP_DEV" "0" "BEAM_LISP_IMAGE" "release" "BEAM_LISP_RELOAD" "1"}}\n')
(root / "main.bl").write_text((repo / "research/live-migration/http.bl").read_text())
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
base = f"http://127.0.0.1:{port}"
unit = f"bl-live-migration-{os.getpid()}"

def request(path, method="GET"):
    with urllib.request.urlopen(urllib.request.Request(base + path, method=method), timeout=30) as r:
        assert r.status == 200
        return json.load(r)

def percentile(values, q):
    return sorted(values)[min(len(values) - 1, int(len(values) * q))]

counts = []
phases = []

def phase(name, action=None, wait_backfill=False):
    stop = threading.Event()
    latencies, errors, observed = [], [], []
    def worker():
        while not stop.is_set():
            start = time.perf_counter()
            try:
                result = request("/work")
                if type(result["count"]) is not int or result["rows"] != 500:
                    raise AssertionError("invalid response/state")
                observed.append(result["count"])
                latencies.append((time.perf_counter() - start) * 1000)
            except Exception as exc:
                errors.append(type(exc).__name__)
    start = time.perf_counter()
    with futures.ThreadPoolExecutor(max_workers=8) as pool:
        work = [pool.submit(worker) for _ in range(8)]
        try:
            time.sleep(0.5)
            action_start = time.perf_counter()
            outcome = request(action, "POST") if action else None
            action_ms = (time.perf_counter() - action_start) * 1000 if action else None
            if wait_backfill:
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    health = request("/health")
                    if health["backfill"]["status"] == "applied":
                        break
                    if health["backfill"]["status"] not in ("started", "progress"):
                        raise AssertionError(health)
                    time.sleep(.1)
                else:
                    raise TimeoutError("backfill failed to converge")
            time.sleep(1.5)
        finally:
            stop.set()
            for f in work:
                f.result()
    elapsed = time.perf_counter() - start
    assert observed, "no successful traffic"
    counts.extend(observed)
    phases.append(dict(phase=name, requests=len(observed), errors=errors, seconds=elapsed,
                       rps=len(observed)/elapsed, median_ms=statistics.median(latencies),
                       p95_ms=percentile(latencies, .95), p99_ms=percentile(latencies, .99),
                       max_ms=max(latencies), action=outcome, action_ms=action_ms, health=request("/health")))

log = (root / "server.log").open("w")
process = subprocess.Popen([
    "systemd-run", "--user", "--collect", "--wait", "--pipe", f"--unit={unit}",
    f"--working-directory={root}", "--property=MemoryMax=4G", "--property=MemorySwapMax=1G",
    "env", f"TMPDIR={root}", f"LIVE_MIGRATION_ROOT={root}", f"LIVE_MIGRATION_PORT={port}", f"LIVE_MIGRATION_SELECTION={args.selection}",
    "timeout", "240", str(repo / "bin/bl"), "serve", str(root / "main.bl")],
    stdout=log, stderr=subprocess.STDOUT)
try:
    for _ in range(1200):
        if process.poll() is not None:
            raise RuntimeError(f"server exited; inspect {root / 'server.log'}")
        try:
            before = request("/health")
            break
        except Exception:
            time.sleep(.1)
    else:
        raise TimeoutError("server did not start")
    assert before["image"] == "release" and before["reload"] is True, before
    phase("baseline")
    phase("generation-upgrade", "/upgrade")
    phase("online-fjall-backfill", "/backfill", wait_backfill=True)
    phase("rejected-upgrade", "/refuse")
    phase("settled")
    after = request("/health")
    report = dict(runtime="source checkout with production policy", transport="Bandit HTTP loopback",
                  concurrency=8, rows=500, selection=args.selection, before=before, after=after, phases=phases,
                  same_vm=before["pid"] == after["pid"], same_owner=before["owner"] == after["owner"],
                  unique_responses=len(counts) == len(set(counts)),
                  consecutive_responses=sorted(counts) == list(range(1, len(counts) + 1)))
    (root / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)
    assert report["same_vm"] and report["same_owner"] and report["unique_responses"] and report["consecutive_responses"]
    assert all(not p["errors"] for p in phases)
    assert phases[1]["action"]["status"] == "applied"
    assert phases[2]["action"]["status"] == "started"
    assert after["ready-rows"] == 500 and after["durable-writes"] == len(counts)
    assert phases[3]["action"]["status"] == "refused"
finally:
    subprocess.run(["systemctl", "--user", "stop", unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    process.wait(timeout=30)
    log.close()
    print(f"Evidence: {root}")
