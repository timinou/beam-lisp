#!/usr/bin/env bash
# apps/bl-ed/build.sh — compile the editor (Beam Lisp) to ES modules for the page.
#   apps/bl-ed/build.sh   → apps/bl-ed/web/out/
# ONE output directory, so the editor and Beam Lisp itself (reader + compiler
# + emitter + eval, for the `:` command line) share one runtime: one rt.mjs,
# one compiled core (out/ns/core.mjs) — a keyword or a vector is the same value
# to both. There is ONE target: core/rt/sugar and the clojure prelude are
# compiled from priv/boot (the facade adds those roots), never a hand-written
# core. `bl js build` defaults to it; no alternate core mode.
# One `bl` VM per build; set RUN to wrap it (e.g. a systemd scope).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=apps/bl-ed/web/out
${RUN:-} ./bin/bl js build js.eval -p priv/lib -p apps/bl-ed \
  --stub lower --with reader,ed.main,ed.selftest \
  --host run,eval-ed,eval-cells --out "$out"
# the language's own macros, read by the page at start (boot.mjs)
mkdir -p "$out/src/priv/boot"
cp priv/boot/core.bl priv/boot/sugar.bl "$out/src/priv/boot/"
