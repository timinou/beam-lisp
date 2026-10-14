#!/usr/bin/env python3
"""Create the reviewed benchmark-only cache bypass; never edit SDK sources."""
import argparse
import hashlib
import pathlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=pathlib.Path)
parser.add_argument("--revision", default="HEAD")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[2]
source = subprocess.check_output(
    ["git", "show", f"{args.revision}:priv/std/reload/generation.bl"], cwd=root, text=True
)
changes = [
    ("(ns reload.generation\n", "(ns reload.generation-inventory-baseline\n"),
    ("modules (set (mapcat #(analyzed-namespace-modules planned %) names))",
     "modules (set (mapcat namespace-modules names))"),
    ('(set (analyzed-namespace-modules planned "reload.binding"))',
     '(set (namespace-modules "reload.binding"))'),
]
for before, after in changes:
    if source.count(before) != 1:
        raise SystemExit(f"Reviewed source shape changed: {before}")
    source = source.replace(before, after, 1)
output = args.output.expanduser().resolve()
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(source)
print(hashlib.sha256(source.encode()).hexdigest(), output)
