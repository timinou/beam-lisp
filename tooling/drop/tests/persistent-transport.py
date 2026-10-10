#!/usr/bin/env python3
"""Actual first-ever service dispatch. Accept a launcher and an installed build.
This checks launcher ownership only; vm/service_test.bl checks service semantics.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

p = argparse.ArgumentParser()
p.add_argument("--launcher", required=True)
p.add_argument("--build", required=True)
a = p.parse_args()
launcher = str(Path(a.launcher).resolve())
with tempfile.TemporaryDirectory(prefix="bl-persistent-transport-") as scratch:
    root = Path(scratch)
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    (root / "env.bl").write_text('{:name "persistent-transport-test" :vm "shared" '
                                ':tasks {"host" {:run "host.bl" :service true}}}')
    (root / "host.bl").write_text('(println (str "OWNER " (System/pid)))')
    env = {**os.environ, "BL_USE": f"build:{a.build}", "XDG_RUNTIME_DIR": str(runtime),
           "XDG_STATE_HOME": str(root / "state")}
    owners = []
    try:
        samples = []
        for _ in range(2):
            start = time.perf_counter()
            r = subprocess.run([launcher, "host"], cwd=root, env=env,
                               text=True, capture_output=True, timeout=180)
            assert r.returncode == 0, (r.stdout, r.stderr)
            pid = int(next(line[6:] for line in r.stdout.splitlines() if line.startswith("OWNER ")))
            owners.append(pid)
            assert Path(f"/proc/{pid}").exists(), "task returned from a temporary VM"
            samples.append((time.perf_counter() - start) * 1000)
        assert owners[0] == owners[1], "first and second tasks had different owners"
        print(json.dumps({"build": a.build, "same_owner": True, "owner": owners[0], "ms": samples}))
    finally:
        # Discover even a daemon whose startup failed before the task returned.
        for proc in Path("/proc").iterdir():
            if not proc.name.isdigit():
                continue
            try:
                if f"XDG_RUNTIME_DIR={runtime}".encode() + b"\0" in (proc / "environ").read_bytes():
                    cmd = (proc / "cmdline").read_bytes()
                    if b"BeamLisp" in cmd:
                        os.kill(int(proc.name), signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                pass
