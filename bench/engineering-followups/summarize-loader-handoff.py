#!/usr/bin/env python3
"""Summarize interleaved loader handoff controls; fail closed on incomplete logs."""
import json
import re
import statistics
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
if "LOADER_HANDOFF_BENCH_OK" not in text:
    raise SystemExit("benchmark has no completion receipt")
samples = {}
for match in re.finditer(r"HANDOFF_SAMPLE (\d+) :([\w-]+) (\{[^\n]+\})", text):
    round_id, mode, payload = match.groups()
    values = {key: int(value) for key, value in re.findall(r":([\w-]+) (\d+)", payload)}
    key = (int(round_id), mode)
    if key in samples:
        raise SystemExit(f"duplicate sample: {key}")
    samples[key] = values

modes = ("direct", "adapted", "initializer-direct", "initializer-adapted", "causal")
expected = {(round_id, mode) for round_id in range(8) for mode in modes}
if samples.keys() != expected:
    raise SystemExit(f"unexpected sample inventory: {samples.keys() ^ expected}")
summary = {"rounds": 8, "iterations_per_round": 100, "modes": {}}
for mode in modes:
    rows = [samples[round_id, mode] for round_id in range(8)]
    if any(row.get("iterations") != 100 for row in rows):
        raise SystemExit("iteration count differs from protocol")
    summary["modes"][mode] = {
        key: statistics.median(row[key] / row["iterations"] for row in rows)
        for key in ("wall-us", "caller-reductions", "vm-reductions")
    }
    summary["modes"][mode]["wall-us-per-call-range"] = [
        min(row["wall-us"] / 100 for row in rows), max(row["wall-us"] / 100 for row in rows)
    ]
summary["paired_median_wall_ratios"] = {
    label: statistics.median(samples[r, candidate]["wall-us"] / samples[r, control]["wall-us"]
                             for r in range(8))
    for label, candidate, control in (
        ("ordinary_adapter_over_direct", "adapted", "direct"),
        ("initializer_handoff_over_blocking", "initializer-adapted", "initializer-direct"),
    )
}
baseline = re.search(r"HANDOFF_BASELINE :bounded-timeout (\d+)", text)
if not baseline:
    raise SystemExit("bounded deadlock control did not prove timeout")
summary["unadapted_cycle_timeout_us"] = int(baseline[1])
summary["interpretation"] = (
    "Per-call medians from alternating sample order; VM reductions include participating workers. "
    "The 100ms timeout bounds the unsafe cycle control. Causal mode proves completion and includes "
    "an extra nested load; ratios describe overhead, not a universal startup speedup."
)
print(json.dumps(summary, indent=2))
