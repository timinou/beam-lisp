#!/usr/bin/env python3
"""Run one disjoint partition of the complete conventional test corpus."""
import argparse
import os
from pathlib import Path
import subprocess
import signal
import tempfile
import time


def partitions(root, count):
    if count < 1:
        raise ValueError("count must be positive")
    files = []
    for directory, dirs, names in os.walk(root / "test"):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in names:
            if name.endswith(("_test.bl", "_test.exs")):
                files.append(str((Path(directory) / name).relative_to(root)))
    return [sorted(files)[index::count] for index in range(count)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=int, required=True)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    if not 0 <= args.index < args.count:
        parser.error("index must be within [0, count)")
    root = Path(__file__).resolve().parent.parent
    selected = partitions(root, args.count)[args.index]
    if not selected:
        parser.error("empty shard")
    print(f"Shard {args.index + 1}/{args.count}: {len(selected)} test files", flush=True)
    if args.list:
        print("\n".join(selected))
        return 0
    # One VM per shard. Independent runners provide isolation; each runner
    # executes its files serially under a cap, including any child processes.
    command = ["systemd-run", "--user", "--collect", "--wait", "--pipe", "--quiet",
               f"--working-directory={root}", "--property=MemoryMax=6G",
               "--property=MemorySwapMax=0", "--property=RuntimeMaxSec=2700",
               f"--setenv=PATH={os.environ.get('PATH', '')}",
               "--setenv=BL_TEST_TIMES=1",
               str(root / "bin/bl"), "--cold", "test", *selected]
    runtime_parent = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    with tempfile.TemporaryDirectory(prefix="bl-ci-runtime-", dir=runtime_parent) as runtime:
        # Keep automatic checkout endpoints local to this shard. Preserve the
        # manager's actual bus address for capped subprocess verifiers.
        bus = os.environ.get("DBUS_SESSION_BUS_ADDRESS",
                             f"unix:path={runtime_parent}/bus")
        command[command.index(str(root / "bin/bl")):command.index(str(root / "bin/bl"))] = [
            f"--setenv=XDG_RUNTIME_DIR={runtime}",
            f"--setenv=DBUS_SESSION_BUS_ADDRESS={bus}"]
        try:
            return subprocess.call(command, cwd=root)
        finally:
            owned = []
            for proc in Path("/proc").iterdir():
                if not proc.name.isdigit():
                    continue
                try:
                    if (f"XDG_RUNTIME_DIR={runtime}".encode() + b"\0" in (proc / "environ").read_bytes()
                            and b"beam_lisp" in (proc / "cmdline").read_bytes()):
                        owned.append(int(proc.name))
                        os.kill(int(proc.name), signal.SIGTERM)
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    pass
            deadline = time.monotonic() + 5
            while owned and time.monotonic() < deadline:
                owned = [pid for pid in owned if Path(f"/proc/{pid}").exists()]
                if owned:
                    time.sleep(0.05)
            for pid in owned:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())
