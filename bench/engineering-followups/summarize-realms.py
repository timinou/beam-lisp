#!/usr/bin/env python3
"""Summarize complete counterbalanced realm-package trials; reject partial runs."""
import re
import statistics
import sys
from pathlib import Path
rows = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if ':trial ' not in line:
        continue
    trial = int(re.search(r':trial (\d+)', line)[1])
    mode = re.search(r':mode :(source|warm|package)', line)[1]
    elapsed = int(re.search(r':elapsed-us (\d+)', line)[1])
    reductions = int(re.search(r':caller-reductions (\d+)', line)[1])
    assert re.search(r':oracle 64(?:\s|})', line), line
    assert (trial, mode) not in rows, 'duplicate trial'
    rows[trial, mode] = elapsed, reductions
assert set(rows) == {(t, m) for t in range(6) for m in ('source', 'warm', 'package')}, 'incomplete run'
for mode in ('source', 'warm', 'package'):
    print(mode, 'median_us=', statistics.median(rows[t, mode][0] for t in range(6)),
          'median_caller_reductions=', statistics.median(rows[t, mode][1] for t in range(6)))
for baseline in ('source', 'warm'):
    print(baseline + '/package paired median elapsed ratio=',
          statistics.median(rows[t, baseline][0] / rows[t, 'package'][0] for t in range(6)))
