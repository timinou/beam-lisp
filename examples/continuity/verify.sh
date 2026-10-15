#!/usr/bin/env bash
# Own one capped source VM and one external Chromium. No production endpoints.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
RUNTIME=${CONTINUITY_BL:-"$ROOT/bin/bl"}
case "$RUNTIME" in
  /*) ;;
  *) echo "CONTINUITY_BL must name an absolute executable launcher." >&2; exit 1 ;;
esac
if [[ ! -f "$RUNTIME" || ! -x "$RUNTIME" ]]; then
  echo "Selected continuity launcher must be an executable file." >&2; exit 1
fi
mkdir -p "$HOME/tmp"
SCRATCH=$(mktemp -d "$HOME/tmp/ct-XXXXXX")
UNIT="continuity-demo-$BASHPID-$RANDOM"
PORT=${CONTINUITY_PORT:-4048}
URL="http://127.0.0.1:$PORT"
EVIDENCE=${CONTINUITY_EVIDENCE:-"$SCRATCH/evidence"}
export TMPDIR="$SCRATCH"
# Record exact launcher selection before any native command. This is input
# provenance, not proof of a bootable SDK or a successful browser acceptance.
python3 - "$RUNTIME" "$EVIDENCE" <<'PY_INPUT'
import hashlib, json, os, stat, sys
from pathlib import Path
runtime, evidence = Path(sys.argv[1]), Path(sys.argv[2])
home_tmp = Path.home() / 'tmp'
assert evidence.is_absolute() and evidence == Path(os.path.normpath(evidence)) and home_tmp in evidence.parents, 'Evidence must use normalized HOME/tmp'
for parent in (evidence, *evidence.parents):
    if parent.exists() or parent.is_symlink():
        info = parent.lstat()
        assert not stat.S_ISLNK(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o022, 'Protected evidence ancestry required'
    if parent == Path.home():
        break
evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
assert not evidence.stat().st_mode & 0o077, 'Owner-only evidence directory required'
digest = hashlib.sha256()
with runtime.open('rb') as source:
    for block in iter(lambda: source.read(1024 * 1024), b''):
        digest.update(block)
fd = os.open(evidence / 'launcher-input.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    raw = json.dumps({'scope': 'source-continuity-launcher-selection/v1',
        'launcher': str(runtime), 'launcherRealpath': str(runtime.resolve(strict=True)), 'launcherSha256': digest.hexdigest(),
        'limits': ['Launcher input only; not full SDK or packaged product acceptance']}).encode() + b'\n'
    os.write(fd, raw); os.fsync(fd)
finally:
    os.close(fd)
PY_INPUT
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
  "$RUNTIME" run examples/continuity/main.bl
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
