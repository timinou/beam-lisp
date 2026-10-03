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
run=${RUN:-}

cd "$root"
JS_ENTRY=diff.corpus JS_OUT="$out" JS_ROOTS="test/js/diff" $run bl run priv/lib/js/cli.bl >"$out/build.log" 2>&1 \
  || { grep -v '^  at' "$out/build.log" | tail -5; exit 2; }
(cd "$here" && $run bl run beam-side.bl) 2>&1 | grep -P '^[a-z-]+\t' >"$out/beam.out"
node "$here/js-side.mjs" "$out" >"$out/js.out"
node --input-type=module -e "
import { canon } from '$here/canon.mjs';
import fs from 'node:fs';
const read = f => Object.fromEntries(fs.readFileSync(f, 'utf8').trim().split('\n').map(l => { const i = l.indexOf('\t'); return [l.slice(0, i), l.slice(i + 1)]; }));
const b = read('$out/beam.out'), j = read('$out/js.out');
let bad = 0;
for (const k of Object.keys(b)) {
  const bc = canon(b[k]), jc = canon(j[k] ?? '#missing');
  if (bc === jc) { console.log('SAME  ' + k); continue; }
  bad++;
  const bs = bc.split(' '), js = jc.split(' ');
  let i = 0; while (i < bs.length && bs[i] === js[i]) i++;
  console.log('DIFF  ' + k + ' at token ' + i + ':\n  beam: …' + bs.slice(Math.max(0, i - 3), i + 6).join(' ') + '\n  js:   …' + js.slice(Math.max(0, i - 3), i + 6).join(' '));
}
console.log(bad === 0 ? 'diff: all ' + Object.keys(b).length + ' cases identical' : 'diff: ' + bad + ' case(s) differ');
process.exit(bad === 0 ? 0 : 1);
"
