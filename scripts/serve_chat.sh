#!/usr/bin/env bash
# scripts/serve_chat.sh — the emitted chat page, in your browser, live.
#
#   scripts/serve_chat.sh [PORT]        # default 8800
#
# `shot.sh` compiles, serves, screenshots and TEARS DOWN — evidence, then gone.
# This is the same pipeline with the teardown removed and the port fixed, so
# there is a URL you can keep open, type into, and reload.
#
#   1. emit    priv/chat.bl  →  .st          (render_emitted.exs)
#   2. build   .st           →  spacetime.js + spacetime.css   (verse)
#   3. host    the emitted &shell, LIFTED from the emitted text — never retyped
#   4. serve   a static origin (the bundle needs one; file:// will not do)
#
# The page is REAL: bubbles render through the emitted `@each`, the composer
# writes `$draft` through the emitted `@on &.input`, and the send button fires
# the emitted `$send` signal. What is NOT here is a server on the other end of
# that signal — `mix run scripts/live_chat.exs` is the script that answers it.
# So: clicking Send drives the seam and nothing replies. That is the honest
# state of the loop, and it is better seen than described.
set -euo pipefail

PORT="${1:-8800}"

# A stale server holding the port used to fail at the LAST step, after the
# whole emit+build — and whatever WAS serving then answered peek.sh with a
# tree this run did not produce. Refuse up front, naming the squatter.
if ss -tlnp 2>/dev/null | grep -qF ":$PORT "; then
  echo "serve_chat: port $PORT already held by:" >&2
  ss -tlnp 2>/dev/null | grep -F ":$PORT " >&2
  echo "  kill it or pass another PORT" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSE="${VERSE:-$HOME/code/ora/verse}"
WORK="/tmp/chat-serve"
STATUS="${STATUS:-}"

rm -rf "$WORK"; mkdir -p "$WORK"

echo "1/4  emit — priv/chat.bl → .st"
( cd "$ROOT" && mix run scripts/render_emitted.exs "$WORK/page.st" $STATUS ) 2>/dev/null | sed 's/^/     /'

echo "2/4  build — .st → bundle (verse)"
( cd "$VERSE" && cargo run --quiet --bin spacetime -- build "$WORK/page.st" -o "$WORK" ) >/dev/null 2>&1 \
  || { echo "     spacetime build FAILED"; exit 1; }
ls "$WORK"/spacetime.js >/dev/null || { echo "     no bundle produced"; exit 1; }

echo "3/4  host — lifting &shell out of the emitted page"
# The host markup is EXTRACTED from what the emitter produced. Copying it by
# hand is the original sin of this project: a screenshot of a page the emitter
# did not write. If the template is missing, stop rather than invent one.
python3 - "$WORK/page.st" "$WORK/index.html" "$WORK/../chat-serve/page.st" <<'PY'
import re, sys, pathlib
page = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r"@template &shell\(\) \{(.*?)\}\s*$", page, re.S | re.M)
if not m:
    sys.exit("FATAL: no `@template &shell()` in the emitted page — refusing to hand-write one")
shell = m.group(1).strip()
pathlib.Path(sys.argv[2]).write_text(f"""<!doctype html>
<html><head><meta charset="utf-8"><title>chat — emitted</title>
<link rel="stylesheet" href="spacetime.css">
<style>
  html,body{{margin:0;background:#0b0d14;color:#e8eaf2;
    font:16px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif}}
</style>
</head><body>
{shell}
<pre id="spacetime-snapshot" hidden></pre>
<script>
  // Seed the transcript the way the LiveView bridge would. `$messages` is a
  // SUBSCRIPTION in the emitted seam: it initialises to null and a sibling
  // `@data inline` would lose to it, so the seed travels through the transport.
  //
  // A one-shot DOMContentLoaded dispatch RACES the bundle: if its init lands
  // after the dispatch it writes null over the seed and the log stays empty
  // (observed via peek.sh: state.json had messages:null). Push with retry
  // until the bridge exists — the same discipline live_chat.exs uses — and
  // keep RE-asserting the seed until it survives a snapshot tick.
  window.SpacetimeLocal = window.SpacetimeLocal || {{}};
  var SEED = [
    {{role:"user",  text:"what is this?"}},
    {{role:"model", text:"A chat page emitted from one beam-lisp term: contract and view from the same source."}}
  ];
  var seedPushes = 0;
  var seedTimer = setInterval(function () {{
    seedPushes += 1;
    var cur = window.SpacetimeLocal["messages"];
    if (cur && cur.length === SEED.length) {{ clearInterval(seedTimer); return; }}
    window.SpacetimeLocal["messages"] = SEED;
    window.SpacetimeLocal["status"] = window.SpacetimeLocal["status"] || "idle";
    document.dispatchEvent(new CustomEvent("local:messages:updated", {{ detail: SEED }}));
    if (seedPushes > 200) clearInterval(seedTimer); // 5s of trying, then fail loud in state.json
  }}, 25);
  // peek.sh reads the interface's data state out of this element. Published
  // on an interval rather than on demand because headless chrome cannot be
  // asked a question — it can only serialize the DOM, so the state must BE
  // in the DOM. Scope limit, stated honestly: this is the seam state that
  // crossed the bridge (SpacetimeLocal). Page-local signals live inside the
  // bundle and are not reachable without instrumenting verse.
  setInterval(function () {{
    var el = document.getElementById("spacetime-snapshot");
    if (el && window.SpacetimeLocal)
      el.textContent = JSON.stringify(window.SpacetimeLocal);
  }}, 250);

  // Auto-reload: the page rebuilds itself when the machine grows.
  //
  // The live driver writes report.json on every accepted definition, with a
  // version counter. Polling THAT rather than the bundle's Last-Modified is
  // deliberate: a rebuild rewrites spacetime.js even when nothing changed
  // (timestamps move), so the bundle would reload the page on every emit,
  // while the version only moves when the machine did.
  //
  // Cache-busted because a 304 would freeze the version at whatever the browser
  // saw first, and the page would sit there while the machine grew.
  (function () {{
    var seen = null;
    setInterval(function () {{
      fetch("report.json?t=" + Date.now(), {{ cache: "no-store" }})
        .then(function (r) {{ return r.ok ? r.json() : null; }})
        .then(function (report) {{
          if (!report) return;
          if (seen === null) {{ seen = report.version; return; }}
          if (report.version !== seen) location.reload();
        }})
        .catch(function () {{ /* the driver may not be running; that is fine */ }});
    }}, 1000);
  }})();
</script>
<script src="spacetime.js"></script>
</body></html>
""")
print(f"     lifted {len(shell)} B of emitted &shell")
PY

echo "4/4  serve"
cd "$WORK"
echo
echo "   ┌──────────────────────────────────────────────┐"
echo "   │  http://127.0.0.1:$PORT                       "
echo "   └──────────────────────────────────────────────┘"
echo
echo "   Ctrl-C to stop."
exec python3 -m http.server "$PORT" --bind 127.0.0.1
