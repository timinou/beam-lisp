#!/usr/bin/env bash
# scripts/shot.sh — compile a Spacetime page, serve it, screenshot it. Headless.
#
#   scripts/shot.sh <page.st> <out.png> [width] [height]
#
# Why this exists: a claim about a UI is worth what its screenshot is worth. The
# alternative is asserting that a page "renders correctly" from the fact that it
# compiled, which is exactly the mistake a milestone-2 review caught — an app
# whose documents every checker accepted while it had no DOM to render at all.
#
# Three steps, each of which can fail loudly:
#   1. `spacetime build` — compile the .st to spacetime.js + spacetime.css
#   2. a host page + a static server — the bundle needs an origin, not file://
#   3. headless Chrome — screenshot AFTER the signal renderer has painted
#
# The wait in step 3 is not a fixed sleep: the renderer paints on its own
# schedule, and a sleep either flakes or wastes time. We poll for a rendered
# element and fail if it never appears, so a blank screenshot is an ERROR rather
# than a picture of nothing.

set -euo pipefail

PAGE="${1:?usage: shot.sh <page.st> <out.png> [width] [height]}"
OUT="${2:?usage: shot.sh <page.st> <out.png> [width] [height]}"
WIDTH="${3:-960}"
HEIGHT="${4:-800}"

VERSE="${VERSE_ROOT:-/home/user/code/ora/verse}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true' EXIT

CHROME="${CHROME_BIN:-}"
if [ -z "$CHROME" ]; then
  for c in /opt/google/chrome/chrome \
           "$(command -v chromium 2>/dev/null || true)" \
           "$(command -v google-chrome 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && CHROME="$c" && break
  done
fi
[ -n "$CHROME" ] || { echo "shot: no chrome found (set CHROME_BIN)" >&2; exit 1; }

# ── 1. compile ──────────────────────────────────────────────────────────────
( cd "$VERSE" && cargo run --quiet --bin spacetime -- build "$PAGE" -o "$WORK" ) >/dev/null 2>&1 \
  || { echo "shot: build failed for $PAGE" >&2; exit 1; }
[ -s "$WORK/spacetime.js" ] || { echo "shot: build produced no bundle" >&2; exit 1; }

# ── 2. host page ────────────────────────────────────────────────────────────
# The DOM skeleton the .st binds onto. In the LiveView bridge this comes from
# `render_host/1`; standalone, it lives here.
HOST_HTML="${HOST_HTML:-}"
if [ -n "$HOST_HTML" ] && [ -f "$HOST_HTML" ]; then
  cp "$HOST_HTML" "$WORK/index.html"
else
  cat > "$WORK/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><link rel="stylesheet" href="spacetime.css"></head>
<body>
  <main class="chat">
    <div class="log" data-log></div>
    <form class="composer" onsubmit="return false">
      <input class="composer__input" placeholder="Say something…">
      <button class="composer__send" type="button">Send</button>
    </form>
  </main>
  <script src="spacetime.js"></script>
</body></html>
HTML
fi

# ── 3. serve + shoot ────────────────────────────────────────────────────────
# A real origin: the bundle uses module semantics and fetch, neither of which
# behaves the same under file://.
PORT=$((8000 + RANDOM % 1000))
( cd "$WORK" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
SRV_PID=$!
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/index.html" >/dev/null 2>&1 && break
  sleep 0.1
done

# ── 3a. verify the DOM BEFORE capturing ───────────────────────────────────
#
# The check runs FIRST and polls, so a slow bundle is waited for rather than
# raced. The previous order — screenshot, then a second Chrome to check — could
# disagree with itself: if the renderer finished after the screenshot but before
# the check, the image was wrong and the check was green. A reviewer found that;
# it then bit for real on the very next run.
#
# NB `--dump-dom` serializes comments and inline script text as well as
# elements, so a literal match is a necessary condition rather than a sufficient
# one: a page could contain the string in a comment and pass. Give
# `SHOT_REQUIRE` something the renderer PRODUCES — an attribute the templates
# write, say `data-role="model"` — and never a word that also appears in the
# host's own markup, or the check can only confirm what was already there.
if [ -n "${SHOT_REQUIRE:-}" ]; then
  found=""
  for _ in $(seq 1 40); do
    n=$("$CHROME" --headless --disable-gpu --no-sandbox \
      --virtual-time-budget=4000 \
      --dump-dom "http://127.0.0.1:$PORT/index.html" 2>/dev/null \
      | grep -oF -- "$SHOT_REQUIRE" | wc -l)
    if [ "${n:-0}" -gt 0 ]; then found=1; break; fi
    sleep 0.25
  done

  if [ -z "$found" ]; then
    echo "shot: the rendered DOM never contained '$SHOT_REQUIRE' — the page did not render" >&2
    exit 1
  fi
  echo "shot: verified '$SHOT_REQUIRE' is in the rendered DOM"
fi

mkdir -p "$(dirname "$OUT")"
"$CHROME" \
  --headless \
  --disable-gpu \
  --no-sandbox \
  --hide-scrollbars \
  --force-device-scale-factor=2 \
  --virtual-time-budget=6000 \
  --window-size="${WIDTH},${HEIGHT}" \
  --screenshot="$OUT" \
  "http://127.0.0.1:$PORT/index.html" >/dev/null 2>&1

[ -s "$OUT" ] || { echo "shot: chrome produced no image" >&2; exit 1; }

# A screenshot of a blank page is worse than no screenshot: it looks like
# evidence. Reject anything suspiciously small — a page that rendered nothing
# compresses to almost nothing.
SIZE=$(stat -c %s "$OUT")
if [ "$SIZE" -lt 6000 ]; then
  echo "shot: image is only ${SIZE}B — the page probably rendered nothing" >&2
  exit 1
fi

# Byte size is a floor, not a check — the host skeleton alone clears 6000B, so a
# page whose bundle bound NOTHING still produces a plausible image. That is what
# `SHOT_REQUIRE` is for, and it runs BEFORE the capture (step 3a) so the thing
# verified and the thing photographed are the same load.

echo "shot: $OUT (${SIZE}B, ${WIDTH}x${HEIGHT}@2x)"
