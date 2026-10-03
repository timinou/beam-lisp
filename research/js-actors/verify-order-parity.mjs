// verify-order-parity.mjs — the SAME BL program, run on BEAM by the build and in
// JavaScript here, must print the same ordering answers, line for line.
//
// order-parity.bl pins `compare`, `sort` (including comparators that are not an
// order — only a faithful port of lists:sort/2 agrees there), `sort-by`, and a
// function value chosen from data and then called. The BEAM answers are
// out/order-parity.expected.json, written by compiler.bl at build time.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const cwd = new URL('.', import.meta.url);
const expected = JSON.parse(readFileSync(new URL('./out/order-parity.expected.json', cwd), 'utf8'));
assert.ok(Array.isArray(expected) && expected.length >= 18, 'expected answers missing');

const run = spawnSync(process.execPath, ['./out/order-parity.mjs'], {
  cwd, encoding: 'utf8', timeout: 120000, maxBuffer: 4 * 1024 * 1024,
});
assert.ifError(run.error);
assert.equal(run.status, 0, run.stdout + run.stderr);
const lines = run.stdout.split('\n');
assert.ok(lines.includes('ORDER-DONE'), 'the JS run did not finish:\n' + run.stdout + run.stderr);
const got = lines.filter(l => l.startsWith('ORDER ')).map(l => l.slice('ORDER '.length));

assert.equal(got.length, expected.length, 'answer count differs');
let diffs = 0;
for (let i = 0; i < expected.length; i++) {
  if (got[i] !== expected[i]) {
    diffs++;
    console.log(`DIFF ${i}\n  beam ${expected[i]}\n  js   ${got[i]}`);
  }
}
assert.equal(diffs, 0, `${diffs} ordering answer(s) differ between BEAM and JS`);

// The runtime refuses what it cannot order faithfully instead of guessing.
const refusals = spawnSync(process.execPath, ['--input-type=module', '-e', `
  import * as H from './host.mjs';
  const out = [];
  for (const [a, b] of [['a', 1], ['\\u{1F600}', '\\uFF5E']]) {
    try { out.push(H.lt(a, b)); } catch (e) { out.push('raise'); }
  }
  console.log(JSON.stringify(out));
`], { cwd, encoding: 'utf8' });
assert.equal(refusals.status, 0, refusals.stderr);
// a mixed pair raises; strings order by code point, not by UTF-16 unit
assert.deepEqual(JSON.parse(refusals.stdout), ['raise', false]);

console.log(`js-actors: ORDER PARITY PASS (${expected.length} answers identical to BEAM)`);
