#!/usr/bin/env python3
"""Summarize paired callback ownership overhead; no statistical claims."""
import json
import re
import statistics
import sys
from pathlib import Path

records = []
for line in Path(sys.argv[1]).read_text().splitlines():
    if "ASYNC-BENCH" not in line:
        continue
    pairs = dict(re.findall(r":([\w-]+)\s+(:[\w-]+|-?\d+)", line))
    record = {key: (value[1:] if value.startswith(":") else int(value))
              for key, value in pairs.items()}
    if set(record) != {"area", "variant", "trial", "operations", "elapsed-us",
                       "caller-reductions", "result"}:
        raise SystemExit(f"Malformed measurement: {line}")
    records.append(record)
expected = {("process-spawn", variant, trial) for variant in ("raw", "conveyed", "owned")
            for trial in range(6)} | {
                ("retained-invoke", variant, trial) for variant in ("direct", "registered")
                for trial in range(6)}
actual = {(r["area"], r["variant"], r["trial"]) for r in records}
if actual != expected or len(records) != len(expected):
    raise SystemExit("Missing, duplicated or unexpected trials")
summary = {}
for area, variants, expected_operations, expected_result in (
    ("process-spawn", ("raw", "conveyed", "owned"), 100, 100),
    ("retained-invoke", ("direct", "registered"), 1000, 500500),
):
    summary[area] = {}
    for variant in variants:
        rows = [r for r in records if r["area"] == area and r["variant"] == variant]
        if any(r["operations"] != expected_operations or r["result"] != expected_result
               or r["elapsed-us"] < 0 for r in rows):
            raise SystemExit("Operation/result oracle failed")
        summary[area][variant] = {
            "trials": len(rows), "operations-per-trial": expected_operations,
            "median-us-per-operation": statistics.median(r["elapsed-us"] for r in rows)
                                       / expected_operations,
            "median-caller-reductions-per-operation": statistics.median(
                r["caller-reductions"] for r in rows) / expected_operations,
        }
for area, before, after in (("process-spawn", "conveyed", "owned"),
                            ("retained-invoke", "direct", "registered")):
    baseline = summary[area][before]["median-us-per-operation"]
    protected = summary[area][after]["median-us-per-operation"]
    summary[area]["ownership-overhead"] = {
        "baseline": before, "added-us-per-operation": protected - baseline,
        "wall-ratio": protected / baseline if baseline else None,
    }
print(json.dumps({"status": "passed", "method": "six counterbalanced spawn trials; "
                  "six alternating invoke trials; descriptive medians, caller reductions only",
                  "areas": summary}, indent=2))
