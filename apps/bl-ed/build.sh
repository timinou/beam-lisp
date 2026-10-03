#!/usr/bin/env bash
# apps/bl-ed/build.sh — compile the editor (Beam Lisp) to ES modules for the page.
#   apps/bl-ed/build.sh            → apps/bl-ed/web/out/
# One `bl` VM; set RUN to wrap it (e.g. a systemd scope).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=apps/bl-ed/web/out
JS_ENTRY=ed.main JS_OUT="$out" JS_ROOTS=apps/bl-ed ${RUN:-} bl run scripts/js-build.bl
