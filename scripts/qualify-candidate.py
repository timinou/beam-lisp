#!/usr/bin/env python3
"""Qualify an exact drop, retaining resumable per-file results and durations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    with open(path, "rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def source_digest(root):
    tracked = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root)
    result = hashlib.sha256()
    for name in sorted(set(tracked.split(b"\0")) - {b""}):
        path = root / os.fsdecode(name)
        if path.is_file():
            result.update(name + b"\0" + digest(path).encode() + b"\0")
    return result.hexdigest()


def completed(path, identity):
    rows = {}
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue  # A power interruption can leave one incomplete last receipt.
            if row.get("identity") == identity and "file" in row:
                rows[row["file"]] = row
    return rows


def batch_status(path, identity):
    status = -1
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("identity") == identity and row.get("type") == "batch":
                status = row["process_status"]
    return status


def stop_children(runtime):
    """Stop only checkout endpoints belonging to this qualification request."""
    owned = []
    for process in Path("/proc").glob("[0-9]*"):
        try:
            if (f"XDG_RUNTIME_DIR={runtime}".encode() + b"\0" in (process / "environ").read_bytes()
                    and any(name in (process / "cmdline").read_bytes().lower()
                            for name in (b"beam_lisp", b"beamlisp."))):
                pid = int(process.name)
                os.kill(pid, signal.SIGTERM)
                owned.append(pid)
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            pass
    deadline = time.monotonic() + 3
    while owned and time.monotonic() < deadline:
        owned = [pid for pid in owned if Path(f"/proc/{pid}").exists()]
        if owned:
            time.sleep(0.05)
    for pid in owned:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def process_groups(files, isolated):
    warm = [name for name in files if name not in isolated]
    return ([warm] if warm else []) + [[name] for name in files if name in isolated]


def separate_last_record(path):
    """Preserve an interrupted record while keeping the next append parseable."""
    if path.exists() and path.stat().st_size:
        with path.open("rb+") as stream:
            stream.seek(-1, os.SEEK_END)
            if stream.read(1) != b"\n":
                stream.seek(0, os.SEEK_END)
                stream.write(b"\n")
                stream.flush()
                os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("files", nargs="+")
    args = parser.parse_args()
    candidate = args.candidate.resolve()
    identity = {"candidate": digest(candidate), "source": source_digest(ROOT)}
    prior = completed(args.results, identity) if args.resume else {}
    files = list(dict.fromkeys(args.files))
    pending = [name for name in files if name not in prior]
    args.results.parent.mkdir(parents=True, exist_ok=True)
    status = batch_status(args.results, identity) if args.resume else -1
    if pending:
        env = dict(os.environ, BL_QUALIFY_FILES="\n".join(pending),
                   BL_QUALIFY_TIMEOUT_MS=str(args.timeout * 1000), BL_TEST_SOURCE_ROOT=str(ROOT),
                   BL_DAEMON="off", BL_TEST_TIMES="1", BL_QUALIFY_CANDIDATE=str(candidate))
        # Source inputs belong to tests; compiler/runtime inputs belong to the
        # selected artifact. A developer shell must not redirect the candidate
        # to checkout hosts, a source path, or a different installed release.
        for name in ("BL_ROOT", "BL_EBIN", "BL_BIN", "BEAM_LISP_EBIN", "BL_USE",
                     "BL_CHECKOUT_ROOT", "BL_CHECKOUT_COLD", "BL_CHECKOUT_GENERATION",
                     "BL_CHECKOUT_SOURCE_GENERATION", "BEAM_LISP_PATH"):
            env.pop(name, None)
        isolated = json.loads((ROOT / "scripts/test-isolation.json").read_text())
        groups = process_groups(pending, isolated)
        status = 0
        separate_last_record(args.results)
        with args.results.open("a", buffering=1) as receipts:
            while groups:
                selected = groups.pop(0)
                env["BL_QUALIFY_FILES"] = "\n".join(selected)
                reported, handover = set(), False
                # Each process owns its endpoint directory. Lifetime handovers and
                # privileged fixtures stay serial inside the caller's tree cap.
                # Preserve the host's runtime-filesystem contract as well as
                # endpoint isolation (health publishers reject /tmp sockets).
                with tempfile.TemporaryDirectory(prefix="bl-qualify-",
                        dir=os.environ.get("XDG_RUNTIME_DIR")) as runtime:
                    env["XDG_RUNTIME_DIR"] = runtime
                    command = [str(candidate), "--cold", "run", str(ROOT / "scripts/qualify-candidate.bl")]
                    process = subprocess.Popen(command, cwd=ROOT, env=env, text=True,
                                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    try:
                        for line in process.stdout:
                            print(line, end="", flush=True)
                            if line.startswith("BL-QUALIFY "):
                                row = json.loads(line.removeprefix("BL-QUALIFY "))
                                if row.get("file") not in selected:
                                    raise RuntimeError("Candidate reported an unrequested test file")
                                if (row["file"].endswith(("_test.bl", "_test.exs"))
                                        and not any(row.get(key, 0) for key in ("tests", "pass", "fail", "error"))):
                                    row.update(status="incoherent", error=1)
                                    row.setdefault("details", []).append({
                                        "test": "suite-discovery", "actual":
                                        "No tests or assertions ran in this file's declared namespace"})
                                reported.add(row["file"])
                                row["identity"] = identity
                                receipts.write(json.dumps(row, sort_keys=True) + "\n")
                                receipts.flush()
                                os.fsync(receipts.fileno())
                            elif line.startswith("BL-QUALIFY-HANDOVER "):
                                row = json.loads(line.removeprefix("BL-QUALIFY-HANDOVER "))
                                handover = True
                                receipts.write(json.dumps({"type": "handover", "identity": identity,
                                                           **row}) + "\n")
                        current_status = process.wait()
                        status = status or current_status
                        receipts.write(json.dumps({"type": "process", "identity": identity,
                                                   "files": selected, "process_status": current_status}) + "\n")
                        receipts.flush()
                        os.fsync(receipts.fileno())
                    finally:
                        if process.poll() is None:
                            process.terminate()
                            process.wait()
                        process.stdout.close()
                        stop_children(runtime)
                remaining = [name for name in selected if name not in reported]
                if handover and reported and remaining and current_status in (0, 1):
                    groups.insert(0, remaining)
                if current_status not in (0, 1):
                    print(f"Candidate process failed with status {current_status}", flush=True)
            receipts.write(json.dumps({"type": "batch", "identity": identity,
                                       "process_status": status}) + "\n")
            receipts.flush()
            os.fsync(receipts.fileno())
    rows = completed(args.results, identity)
    missing = [name for name in files if name not in rows]
    failed = [name for name in files if name in rows and rows[name]["fail"] + rows[name]["error"]]
    changed = source_digest(ROOT) != identity["source"] or digest(candidate) != identity["candidate"]
    print(json.dumps({"candidate": identity["candidate"], "files": len(files),
                      "completed": len(files) - len(missing), "failed": failed, "missing": missing,
                      "inputs_changed": changed, "process_status": status}, indent=2))
    return int(bool(missing or failed or changed or status != 0))


if __name__ == "__main__":
    raise SystemExit(main())
