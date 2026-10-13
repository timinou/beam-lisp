#!/usr/bin/env bash
# Own one capped source VM and one external Chromium. No production endpoints.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$HOME/tmp"
SCRATCH=$(mktemp -d "$HOME/tmp/ct-XXXXXX")
UNIT="continuity-demo-$BASHPID-$RANDOM"
PORT=${CONTINUITY_PORT:-4048}
URL="http://127.0.0.1:$PORT"
EVIDENCE=${CONTINUITY_EVIDENCE:-"$SCRATCH/evidence"}
export TMPDIR="$SCRATCH"
mkdir -p "$EVIDENCE"
cleanup() {
  systemctl --user stop "$UNIT.service" >/dev/null 2>&1 || true
  journalctl --user -u "$UNIT.service" --no-pager > "$SCRATCH/server.log" || true
  printf 'Sandbox stopped. Evidence: %s\nLogs: %s\n' "$EVIDENCE" "$SCRATCH"
}
trap cleanup EXIT
"$ROOT/scripts/bl-mem"
if curl --noproxy '*' --silent --max-time 2 "$URL/health/ready" >/dev/null; then
  echo "Port $PORT already serves an instance; choose CONTINUITY_PORT." >&2; exit 1
fi
systemd-run --user --unit="$UNIT" --working-directory="$ROOT" \
  --setenv="CONTINUITY_ROOT=$SCRATCH/data" --setenv="CONTINUITY_PORT=$PORT" --setenv="TMPDIR=$SCRATCH" \
  --property=MemoryMax=6G --property=MemorySwapMax=0 --property=RuntimeMaxSec=900 \
  "$ROOT/bin/bl" run examples/continuity/main.bl
deadline=$((SECONDS + 240))
until curl --noproxy '*' --fail --silent --max-time 2 "$URL/health/ready" >/dev/null; do
  if ! systemctl --user is-active --quiet "$UNIT.service" || ((SECONDS > deadline)); then
    journalctl --user -u "$UNIT.service" --no-pager -n 60; exit 1
  fi
  sleep .5
done
cd "$ROOT/test/browser"
CONTINUITY_URL="$URL" CONTINUITY_EVIDENCE="$EVIDENCE" \
  ./node_modules/.bin/playwright test --config=continuity.config.js
systemctl --user show "$UNIT.service" -p MemoryPeak -p CPUUsageNSec > "$EVIDENCE/service-resources.txt"
