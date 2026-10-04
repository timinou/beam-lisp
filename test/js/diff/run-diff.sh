#!/usr/bin/env bash
# test/js/diff/run-diff.sh — the BEAM ↔ JS sync-profile differential.
#
# Builds test/js/diff/diff/corpus.bl to JS, prints every case on BEAM and in
# Node, canonicalizes map/set entry order (BEAM's small-map order follows the
# atom table; FUP-141) and compares. Exit 0 iff every case prints the same.
#
# Each `bl` invocation is one BEAM VM; pass RUN="<wrapper>" to cap it (e.g. a
# systemd-run scope). OUT defaults to a temp dir.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/bl-jsdiff.XXXXXX")}
mkdir -p "$out"
run=${RUN:-}

cd "$root"
$run bl js build diff.corpus -p test/js/diff --out "$out" >"$out/build.log" 2>&1 \
  || { grep -v '^  at' "$out/build.log" | tail -5; exit 2; }
(cd "$here" && $run bl run beam-side.bl) 2>&1 | grep -P '^[a-z-]+\t' >"$out/beam.out"
node "$here/js-side.mjs" "$out" >"$out/js.out"
node "$here/compare.mjs" "$out/beam.out" "$out/js.out"
