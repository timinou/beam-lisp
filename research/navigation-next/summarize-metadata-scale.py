#!/usr/bin/env python3
"""Summarize complete balanced storage/read samples; never infer navigation gains."""
import collections
import json
import statistics
import sys

groups = collections.defaultdict(dict)
for line in open(sys.argv[1]):
    for prefix in ("metadata-storage-scale ", "metadata-selected-read "):
        if line.startswith(prefix):
            row = json.loads(line[len(prefix):])
            key = (prefix.strip(), row["nodes"], row["definitions"])
            sample = (row["kind"], row["round"])
            if sample in groups[key]:
                raise SystemExit(f"duplicate sample: {key} {sample}")
            groups[key][sample] = row

expected = {(kind, r) for kind in ("legacy", "incremental") for r in range(4)}
if len(groups) != 12 or any(set(rows) != expected for rows in groups.values()):
    raise SystemExit("incomplete benchmark: need 8 storage and 4 selected-read groups, 8 samples each")
for key, rows in sorted(groups.items()):
    result = {"measurement": key[0], "nodes": key[1], "definitions": key[2], "rounds": 4}
    for metric in ("reductions", "elapsed-us"):
        medians = {
            kind: statistics.median(rows[(kind, r)][metric] for r in range(4))
            for kind in ("legacy", "incremental")
        }
        result[metric] = {**medians, "legacy/incremental": medians["legacy"] / medians["incremental"]}
    print(json.dumps(result, sort_keys=True))
