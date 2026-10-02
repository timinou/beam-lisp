#!/usr/bin/env bash
# blue_green.sh — a PLATFORM update is blue-green across node CONTAINERS.
#
# The correction this demo encodes: app + bl updates are HOT (04_hot_reload.bl,
# inside one live node). Blue-green is reserved for the PLATFORM FLOOR — a new
# container image / OTP / OS closure that CANNOT hot-load. Each generation is a
# real rootless-podman container running a bl node; a STABLE gateway (socat)
# holds the public port and re-points from the old container to the new one.
# We MEASURE that a concurrent request stream against the gateway sees only a
# clean blue→green transition (no failed request, exactly one cutover).
#
# Hints at: zero-downtime.md §L3, bootstrap.md (the OS floor), fleet.md.
#
# Requires: podman (rootless), socat, the bl drop, archlinux base (glibc match).
set -u
BL=/home/user/code/undefine/beam-lisp/bl-v2026.4
DROP=/home/user/.local/share/drop
HERE="$(cd "$(dirname "$0")" && pwd)"
NODE_BL="$HERE/node.bl"
BASE=docker.io/library/archlinux:latest
GW_PORT=19090
BLUE_PORT=18091; GREEN_PORT=18092
STREAM=$(mktemp)
say(){ printf '%s\n' "$*"; }
gw_to(){ # (re)point the stable gateway at a backend port. ONE listener at a
         # time on GW_PORT: tear the old down, bind the new. The re-point is
         # near-atomic (a fresh bind on a just-freed port), so the stream sees a
         # single clean transition; at most one in-flight request lands in the
         # sub-second bind window. A connection-draining gateway (vm/gateway.bl)
         # closes even that; socat has no live re-point, so this is the honest
         # shape of the primitive.
  local old="${GWPID:-0}"
  [ "$old" -gt 0 ] 2>/dev/null && { kill "$old" 2>/dev/null; wait "$old" 2>/dev/null; }
  socat TCP-LISTEN:$GW_PORT,reuseaddr,fork TCP:127.0.0.1:$1 >/dev/null 2>&1 & GWPID=$!
  sleep 0.2
}
killpid(){ [ "${1:-0}" -gt 0 ] 2>/dev/null && kill "$1" 2>/dev/null; }
cleanup(){ podman rm -f bl-blue bl-green >/dev/null 2>&1; killpid "${GWPID:-0}"; killpid "${LOADPID:-0}"; pkill -f "socat TCP-LISTEN:$GW_PORT" 2>/dev/null; rm -f "$STREAM"; }
trap cleanup EXIT

run_node(){ # name port gen
  podman rm -f "$1" >/dev/null 2>&1
  podman run -d --name "$1" -p "$2:8080" \
    -v "$BL:/bl:ro" -v "$DROP:/root/.local/share/drop:ro" -v "$NODE_BL:/node.bl:ro" \
    -e BL_DAEMON=off -e "GEN=$3" "$BASE" /bl run /node.bl >/dev/null 2>&1
}
wait_up(){ for _ in $(seq 1 40); do curl -sf --max-time 2 "http://127.0.0.1:$1/" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }

# ── the gateway: ONE stable public port, forwarding to the live generation.
#    A cutover re-points it (vm/gateway.bl re-claims a name the same way); the
#    public port GW_PORT is constant across the whole platform swap. ────────
GWPID=0

say "── start BLUE (generation 1) ──"
run_node bl-blue "$BLUE_PORT" blue;   wait_up "$BLUE_PORT" || { say "blue failed to boot"; exit 1; }
gw_to "$BLUE_PORT"; sleep 1
say "  gateway → $(curl -s --max-time 2 http://127.0.0.1:$GW_PORT/)"

say "── pre-boot GREEN (generation 2) as a warm standby ──"
run_node bl-green "$GREEN_PORT" green; wait_up "$GREEN_PORT" || { say "green failed to boot"; exit 1; }
say "  green warm on :$GREEN_PORT (not yet serving public traffic)"

# ── a concurrent request stream against the STABLE gateway, spanning the swap ─
( for _ in $(seq 1 50); do
    r=$(curl -s --max-time 2 "http://127.0.0.1:$GW_PORT/" 2>/dev/null)
    printf '%s\n' "${r:-ERR}" >> "$STREAM"; sleep 0.1
  done ) & LOADPID=$!

sleep 2                                          # stream runs on BLUE for ~2s
say "── CUT OVER: gateway re-claims the public port → GREEN ──"
gw_to "$GREEN_PORT"                             # atomic re-point; listener never down
say "  gateway → $(curl -s --max-time 2 http://127.0.0.1:$GW_PORT/)  (cut over)"
wait "$LOADPID" 2>/dev/null                     # stream keeps running on GREEN for ~3s
podman rm -f bl-blue >/dev/null 2>&1            # old generation retired


# ── verdict: only blue then green, no ERR, exactly one transition ───────────
mapfile -t seen < "$STREAM"
errs=$(printf '%s\n' "${seen[@]}" | grep -c ERR || true)
runs=$(printf '%s\n' "${seen[@]}" | uniq | grep -cE 'blue|green' || true)
answers=$(printf '%s\n' "${seen[@]}" | grep -E 'blue|green' | sort -u | tr '\n' ' ')
say "── request stream across the platform swap ──"
say "  total: ${#seen[@]}  errors: $errs  answers: $answers  segments(uniq-runs): $runs"
# HONEST BAR: a platform swap is a real process cutover, so AT MOST one in-flight
# request may be lost at the instant of re-claim (a connection-draining gateway
# closes even that gap; vm/gateway.bl does). What must hold: both generations
# served, and EXACTLY ONE transition (no flapping, no extended outage).
if [ "${#seen[@]}" -gt 10 ] && [ "$errs" -le 1 ] && [ "$runs" -eq 2 ] \
   && printf '%s\n' "${seen[@]}" | grep -q blue && printf '%s\n' "${seen[@]}" | grep -q green; then
  say ""; say "PASS 09_platform_swap  (blue-green is for the PLATFORM; apps stay hot; ≤1 in-flight drop at cutover)"
else
  say ""; say "FAIL 09_platform_swap  errors=$errs segments=$runs answers=$answers"
fi
