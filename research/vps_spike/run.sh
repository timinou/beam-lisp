#!/usr/bin/env bash
# run.sh — run every VPS spike and summarize PASS/FAIL.
#   research/vps_spike/run.sh            bl spikes (01-08); brings Garage up for 06
#   research/vps_spike/run.sh --podman   also run 09 platform-swap (rootless podman,
#                                        under a systemd cgroup — see podman/scoped.sh)
#
# The bl spikes are light and run in-process. The container demo (09) is heavy
# and is ALWAYS run detached under a hard memory/tasks cgroup, because a runaway
# platform-swap must never starve the host — the design's blast-radius thesis,
# applied to the harness itself.
set -u
cd "$(dirname "$0")/../.." || exit 2
BL=./blx
HERE=research/vps_spike

# ── Garage (real S3) for 06_backups_dr; degrades to in-memory if it can't start ─
if [ -x "$HERE/garage/up.sh" ] && command -v garage >/dev/null 2>&1; then
  if "$HERE/garage/up.sh" >/dev/null 2>&1 && [ -f /tmp/vps-garage/creds.env ]; then
    set -a; . /tmp/vps-garage/creds.env; set +a; echo "· garage up ($S3_ENDPOINT)"
  else
    echo "· garage unavailable — 06 runs in-memory"
  fi
fi

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

# ── 09 platform-swap: real containers, detached + capped, polled ────────────
if [ "${1:-}" = "--podman" ]; then
  if command -v podman >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1; then
    echo "· 09_platform_swap: rootless podman under a systemd cgroup (detached)"
    rm -f /tmp/bg.out; systemctl --user reset-failed bl-bg 2>/dev/null
    systemd-run --user --unit=bl-bg --collect \
      -p MemoryMax=1200M -p MemorySwapMax=0 -p TasksMax=96 -p RuntimeMaxSec=150 \
      -p "StandardOutput=file:/tmp/bg.out" -p "StandardError=file:/tmp/bg.out" \
      -p "WorkingDirectory=$PWD" \
      bash "$HERE/podman/blue_green.sh" >/dev/null 2>&1
    for _ in $(seq 1 60); do
      [ "$(systemctl --user is-active bl-bg 2>/dev/null)" = "inactive" ] && break; sleep 3
    done
    line=$(grep -E "^(PASS|FAIL) " /tmp/bg.out 2>/dev/null | tail -1)
    if printf '%s' "$line" | grep -q "^PASS"; then pass=$((pass+1)); echo "✓ $line"
    else fail=$((fail+1)); echo "✗ 09_platform_swap"; tail -8 /tmp/bg.out 2>/dev/null | sed 's/^/    /'; fi
  else
    echo "· 09_platform_swap skipped (needs podman + systemd-run)"
  fi
fi

echo "──────────────────────────────────────────"
echo "vps_spike: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
