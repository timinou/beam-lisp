#!/usr/bin/env bash
# scripts/peek.sh — look at the LIVE page: screenshot + interface data state.
#
#   scripts/serve_chat.sh        # terminal 1: the live origin
#   scripts/peek.sh              # terminal 2: what does it look like NOW?
#   scripts/peek.sh 8800 /tmp/peek2
#
# Unlike shot.sh this builds NOTHING and serves nothing: it photographs and
# reads the origin that is already running, so what you see is what the user
# sees, not a fresh compile. Three outputs in the out dir (default
# /tmp/chat-peek):
#
#   screen.png   the live page, rendered now
#   state.json   the interface's data state — everything that crossed the
#                bridge (window.SpacetimeLocal), read out of the hidden
#                <pre id="spacetime-snapshot"> the host page maintains.
#                Page-local signals live inside the bundle and are NOT here;
#                that is a scope limit of reading from outside, not a bug.
#   report.json  the machine/repl state, IF the driver published one
#                (spell_live.exs, PLAN-025 phase 4 — absent until then)
#
# Chrome discovery and the blank-image floor are copied from shot.sh — same
# discipline, live target.
set -euo pipefail

PORT="${1:-8800}"
OUT="${2:-/tmp/chat-peek}"
SERVE_DIR="${SERVE_DIR:-/tmp/chat-serve}"
URL="http://127.0.0.1:$PORT/index.html"

mkdir -p "$OUT"

CHROME="${CHROME_BIN:-}"
if [ -z "$CHROME" ]; then
  for c in /opt/google/chrome/chrome \
           "$(command -v chromium 2>/dev/null || true)" \
           "$(command -v google-chrome 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && CHROME="$c" && break
  done
fi
[ -n "$CHROME" ] || { echo "peek: no chrome found (set CHROME_BIN)" >&2; exit 1; }

curl -sf "$URL" >/dev/null 2>&1 \
  || { echo "peek: nothing serving at $URL — is serve_chat.sh running?" >&2; exit 1; }

# ── 1. screenshot ───────────────────────────────────────────────────────────
"$CHROME" --headless --disable-gpu --no-sandbox --hide-scrollbars \
  --force-device-scale-factor=2 --virtual-time-budget=6000 \
  --window-size=960,800 --screenshot="$OUT/screen.png" "$URL" >/dev/null 2>&1

SIZE=$(stat -c %s "$OUT/screen.png" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 6000 ]; then
  echo "peek: screenshot is only ${SIZE}B — the page probably rendered nothing" >&2
  exit 1
fi
echo "peek: screen.png  ${SIZE}B"

# ── 2. interface data state ─────────────────────────────────────────────────
# virtual-time-budget lets the host's 250ms snapshot interval actually fire.
"$CHROME" --headless --disable-gpu --no-sandbox \
  --virtual-time-budget=4000 --dump-dom "$URL" 2>/dev/null \
  | python3 -c '
import html, json, re, sys
dom = sys.stdin.read()
m = re.search(r"<pre id=\"spacetime-snapshot\"[^>]*>(.*?)</pre>", dom, re.S)
if not m or not m.group(1).strip():
    sys.exit("peek: no spacetime-snapshot in the DOM — host page predates the hook?")
state = json.loads(html.unescape(m.group(1)))
json.dump(state, sys.stdout, indent=2, sort_keys=True)
print()
' > "$OUT/state.json" || { echo "peek: could not read interface state" >&2; exit 1; }
echo "peek: state.json  $(stat -c %s "$OUT/state.json")B"
cat "$OUT/state.json"

# ── 3. repl/machine state, if the driver published it ───────────────────────
if [ -f "$SERVE_DIR/report.json" ]; then
  cp "$SERVE_DIR/report.json" "$OUT/report.json"
  echo "peek: report.json (machine state, from the driver)"
  python3 -m json.tool "$OUT/report.json"
else
  echo "peek: no $SERVE_DIR/report.json — machine state appears once the live driver (PLAN-025) publishes it"
fi
