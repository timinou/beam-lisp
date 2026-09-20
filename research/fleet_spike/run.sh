#!/usr/bin/env bash
# run.sh — run every fleet algorithm spike, print PASS/FAIL.
# Usage: research/fleet_spike/run.sh   (from the worktree root)
#
# These are pure-algorithm spikes (no containers, no network) — each implements a
# distributed algorithm in bl and asserts its defining property. Cold `blx` starts
# cost ~10-15s each, so the sweep takes a couple of minutes; that latency is boot.
set -u
cd "$(dirname "$0")/../.." || exit 2
BL=./blx
HERE=research/fleet_spike
pass=0; fail=0
for f in "$HERE"/[0-9][0-9]_*.bl; do
  name=$(basename "$f" .bl)
  out=$("$BL" run "$f" 2>&1 | grep -vE "unknown key schedules")
  line=$(printf '%s\n' "$out" | grep -E "^(PASS|FAIL) ")
  if printf '%s' "$line" | grep -q "^PASS"; then
    pass=$((pass+1)); echo "✓ $line"
  else
    fail=$((fail+1)); echo "✗ $name"; printf '%s\n' "$out" | tail -20 | sed 's/^/    /'
  fi
done
echo "──────────────────────────────────────────"
echo "fleet_spike: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
