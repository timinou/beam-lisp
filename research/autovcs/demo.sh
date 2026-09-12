#!/usr/bin/env bash
# autovcs/demo.sh — one agent session, every change recorded, then undone.
#
# Runs the probe end to end against a throwaway workspace and ASSERTS the
# behaviour it claims: the files landed, jj holds one change per request, the
# mirror answers who/why/when, and an operation-level undo puts the tree back.
#
#   research/autovcs/demo.sh [workspace]     (default /tmp/autovcs-demo)
#
# Every jj command here is jj's own CLI — the probe never speaks a private
# protocol to it. The replies and the history are printed, not summarised, so
# this script is also the evidence.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
ws="${1:-/tmp/autovcs-demo}"

# Precaution, not a cure: payload dirs under ~/.local/share/drop have been seen
# failing to boot ("cannot get bootfile .../bin/start.boot") while sibling `bl`
# processes ran from other payloads. A wide GC window costs nothing here.
export BL_DROP_KEEP_DAYS=${BL_DROP_KEEP_DAYS:-100000}
# A warm daemon belongs to one session and one build; this probe is not its work.
export BL_DAEMON=off

JJ=$("$here/fetch.sh")           # pinned, sha256-verified
export AUTOVCS_JJ="$JJ"
bl() { (cd "$repo" && ./bl -p priv/std "$@"); }

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ── a fresh managed tree ──────────────────────────────────────────────────────
rm -rf "$ws"; mkdir -p "$ws"
(cd "$ws" && "$JJ" git init --colocate >/dev/null 2>&1 || true)
(cd "$ws" && "$JJ" config set --repo user.name "autovcs probe" >/dev/null \
           && "$JJ" config set --repo user.email "probe@beam-lisp.invalid" >/dev/null)
printf '_build/\n%s/\n' ".autovcs" > "$ws/.gitignore"
mkdir -p "$ws/_build"; echo "object" > "$ws/_build/artifact.o"
printf '# fixture\n\nA tree with .bl and non-.bl files, owned by a daemon.\n' > "$ws/README.md"

# ── one agent session, delivered as requests ──────────────────────────────────
# Every mutation names its actor and its intent. That is the whole difference
# between a backup and a history.
mkdir -p "$ws/.autovcs"
cat > "$ws/.autovcs/requests.jsonl" <<'JSONL'
{"op":"write","id":"r1","path":"app.bl","content":"(ns app)\n\n(defn answer [] 1)\n","by":"agent:probe","why":"first cut of the answer fn"}
{"op":"write","id":"r2","path":"data/points.json","content":"{\"points\": [[0,0],[3,7]]}\n","by":"agent:probe","why":"seed the fixture data"}
{"op":"write","id":"r3","path":"notes.md","content":"# notes\n\nwhy 3 and 7? see BUG-9.\n","by":"human:you","why":"record the open question"}
{"op":"write","id":"r4","path":"app.bl","content":"(ns app)\n\n(defn answer [] 2)\n","by":"agent:probe","why":"make it 2, per BUG-9"}
{"op":"delete","id":"r5","path":"notes.md","by":"agent:probe","why":"the question is answered; drop the note"}
{"op":"status"}
{"op":"history"}
{"op":"touched","path":"app.bl"}
JSONL

say "the floor: what a bare process costs before any work happens"
b0=$(date +%s%N); bl eval '1' >/dev/null 2>&1 || true; b1=$(date +%s%N)
boot_ms=$(( (b1 - b0) / 1000000 ))
: > "$ws/.autovcs/empty.jsonl"
b2=$(date +%s%N)
bl run research/autovcs/autovcs.bl -- script "$ws" "$ws/.autovcs/empty.jsonl" >/dev/null 2>&1 || true
b3=$(date +%s%N)
load_ms=$(( (b3 - b2) / 1000000 ))
printf '  a bare VM, nothing loaded: %s ms\n  the same VM with the probe and datom loaded, no requests: %s ms\n' "$boot_ms" "$load_ms"

say "session: five mutations, then the mirror is asked what happened"
t0=$(date +%s%N)
bl run research/autovcs/autovcs.bl -- script "$ws" "$ws/.autovcs/requests.jsonl" \
  | tee "$ws/.autovcs/replies.jsonl" | cut -c1-150
t1=$(date +%s%N)
session_ms=$(( (t1 - t0) / 1000000 ))

python3 - "$ws/.autovcs/replies.jsonl" <<'PY' || exit 1
import json, sys
replies = [json.loads(l) for l in open(sys.argv[1]) if l.strip().startswith("{")]
mutations = [r for r in replies if "request" in r]
bad = [r for r in replies if r.get("ok") is False]
for r in mutations:
    assert r["ok"], r
if bad:
    print("  failed replies:", bad); sys.exit(1)
for r in mutations:
    print(f'  {r["request"]:>3}  {r["ms"]:>5} ms total  {r["mirror_ms"]:>4} ms mirror  op {r["op"][:12]}…  commit {r["commit"][:12]}…  {r["paths"]}')
hist = [r for r in replies if "history" in r][0]["history"]
print(f'  history rows: {len(hist)}')
for row in hist:
    print(f'    {row["request"]:>3} {row["by"]:<14} {row["why"]:<34} {row["path"]:<18} op {row["op"][:10]}…')
touched = [r for r in replies if "requests" in r and "path" in r][0]["requests"]
print(f'  touched app.bl: {[t["request"] for t in touched]}')
PY

# ── the tree, read by jj itself (not by us) ───────────────────────────────────
say "the tree's own history (jj log, jj's words)"
(cd "$ws" && "$JJ" log --no-graph -r '::@' -T 'self.change_id().shortest(8) ++ "  " ++ self.author().name() ++ "  " ++ self.description() ++ "\n"')

say "the colocated git repo sees the same history (interop)"
(cd "$ws" && git log --oneline | head -6 || true)

say "the files on disk after the session"
(cd "$ws" && ls -aR . | head -24 || true)
grep -q "answer \[\] 2" "$ws/app.bl" || fail "app.bl was not updated"
[ -f "$ws/notes.md" ] && fail "notes.md should have been deleted by r5" || true
status_out=$(cd "$ws" && "$JJ" status)
case "$status_out" in
  *"no changes"*) echo "  the working copy is clean: everything the daemon did is a change" ;;
  *) fail "the working copy should be clean, got: $status_out" ;;
esac

# ── undo as an operation, not a patch ─────────────────────────────────────────
op_before_edit=$(python3 - "$ws/.autovcs/replies.jsonl" <<'PY'
import json, sys
replies = [json.loads(l) for l in open(sys.argv[1]) if l.strip().startswith("{")]
print([r for r in replies if r.get("request") == "r3"][0]["op"])
PY
)
say "undo: restore to the operation recorded after r3 (${op_before_edit:0:12}…) — two later changes vanish"
cat > "$ws/.autovcs/undo.jsonl" <<JSONL
{"op":"undo","id":"$op_before_edit"}
{"op":"status"}
{"op":"history"}
JSONL
bl run research/autovcs/autovcs.bl -- script "$ws" "$ws/.autovcs/undo.jsonl" \
  | tee "$ws/.autovcs/undo-replies.jsonl" | cut -c1-150

grep -q "answer \[\] 1" "$ws/app.bl" || fail "undo did not restore app.bl"
[ -f "$ws/notes.md" ] || fail "undo did not restore the deleted notes.md"
echo "  both files are back: app.bl says 1 again, notes.md exists"

say "measured"
python3 - "$ws/.autovcs/replies.jsonl" "$session_ms" "$boot_ms" "$load_ms" <<'PY'
import json, sys
replies = [json.loads(l) for l in open(sys.argv[1]) if l.strip().startswith("{")]
mut = [r for r in replies if "request" in r]
ms = [r["ms"] for r in mut]
mir = [r["mirror_ms"] for r in mut]
print(f'  bare cold VM                             : {sys.argv[3]} ms')
print(f'  cold VM + probe + datom, zero requests   : {sys.argv[4]} ms   <- why this belongs in the daemon')
print(f'  checkpoint total, per request            : {ms}  spread {min(ms)}–{max(ms)}')
print(f'    of which the jj->datom mirror          : {mir}  spread {min(mir)}–{max(mir)}')
print(f'  the whole script pass (5 mutations + 3 queries + process): {sys.argv[2]} ms')
PY

say "OK — the daemon's work is a history, not a state"
