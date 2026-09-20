#!/usr/bin/env bash
# run.sh — run every VPS spike, cold, and summarize PASS/FAIL.
# Usage: research/vps_spike/run.sh   (from the worktree root)
set -u
cd "$(dirname "$0")/../.." || exit 2
BL=./blx
pass=0; fail=0
for f in research/vps_spike/0*.bl; do
  name=$(basename "$f" .bl)
  out=$(BL_DAEMON=off "$BL" run "$f" 2>&1 | grep -vE "unknown key schedules")
  line=$(printf '%s\n' "$out" | grep -E "^(PASS|FAIL) ")
  if printf '%s' "$line" | grep -q "^PASS"; then
    pass=$((pass+1)); echo "✓ $line"
  else
    fail=$((fail+1)); echo "✗ $name"; printf '%s\n' "$out" | tail -20 | sed 's/^/    /'
  fi
done
echo "──────────────────────────────────────────"
echo "vps_spike: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
