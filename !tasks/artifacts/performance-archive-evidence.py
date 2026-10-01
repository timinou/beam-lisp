#!/usr/bin/env python3
"""Retain an immutable, hashed copy of the observed performance checkpoint logs."""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FINAL = "--final" in sys.argv
CHECKPOINT = "final-continuation" if FINAL else "foundation-checkpoint"
OUT = ROOT / "performance-evidence" / CHECKPOINT
NAMES = [
    "bl-performance-published-cli-final-158e8a77.log",
    "bl-performance-postfix-startup-profile-158e8a77.log",
    "bl-performance-postfix-incremental-158e8a77.log",
    "bl-performance-postfix-lazy-158e8a77.log",
    "bl-performance-final-image-audit-158e8a77.log",
    "bl-performance-final-loading-gates-158e8a77.log",
    "bl-performance-final-memo-gates-158e8a77.log",
    "bl-performance-published-abi-gates-158e8a77.log",
    "bl-performance-cold-shim-loader-gates-158e8a77.log",
    "bl-performance-current-release-158e8a77.log",
    "bl-performance-release-smoke-158e8a77.log",
]
if FINAL:
    NAMES = [
        "bl-performance-final-continuation-gates-158e8a77.log",
        "bl-performance-final-published-gates-158e8a77.log",
        "bl-performance-final-cli-benchmarks-158e8a77.log",
        "bl-performance-final-lazy-benchmarks-158e8a77.log",
        "bl-performance-final-incremental-benchmarks-158e8a77.log",
        "bl-performance-final-release-158e8a77.log",
        "bl-performance-final-release-smoke-158e8a77.log",
        "bl-performance-final-package-audit-158e8a77.log",
    ]



def main():
    OUT.mkdir(parents=True, exist_ok=True)
    records = []
    for name in NAMES:
        source = Path("/tmp") / name
        data = source.read_bytes()
        if not data:
            raise ValueError(f"empty evidence: {source}")
        target = OUT / name
        if target.exists():
            if target.read_bytes() != data:
                raise ValueError(f"refusing to replace a distinct checkpoint: {target}")
        else:
            with target.open("xb") as stream:
                stream.write(data)
        records.append({"source": str(source), "file": name,
                        "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    index = json.dumps({"checkpoint": CHECKPOINT if FINAL else "published foundation, before final callable/analysis wave",
                        "logs": records}, indent=2) + "\n"
    index_path = OUT / "index.json"
    if index_path.exists() and index_path.read_text() != index:
        raise ValueError(f"refusing to replace a distinct index: {index_path}")
    if not index_path.exists():
        with index_path.open("x") as stream:
            stream.write(index)
    print(json.dumps({"archived": len(records), "directory": str(OUT)}))


if __name__ == "__main__":
    main()
