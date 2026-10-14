#!/usr/bin/env python3
"""Materialize reviewed old/new actual Reader+rewrite controls; never start a VM.

Usage: python3 research/reload-contracts/namespace-rewrite-controls.py ~/tmp/rewrite-controls
Then BL_REWRITE_PROTOTYPE_DIR=... BL_REWRITE_REPORT=... ./bin/bl run research/reload-contracts/namespace-rewrite-benchmark.bl
The benchmark owns no business resources; each pure sample has a five-second cap.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

BASELINE = "6e09636737c5ed0b802270e7df258d8fa4b6a4e2"

def extracted(reader, generation, label):
    reader = reader.replace("(ns reader\n", f"(ns reader-rewrite-{label}\n", 1)
    helpers = generation[generation.index("(defn- children [node]"):generation.index("(defn- executable-symbols [node]")]
    begin = "(defn- rewrite-edits" if "(defn- rewrite-edits" in generation else "(declare rewrite-fragment)"
    rewrite = generation[generation.index(begin):generation.index("(defn- dependency-order")]
    prefix = f"(ns rewrite-{label} (:require [reader-node :as rn] [reader-rewrite-{label} :as reader]))\n"
    prefix += '(defn- refuse! [kind data] (throw (ex-info "Rewrite refused" (assoc data :kind kind))))\n'
    return {f"reader-rewrite-{label}.bl": reader, f"rewrite-{label}.bl": prefix + helpers + rewrite.rstrip() + "\n"}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--candidate-revision", help="Immutable Git revision; defaults to reviewed current working files")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    destination = args.destination.expanduser().resolve()
    home_tmp = (Path.home() / "tmp").resolve()
    if home_tmp not in destination.parents:
        parser.error("destination must be a fresh directory below ~/tmp")
    destination.mkdir(parents=True, exist_ok=False)
    def source(path, revision):
        if revision:
            return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=repo).decode()
        return (repo / path).read_text()
    results = {}
    for label, revision in [("baseline", BASELINE), ("candidate", args.candidate_revision)]:
        for name, text in extracted(source("priv/boot/reader.bl", revision), source("priv/std/reload/generation.bl", revision), label).items():
            payload = text.encode()
            (destination / name).write_bytes(payload)
            results[name] = hashlib.sha256(payload).hexdigest()
    report = {"baseline-revision": BASELINE, "candidate-revision": args.candidate_revision or "working-tree", "snapshot-sha256": results}
    (destination / "provenance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
