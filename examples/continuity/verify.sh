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
READY_SECONDS=${CONTINUITY_READY_TIMEOUT:-240}
RUNTIME_SECONDS=${CONTINUITY_RUNTIME_SECONDS:-900}
if [[ ! "$READY_SECONDS" =~ ^[1-9][0-9]{1,3}$ || ! "$RUNTIME_SECONDS" =~ ^[1-9][0-9]{1,3}$ ]] ||
   ((READY_SECONDS < 30 || READY_SECONDS > 1800 || RUNTIME_SECONDS > 2700 || RUNTIME_SECONDS < READY_SECONDS + 180)); then
  echo "Finite readiness30..1800 and runtime <=2700, with180 seconds for browser/cleanup, required." >&2; exit 1
fi
mkdir -p "$HOME/tmp"
SCRATCH=$(mktemp -d "$HOME/tmp/ct-XXXXXX")
UNIT="continuity-demo-$BASHPID-$RANDOM"
PORT=${CONTINUITY_PORT:-4048}
URL="http://127.0.0.1:$PORT"
EVIDENCE=${CONTINUITY_EVIDENCE:-}
OWN_EVIDENCE=0
UNIT_STARTED=0
INVOCATION=""
EVIDENCE_READY=0
cleanup() {
  local status=$? stopped=1 current="" state="" loaded="" pid=""
  trap - EXIT
  set +e
  if ((UNIT_STARTED)); then
    stopped=0
    current=$(systemctl --user show "$UNIT.service" -p InvocationID --value 2>/dev/null)
    if [[ -n "$INVOCATION" && "$current" == "$INVOCATION" ]]; then
      if timeout 30s systemctl --user stop "$UNIT.service" >/dev/null 2>&1; then
        state=$(systemctl --user show "$UNIT.service" -p ActiveState --value 2>/dev/null)
        current=$(systemctl --user show "$UNIT.service" -p InvocationID --value 2>/dev/null)
        loaded=$(systemctl --user show "$UNIT.service" -p LoadState --value 2>/dev/null)
        pid=$(systemctl --user show "$UNIT.service" -p MainPID --value 2>/dev/null)
        if [[ "$state" == inactive && "$pid" == 0 &&
              ( "$current" == "$INVOCATION" || ( -z "$current" && "$loaded" == not-found ) ) ]]; then
          stopped=1
        fi
      fi
    fi
    if ((EVIDENCE_READY)); then
      journalctl --user -u "$UNIT.service" --no-pager -o json > "$EVIDENCE/server-journal.jsonl"
      printf '%s\n' "$INVOCATION" > "$EVIDENCE/service-invocation.txt"
    fi
  fi
  if ((stopped)); then
    rm -rf -- "$SCRATCH"
  else
    printf 'Sandbox ownership or stop could not be confirmed; retained %s and %s.service\n' "$SCRATCH" "$UNIT" >&2
    ((status)) || status=1
  fi
  if ((EVIDENCE_READY)); then
    printf 'Evidence: %s\n' "$EVIDENCE"
  elif ((OWN_EVIDENCE)); then
    rm -rf -- "$EVIDENCE"
  fi
  exit "$status"
}
trap cleanup EXIT
if [[ -z "$EVIDENCE" ]]; then
  EVIDENCE=$(mktemp -d "$HOME/tmp/continuity-evidence-XXXXXX")
  OWN_EVIDENCE=1
fi
export TMPDIR="$SCRATCH"
# Record exact launcher selection before any native command. This is input
# provenance, not proof of a bootable SDK or a successful browser acceptance.
python3 - "$RUNTIME" "$EVIDENCE" "$SCRATCH" <<'PY_INPUT'
import hashlib, json, os, stat, sys
from pathlib import Path
runtime, evidence, scratch = map(Path, sys.argv[1:])
home_tmp = Path.home() / 'tmp'
assert evidence.is_absolute() and evidence == Path(os.path.normpath(evidence)) and home_tmp in evidence.parents, 'Evidence must use normalized HOME/tmp'
assert evidence != scratch and scratch not in evidence.parents, 'Evidence must outlive disposable sandbox data'
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
# Optional code-byte candidates only. Each demo gets its own copied writable
# cache; the native loader still validates keys/Source/provenance. No SDKlease,
# namespace readiness, initializer or runtime authority is imported by Python.
launcher_sha256 = digest.hexdigest()
cache = scratch / 'aot-cache'
cache.mkdir(mode=0o700)
cache_source = os.environ.get('CONTINUITY_AOT_CACHE_SOURCE')
cache_record = {'kind': 'empty-private-cache', 'files': 0, 'bytes': 0}
if cache_source:
    source = Path(cache_source)
    assert source.is_absolute() and source == Path(os.path.normpath(source)), 'Absolute normalized cache source required'
    assert home_tmp in source.parents and source != scratch and scratch not in source.parents, 'Cache must be outside this disposable HOME/tmp'
    for parent in (source, *source.parents):
        info = parent.lstat()
        assert not stat.S_ISLNK(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o022, 'Protected cache ancestry required'
        if parent == Path.home(): break
    def inventory():
        rows = []; total = 0
        for parent, directories, names in os.walk(source, followlinks=False):
            for name in directories:
                assert not (Path(parent) / name).is_symlink(), 'Cache symlink refused'
            for name in names:
                path = Path(parent) / name; info = path.lstat()
                assert stat.S_ISREG(info.st_mode) and 0 < info.st_size <= 67108864, 'Finite regular cache objects required'
                total += info.st_size
                assert len(rows) < 65536 and total <= 4294967296, 'Finite cache inventory required'
                digest = hashlib.sha256(); count = 0
                with path.open('rb') as data:
                    for block in iter(lambda: data.read(1048576), b''):
                        count += len(block); assert count <= info.st_size, 'Cache grew during capture'
                        digest.update(block)
                assert count == info.st_size, 'Cache shrank during capture'
                rows.append({'path': str(path.relative_to(source)), 'sha256': digest.hexdigest(), 'bytes': count})
        assert rows, 'Cache source must contain actual candidate files'
        return sorted(rows, key=lambda row: row['path'])
    rows = inventory()
    for row in rows:
        original = source / row['path']; target = cache / row['path']
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        digest = hashlib.sha256(); count = 0
        with original.open('rb') as inp, target.open('xb') as out:
            os.fchmod(out.fileno(), 0o600)
            for block in iter(lambda: inp.read(1048576), b''):
                count += len(block); assert count <= row['bytes'], 'Cache grew during copy'
                digest.update(block); out.write(block)
        assert count == row['bytes'] and digest.hexdigest() == row['sha256'], 'Cache byte copy drift'
        assert (original.stat().st_dev, original.stat().st_ino) != (target.stat().st_dev, target.stat().st_ino), 'Independent cache inode required'
    assert inventory() == rows, 'Original cache changed during copy'
    cache_record = {'kind': 'untrusted-exact-private-byte-copy', 'source': str(source), 'files': len(rows),
                    'bytes': sum(row['bytes'] for row in rows), 'inventorySha256': hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest(),
                    'authority': 'NONE; native canonical producer revalidation required'}
fd = os.open(evidence / 'launcher-input.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    raw = json.dumps({'scope': 'source-continuity-launcher-selection/v1',
        'launcher': str(runtime), 'launcherRealpath': str(runtime.resolve(strict=True)), 'launcherSha256': launcher_sha256, 'cacheCandidates': cache_record,
        'limits': ['Launcher input only; not full SDK or packaged product acceptance']}).encode() + b'\n'
    os.write(fd, raw); os.fsync(fd)
finally:
    os.close(fd)
PY_INPUT
EVIDENCE_READY=1
"$ROOT/scripts/bl-mem"
if curl --noproxy '*' --silent --max-time 2 "$URL/health/ready" >/dev/null; then
  echo "Port $PORT already serves an instance; choose CONTINUITY_PORT." >&2; exit 1
fi
# A lost launcher reply may still have created the service. Preserve its data
# unless this invocation is positively identified and stopped.
UNIT_STARTED=1
systemd-run --user --unit="$UNIT" --working-directory="$ROOT" \
  --setenv="CONTINUITY_ROOT=$SCRATCH/data" --setenv="CONTINUITY_PORT=$PORT" --setenv="TMPDIR=$SCRATCH" \
  --setenv=BL_DAEMON=off --setenv=BL_AUTOBUILD=off --setenv="BEAM_LISP_AOT_CACHE_DIR=$SCRATCH/aot-cache" \
  --property=MemoryMax=6G --property=MemorySwapMax=0 --property=RuntimeMaxSec="$RUNTIME_SECONDS" --property=TimeoutStopSec=15 \
  "$RUNTIME" run examples/continuity/main.bl
INVOCATION=$(systemctl --user show "$UNIT.service" -p InvocationID --value)
[[ "$INVOCATION" =~ ^[[:xdigit:]]{32}$ ]]
deadline=$((SECONDS + READY_SECONDS))
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
