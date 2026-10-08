// verify-numeric-exact.mjs — host.mjs arithmetic and value edge cases for the
// exact-integer change. BEAM-observable behaviour is pinned by order-parity.bl;
// this file pins the host leaves directly, where the parity printer cannot
// reach (canonical forms, hash equality, mixed Number/BigInt comparison).
//
//   node research/js-actors/verify-numeric-exact.mjs
//
// Prints `js-actors: EXACT PASS (N checks)` on success.
import assert from 'node:assert/strict';
import * as H from './host.mjs';

let checks = 0;
function ok(label, cond) {
  checks++;
  assert.ok(cond, label);
}
function isNum(v) { return typeof v === 'number'; }
function isBig(v) { return typeof v === 'bigint'; }

// ── exact integers beyond the safe range, normalization back ─────────────────

const b = H.arith('add', 9007199254740991, 1);          // 2^53
ok('safe+1 promotes to BigInt', isBig(b) && b === 9007199254740992n);
ok('promoted value fits back to Number', isNum(H.arith('sub', b, 1)) && H.arith('sub', b, 1) === 9007199254740991);
ok('safe small sum stays a Number', isNum(H.arith('add', 1, 2)) && H.arith('add', 1, 2) === 3);
ok('product beyond 2^53 is exact', H.arith('mul', 4294967296, 4294967296) === 18446744073709551616n);
ok('square of 123456789012 is exact', H.arith('mul', 123456789012, 123456789012) === 15241578753153483936144n);
ok('negative big', H.arith('sub', 0, 9007199254740993n) === -9007199254740993n);
ok('big + big normalizes', isNum(H.arith('add', 9007199254740992n, -1n)));
ok('big * 1 stays exact', H.arith('mul', 9007199254740993n, 1) === 9007199254740993n);

// ── quot / rem / mod: truncating divide, C remainder, floor mod ──────────────

ok('quot truncates toward zero', H.arith('quot', 7, 2) === 3 && H.arith('quot', -7, 2) === -3);
ok('quot negative divisor', H.arith('quot', 7, -2) === -3 && H.arith('quot', -7, -2) === 3);
ok('rem keeps the dividend sign', H.arith('rem', -7, 2) === -1 && H.arith('rem', 7, -2) === 1);
ok('mod keeps the divisor sign', H.arith('mod', -7, 2) === 1 && H.arith('mod', 7, -2) === -1);
ok('big quot', H.arith('quot', 9007199254740993n, 7) === 1286742750677284);
ok('big rem', H.arith('rem', -9007199254740993n, 7) === -5);
ok('big mod', H.arith('mod', -9007199254740993n, 7) === 2);
assert.throws(() => H.arith('mod', 1, 0), /mod by zero/); checks++;
assert.throws(() => H.arith('quot', 1, 0), /divide by zero/); checks++;
assert.throws(() => H.arith('rem', 7.5, 2), /needs two integers/); checks++;

// ── division is a float; a BigInt operand becomes one (float contagion) ───────

ok('div of ints is the double quotient', H.arith('div', 8, 2) === 4 && H.arith('div', 7, 2) === 3.5);
ok('div of a BigInt is a float', H.arith('div', 9007199254740993n, 1) === 9007199254740992);
ok('float contagion converts a BigInt to a Number', isNum(H.arith('add', 9007199254740993n, 0.25)) && H.arith('add', 9007199254740993n, 0.25) === 9007199254740992);
ok('float contagion with a fraction', H.arith('sub', 9007199254740993n, 0.5) === 9007199254740991.5);

// ── hashing and equality across the Number/BigInt boundary ───────────────────

ok('hashKey of a small BigInt is canonical', H.hashKey(1n) === H.hashKey(1));
ok('hashKey of a large BigInt is its digits', H.hashKey(9007199254740993n) === 'n:9007199254740993');
ok('eq normalizes Number/BigInt', H.eq(1n, 1) && H.eq(9007199254740993n, 9007199254740993n));
ok('distinct big values are not equal', !H.eq(9007199254740993n, 9007199254740992n));

// ── predicates and ordering ──────────────────────────────────────────────────

ok('isInt/isNum accept BigInt', H.isInt(1n) && H.isNum(1n) && !H.isFloat(1n));
ok('lt across Number/BigInt', H.lt(2n, 3) && !H.lt(9007199254740993n, 9007199254740992n) && H.lt(1n, 1.5));
ok('keyOrder: integers before floats', H.keyOrder(-1, -2.5) < 0 && H.keyOrder(2, 2.5) < 0);
ok('keyOrder: number < atom < string', H.keyOrder(3, H.kw('a')) < 0 && H.keyOrder(H.kw('a'), 's') < 0);
ok('keyOrder: bigints sort numerically', H.keyOrder(2, 9007199254740993n) < 0);

// ── sets: membership, order, structural identity ─────────────────────────────

const s1 = H.setFromList(H.listFromArray([3, 1, 2, 1]));
const s2 = H.setFromList(H.listFromArray([1, 3, 2]));
ok('set dedups', H.setSize(s1) === 3);
ok('set membership', H.setHas(s1, 2) && !H.setHas(s1, 9));
ok('set enumerates in map-key order', JSON.stringify(H.listToArray(H.setToList(s1)).map(Number)) === '[1,2,3]');
ok('set equality is order-independent', H.eq(s1, s2));
ok('set hashKey is order-independent', H.hashKey(s1) === H.hashKey(s2));
ok('set of sets', H.setHas(H.setFromList(H.listFromArray([s1, H.setFromList(H.listFromArray([9]))])), s2));

console.log(`js-actors: EXACT PASS (${checks} checks)`);
