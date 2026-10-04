#!/usr/bin/env bash
# apps/bl-ed/build.sh — compile the editor (Beam Lisp) to ES modules for the page.
#   apps/bl-ed/build.sh   → apps/bl-ed/web/out/
# ONE output directory, so the editor and Beam Lisp itself (reader + compiler
# + emitter + eval, for the `:` command line) share one runtime: one rt.mjs,
# one core.mjs — a keyword or a vector is the same value to both.
# One `bl` VM per build; set RUN to wrap it (e.g. a systemd scope).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=apps/bl-ed/web/out
${RUN:-} bl js build js.eval -p priv/lib -p priv/boot --stub lower --with reader --host run --out "$out"
${RUN:-} bl js build ed.main -p apps/bl-ed --host eval-ed,eval-cells --out "$out"
# the language's own macros, read by the page at start (boot.mjs)
mkdir -p "$out/src/priv/boot"
cp priv/boot/core.bl priv/boot/sugar.bl "$out/src/priv/boot/"
