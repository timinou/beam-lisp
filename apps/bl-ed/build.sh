#!/usr/bin/env bash
# apps/bl-ed/build.sh — compile the editor (Beam Lisp) to ES modules for the page.
#   apps/bl-ed/build.sh            → apps/bl-ed/web/out/
# One `bl` VM; set RUN to wrap it (e.g. a systemd scope).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=apps/bl-ed/web/out
${RUN:-} bl js build ed.main -p apps/bl-ed --out "$out"
