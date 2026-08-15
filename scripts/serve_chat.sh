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
<script>
  // Seed the transcript the way the LiveView bridge would. `$messages` is a
  // SUBSCRIPTION in the emitted seam: it initialises to null and a sibling
  // `@data inline` would lose to it, so the seed travels through the transport.
  window.SpacetimeLocal = window.SpacetimeLocal || {{}};
  window.SpacetimeLocal["messages"] = [
    {{role:"user",  text:"what is this?"}},
    {{role:"model", text:"A chat page emitted from one beam-lisp term: contract and view from the same source."}}
  ];
  window.SpacetimeLocal["status"] = "idle";
  document.addEventListener("DOMContentLoaded", function () {{
    document.dispatchEvent(new CustomEvent("local:messages:updated",
      {{ detail: window.SpacetimeLocal["messages"] }}));
  }});
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
