#!/usr/bin/env python3
"""Summarize a single native retirement run; descriptive, not a confidence interval."""
import json
import statistics
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text().splitlines()
metadata = [json.loads(line.removeprefix('RUNTIME_META ')) for line in lines if line.startswith('RUNTIME_META ')]
rows = [json.loads(line.removeprefix('RUNTIME_JSON ')) for line in lines if line.startswith('RUNTIME_JSON ')]
if len(metadata) != 1 or metadata[0]['tracked-dirty?']:
    raise SystemExit('Require one clean tracked source revision')
def one(area):
    values = [row['data'] for row in rows if row['area'] == area]
    if len(values) != 1:
        raise SystemExit(f'Require exactly one {area} receipt')
    return values[0]
reads = {variant: statistics.median(row['data']['us'] / row['data']['value']
                                   for row in rows if row['area'] == 'retirement-read'
                                   and row['data']['variant'] == variant)
         for variant in ['ordinary', 'indexed']}
writes = {label: one(area)['us'] / 10 for label, area in [
    ('baseline', 'retirement-baseline-writes'),
    ('maintained', 'retirement-maintained-writes'),
    ('retired', 'retirement-after-writes')]}
cleanup = one('retirement-cleanup')
print(json.dumps({'metadata': metadata[0], 'read_us_per_operation': reads,
                  'write_us_per_transaction': writes,
                  'maintained_over_retired_write_ratio': writes['maintained'] / writes['retired'],
                  'build': one('retirement-build'),
                  'cleanup': {'us': cleanup['us'], 'transactions': cleanup['value']},
                  'limits': 'One native 100-entity store; sequential write phases; ABBA read blocks; no confidence interval or universal speedup claim.'}, indent=2))
