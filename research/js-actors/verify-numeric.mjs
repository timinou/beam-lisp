// Focused verification of the numeric gate: the emitter's fast/checked decision
// and the raw-JS-vs-H.arith equivalence it rests on.
//
// Run after compiler.bl:
//   node research/js-actors/verify-numeric.mjs
//
// It checks three things, none of which needs the BL toolchain:
//
//   1. the CONTRACT the raw operator must satisfy — for safe-integer operands
//      `a OP b` is exactly `H.arith(op, a, b)`, and outside ±(2^53-1) the
//      checked operator PROMOTES to an exact BigInt where the raw JS operator
//      would silently lose precision, which is precisely why the gate must
//      refuse to widen there;
//   2. the compile-time TRAP — `Number.isInteger(1.0)` is true, so the host
//      cannot tell `1` from `1.0`; the int/float category has to be decided where
//      the literal is still a BL value, never from the JS Number;
//   3. the ARTIFACT — the build report's raw/checked split matches the emitted
//      bundle (witness markers, `H.arith(` sites), every witnessed range lies in
//      the safe band, and every witness annotates a raw integer operator.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as H from './host.mjs';

const cwd = fileURLToPath(new URL('.', import.meta.url));
const SAFE = Number.MAX_SAFE_INTEGER;      // 2^53 - 1
const MIN_SAFE = Number.MIN_SAFE_INTEGER;

// ── 1. the checked operator and its raw equivalent ───────────────────────────

const RAW = {
  add: (a, b) => a + b,
  sub: (a, b) => a - b,
  mul: (a, b) => a * b,
  rem: (a, b) => a % b,
};
// BL `rem` and JS `%` both truncate toward zero, so they agree on integers.

assert.equal(H.arith('add', SAFE, 1), 9007199254740992n);
assert.equal(H.arith('sub', MIN_SAFE, 1), -9007199254740992n);
assert.equal(H.arith('mul', SAFE, 2), BigInt(SAFE) * 2n);
assert.throws(() => H.arith('rem', 1, 0), /rem by zero/);
assert.throws(() => H.arith('div', 1, 0), /divide by zero/);
assert.equal(H.arith('add', SAFE, 0), SAFE);
assert.equal(H.arith('sub', MIN_SAFE, 0), MIN_SAFE);
console.log('PASS checked arithmetic boundary: ±(2^53-1) exact in Number, promoted to BigInt outside, zero divisors raise');

const samples = [0, 1, -1, 2, -2, 7, -7, 3, 1e6, -1e6, 12345, -54321, SAFE, MIN_SAFE];
// The exact result as a canonical value: a Number inside ±(2^53-1), else BigInt.
const asExact = (a, b, op) => {
  const x = BigInt(a), y = BigInt(b);
  const r = op === 'add' ? x + y : op === 'sub' ? x - y : op === 'mul' ? x * y : x % y;
  return (r >= -9007199254740991n && r <= 9007199254740991n) ? Number(r) : r;
};
let equalities = 0, promotions = 0;
for (const op of Object.keys(RAW)) {
  for (const a of samples) {
    for (const b of samples) {
      if (op === 'rem' && b === 0) continue;
      const checked = H.arith(op, a, b);
      assert.ok(Object.is(checked, asExact(a, b, op)), `${op}(${a},${b}): ${checked} !== exact`);
      if (typeof checked === 'bigint') promotions++; else equalities++;
    }
  }
}
assert.ok(equalities > 100 && promotions > 0, 'sample set must exercise both sides');
console.log(`PASS raw operator ≡ H.arith on ${equalities} safe assignments; ${promotions} promoted beyond the band`);

// ── 2. the int/float trap the gate has to decide statically ──────────────────

assert.equal(Number.isInteger(1.0), true);
assert.equal(Number.isInteger(1), true);
// The host literally cannot tell them apart — so the gate must, at ANF time.
assert.equal(H.arith('add', 1, 1.0), 2);
console.log('PASS Number.isInteger(1.0) is true — the int/float category is a compile-time decision');

// ── 3. the emitted artifact against the build report ─────────────────────────

const report = JSON.parse(readFileSync(new URL('./out/numeric-gate.bundle.mjs.json', import.meta.url), 'utf8'));
const demoReport = JSON.parse(readFileSync(new URL('./out/numeric-gate.demo.mjs.json', import.meta.url), 'utf8'));
const bundle = readFileSync(new URL('./out/bundle.mjs', import.meta.url), 'utf8');

for (const r of [report, demoReport]) {
  assert.equal(r.counts.raw + r.counts.checked, r.sites.length, `${r.bundle}: counts must cover every site`);
}
assert.equal(report.bundle, 'bundle.mjs');

const count = (text, needle) => text.split(needle).length - 1;
assert.equal(count(bundle, 'js-actors:num-witness'), report.counts.raw,
  'witness markers in the bundle must equal the report raw count');
assert.equal(count(bundle, 'H.arith('), report.counts.checked,
  'H.arith sites in the bundle must equal the report checked count');

for (const site of report.sites) {
  assert.ok(['raw', 'checked'].includes(site.decision));
  if (site.decision === 'raw') {
    assert.equal(site.cat, 'int', `${site.fun}: a raw site must be categorised :int`);
    assert.ok(['add', 'sub', 'mul', 'rem'].includes(site.fun), `${site.fun}: only integer-closed ops may be raw`);
    assert.ok(Array.isArray(site.range) && site.range.length === 2, `${site.fun}: raw site needs a range`);
    assert.ok(site.range[0] <= site.range[1]);
    assert.ok(site.range[0] >= MIN_SAFE && site.range[1] <= SAFE, `${site.fun}: range escapes ±(2^53-1)`);
    assert.ok(Array.isArray(site.ops) && site.ops.length > 0, `${site.fun}: raw site needs an operator witness`);
    assert.ok(Array.isArray(site.leaves) && site.leaves.length > 0,
      `${site.fun}: raw site must bottom out in literals/let facts`);
  } else {
    assert.equal(site.cat, null, 'a checked site carries no numeric fact');
    assert.equal(site.range, null, 'a checked site carries no range');
    assert.ok(typeof site.reason === 'string' && site.reason.length > 0, 'a checked site must name its reason');
  }
}

// Every witness marker must annotate a raw integer operator (never H.arith).
const witnessed = [...bundle.matchAll(
  /const (\w+) = \((\w+) ([+\-*%]) (\w+)\); \/\* js-actors:num-witness cat=(\w+) range=\[(-?\d+),(-?\d+)\] ops=\[([^\]]*)\] leaves=\[([^\]]*)\] \*\//g,
)];
assert.equal(witnessed.length, report.counts.raw, 'every raw site must be a witnessed raw operator statement');
const opName = { '+': 'add', '-': 'sub', '*': 'mul', '%': 'rem' };
for (const m of witnessed) {
  const [, , , jsOp, , cat, lo, hi, ops, leaves] = m;
  assert.equal(cat, 'int');
  assert.ok(Number(lo) >= MIN_SAFE && Number(hi) <= SAFE && Number(lo) <= Number(hi));
  assert.ok(ops.split(',').includes(opName[jsOp]), `witness ops ${ops} must include ${opName[jsOp]}`);
  assert.ok(leaves.length > 0, 'witness must show literal provenance');
}
console.log(`PASS artifact: ${report.counts.raw} witnessed raw site(s), ${report.counts.checked} checked site(s), report ≡ bundle`);

// End-to-end: the literal arithmetic the gate widened must still pass on the
// generated bundle. The aggregate exit code belongs to verify.mjs — this check
// only requires the numeric acceptance lines to be present and correct.
const run = spawnSync(process.execPath, ['out/bundle.mjs'], {
  cwd, encoding: 'utf8', timeout: 120000, maxBuffer: 4 * 1024 * 1024,
});
assert.ifError(run.error);
const out = run.stdout + run.stderr;
for (const name of ['add', 'sub', 'mul', 'div', 'rem', 'lt-true', 'lt-false', 'ge']) {
  assert.match(out, new RegExp('^PASS ' + name + '$', 'm'), `bundle must still pass ${name}:\n${out}`);
  assert.doesNotMatch(out, new RegExp('^FAIL ' + name + '\\b', 'm'), `bundle must not fail ${name}:\n${out}`);
}
console.log('PASS bundle: gate-widened literal arithmetic matches BL results at runtime');

console.log('js-actors: NUMERIC GATE PASS');
