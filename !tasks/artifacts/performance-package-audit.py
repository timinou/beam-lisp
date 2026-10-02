#!/usr/bin/env python3
"""Verify compound payload integrity and compare its floor/NIF with the checkout."""
import hashlib
import io
import json
import struct
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FORMAT = "<QQ32sBBH4s"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    package = Path(sys.argv[1])
    data = package.read_bytes()
    size = struct.calcsize(FORMAT)
    offset, length, digest, os_tag, arch_tag, version, magic = struct.unpack(FORMAT, data[-size:])
    assert magic == b"DRP1" and version == 1, "invalid compound trailer"
    assert offset + length == len(data) - size, "invalid compound payload boundary"
    payload = data[offset:offset + length]
    assert hashlib.sha256(payload).digest() == digest, "payload digest mismatch"
    floor = {p.name: p for p in (ROOT / "priv/bootstrap/seed").iterdir() if p.is_file()}
    checked = []
    mismatches = []
    authored_elixir = []
    native = []
    sources = []
    live_native = ROOT / "priv/native/lazy_memo.so"
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        for member in archive:
            if not member.isfile():
                continue
            name = member.name
            if "/priv/" in "/" + name and name.endswith((".bl", ".bl.md", ".bl.org", ".clj", ".cljc")):
                sources.append(name)
            if "/priv/" in "/" + name and name.endswith((".ex", ".exs")):
                authored_elixir.append(name)
            if "/priv/bootstrap/seed/" in "/" + name:
                expected = floor.get(Path(name).name)
                if expected is not None:
                    value = archive.extractfile(member).read()
                    checked.append(name)
                    if value != expected.read_bytes():
                        mismatches.append(name)
            if name.endswith("/priv/native/lazy_memo.so"):
                value = archive.extractfile(member).read()
                native.append({"path": name, "sha256": sha(value),
                               "matches_checkout": value == live_native.read_bytes()})
    result = {"package": str(package), "compound_bytes": len(data), "payload_bytes": length,
              "payload_sha256": digest.hex(), "target_tags": [os_tag, arch_tag],
              "floor_files_checked": len(checked), "floor_mismatches": mismatches,
              "native": native, "priv_elixir_sources": authored_elixir,
              "priv_lisp_sources": len(sources)}
    print(json.dumps(result, indent=2))
    assert len(checked) == len(floor), "packaged floor inventory differs"
    assert not mismatches, "packaged floor differs from checkout"
    assert len(native) == 1 and native[0]["matches_checkout"], "packaged native differs from checkout"
    assert not authored_elixir, "repository Elixir source leaked into priv payload"


if __name__ == "__main__":
    main()
