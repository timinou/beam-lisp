#!/usr/bin/env python3
"""Abrupt VM halt then reopen the same Fjall store; HOME scratch only."""
import json
import os
from pathlib import Path
import subprocess
import time

repo = Path(__file__).resolve().parents[2]
root = Path.home() / "tmp/live-migration" / f"restart-{time.time_ns()}"
root.mkdir(parents=True, mode=0o700)
commands = []
for mode in ("crash", "resume"):
    command = ["systemd-run", "--user", "--collect", "--wait", "--pipe",
               f"--working-directory={repo}", "--property=MemoryMax=4G", "--property=MemorySwapMax=1G",
               "env", f"TMPDIR={root}", f"LIVE_MIGRATION_ROOT={root}", "timeout", "180",
               str(repo / "bin/bl"), "run", str(repo / "research/live-migration/restart.bl"), "--", mode]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=210)
    (root / f"{mode}.log").write_text(result.stdout)
    commands.append(dict(mode=mode, exit_code=result.returncode))
    if mode == "crash":
        assert result.returncode == 137 and "CRASH after 60 durable backfill rows" in result.stdout, result.stdout
    else:
        assert result.returncode == 0, result.stdout
        receipt = next(json.loads(line) for line in result.stdout.splitlines() if line.startswith('{"'))
report = dict(boundary="abrupt VM halt and process restart; not power loss", commands=commands, receipt=receipt)
(root / "results.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
print(f"Evidence: {root}")
