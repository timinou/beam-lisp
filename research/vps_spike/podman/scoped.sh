#!/usr/bin/env bash
# scoped.sh — run a command under a hard resource cgroup, so a runaway dies in
# its OWN scope and never starves the host. This is the VPS design's blast-radius
# thesis (devops.md §identity/blast-radius, the OS floor) applied to the demo
# harness itself: a platform-swap experiment that fork-bombs or leaks memory
# hits MemoryMax/TasksMax and is killed by the kernel, host untouched.
#
# Usage: research/vps_spike/podman/scoped.sh [MEM] [TASKS] -- cmd args...
#        research/vps_spike/podman/scoped.sh                 (defaults: 1G/96, runs blue_green.sh)
set -u
MEM="${1:-1G}"; TASKS="${2:-96}"
HERE="$(cd "$(dirname "$0")" && pwd)"
shift 2 2>/dev/null
[ "${1:-}" = "--" ] && shift
CMD=("$@"); [ ${#CMD[@]} -eq 0 ] && CMD=(bash "$HERE/blue_green.sh")

exec systemd-run --user --scope --collect \
  -p MemoryMax="$MEM" -p MemorySwapMax=0 -p TasksMax="$TASKS" \
  -p RuntimeMaxSec=200 \
  --unit="bl-vps-spike-$$" \
  "${CMD[@]}"
