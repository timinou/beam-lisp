#!/usr/bin/env python3
"""Retain an immutable, hashed copy of the observed performance checkpoint logs."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--final", action="store_true")
parser.add_argument("--checkpoint", help="A new immutable checkpoint directory name")
parser.add_argument("--logs", nargs="+", type=Path, help="Observed logs for the named checkpoint")
args = parser.parse_args()
if bool(args.checkpoint) != bool(args.logs):
    parser.error("--checkpoint and --logs must be supplied together")
if args.checkpoint and (Path(args.checkpoint).name != args.checkpoint or args.checkpoint in {".", ".."}):
    parser.error("checkpoint must be a single directory name")
FINAL = args.final
CHECKPOINT = args.checkpoint or ("final-continuation" if FINAL else "foundation-checkpoint")
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
    sources = args.logs or [Path("/tmp") / name for name in NAMES]
    if len({source.name for source in sources}) != len(sources):
        raise ValueError("checkpoint logs must have distinct filenames")
    for source in sources:
        name = source.name
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
    index = json.dumps({"checkpoint": CHECKPOINT if (FINAL or args.checkpoint) else "published foundation, before final callable/analysis wave",
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
