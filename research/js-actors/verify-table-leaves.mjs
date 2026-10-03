// verify-table-leaves.mjs — focused verifier for the host's mutable-table
// STORAGE primitive (the FEAT-052 slice).
//
// The host owns one thing here: a native `Map` per table, updated IN PLACE, and
// a handle that names it. The handle is a host object, so no BL value can forge
// one, and it is bound to the runtime that minted it, so a leaf called on
// another runtime refuses it. Ownership, heir, access mode, naming and the
// atomic counter are BL decisions taken ABOVE these leaves — this file asserts
// the host does NOT take them: `table-new` takes no owner/heir/mode, and a
// handle is not a BL map.
//
// What is checked, in order:
//   1. the ABI surface (exact leaf names, which table is PURE vs RT_HOST);
//   2. the handle is non-forgeable and not a BL map;
//   3. identity isolation (distinct handles; one runtime refuses another's);
//   4. structural keys, reusing `hashKey`, including the injective pair;
//   5. mutation visibility, values kept BY REFERENCE, and the untouched
//      immutability of `mapPut`/`BMap`;
//   6. delete/size and the two absence answers;
//   7. invalid handle and use-after-destroy;
//   8. the loud memory/key bounds;
//   9. SCALING — measured, not asserted against a brittle absolute: the
//      per-operation cost of lookup and write at two table sizes 16x apart must
//      stay flat, while the copy cost of `mapPut` is measured at the SAME sizes
//      as the contrast (a copy-per-write store grows ~16x; a flat store ~1x).
//
// Standalone: no generated bundle, no compiler run.
//   node research/js-actors/verify-table-leaves.mjs
import assert from 'node:assert/strict';
import * as H from './host.mjs';

const now = () => globalThis.performance.now();
const leaf = (rt, name) => H.hostRef(rt, name);
const size = (rt, h) => leaf(rt, 'table-size')(h);
const row = (rt, h, k) => leaf(rt, 'table-lookup')(h, k);
const val = (rt, h, k) => {
  const r = row(rt, h, k);
  return r === null ? null : H.tupEl(r, 1);
};

// ── 1. the ABI surface ───────────────────────────────────────────────────────
// The exact names a later compiler allowlist must add to `host/…`.
const LEAVES = ['table-new', 'table-lookup', 'table-insert', 'table-delete',
  'table-size', 'table-destroy', 'table-snapshot', 'is-table'];
for (const n of LEAVES) assert.ok(H.hostNames().includes(n), `host leaf ${n} is not registered`);
// The value predicate is PURE (it reads no runtime); every storage op needs the
// runtime to validate the handle, so it is an RT_HOST leaf.
assert.ok(Object.prototype.hasOwnProperty.call(H.PURE, 'is-table'));
assert.equal(H.PURE['is-table'], H.isTable);
for (const n of LEAVES.filter(n => n !== 'is-table'))
  assert.ok(Object.prototype.hasOwnProperty.call(H.RT_HOST, n), `${n} must be an RT_HOST leaf`);
assert.throws(() => H.hostRef(H.newRuntime(), 'table-nope'), /unknown host intrinsic/);
console.log('PASS table ABI: ' + LEAVES.map(n => 'host/' + n).join(' '));

// ── 2. the handle is non-forgeable and not a BL map ──────────────────────────
const rA = H.newRuntime();
const rB = H.newRuntime();       // a SECOND runtime in the same process
const h = leaf(rA, 'table-new')();
assert.equal(H.isTable(h), true);
assert.equal(H.isTable({ __table: true, rt: rA.runtimeId, m: new Map(), dead: false }), false,
  'a plain object that LOOKS like a handle must not pass');
for (const impostor of [null, undefined, 0, 'table', [], H.bmap([]), H.vec([]), H.tup([H.kw('table')])])
  assert.equal(H.isTable(impostor), false, 'is-table accepted a forged value: ' + H.describe(impostor));
assert.throws(() => leaf(rA, 'table-lookup')({ __table: true }, H.kw('k')), /not a table handle/);
assert.throws(() => leaf(rA, 'table-size')(null), /not a table handle/);
assert.throws(() => leaf(rA, 'table-insert')(H.vec([]), H.kw('k'), 1), /not a table handle/);
// No transparent alias to an ordinary BL map.
assert.equal(H.isMap(h), false);
assert.equal(H.isBMap(h), false);
assert.equal(H.isStruct(h), false);
assert.equal(H.mapSize(h), 0);
assert.equal(H.mapGet(h, H.kw('k')), null);
console.log('PASS table handle: opaque, non-forgeable, not a BL map');
console.log('     describe -> ' + H.describe(h));

// ── 3. identity isolation ────────────────────────────────────────────────────
const h2 = leaf(rA, 'table-new')();
assert.notEqual(H.hashKey(h), H.hashKey(h2), 'two handles shared a structural key');
assert.equal(H.eq(h, h2), false);
assert.notEqual(H.describe(h), H.describe(h2));
leaf(rA, 'table-insert')(h, H.kw('k'), 'a');
assert.equal(size(rA, h), 1);
assert.equal(size(rA, h2), 0, 'a second table saw the first table\'s row');
// Another runtime cannot touch a handle it did not mint, and the refusal does
// not disturb the owning runtime's table.
for (const n of ['table-lookup', 'table-size', 'table-snapshot', 'table-destroy'])
  assert.throws(() => leaf(rB, n)(h, ...(n === 'table-lookup' ? [H.kw('k')] : [])), /another runtime/);
assert.throws(() => leaf(rB, 'table-insert')(h, H.kw('k'), 1), /another runtime/);
assert.throws(() => leaf(rB, 'table-delete')(h, H.kw('k')), /another runtime/);
assert.equal(size(rA, h), 1, 'a cross-runtime refusal mutated the table');
assert.equal(val(rA, h, H.kw('k')), 'a');
assert.notEqual(rA.runtimeId, rB.runtimeId, 'two runtimes shared an identity');
// The host holds no owner/heir/mode: `table-new` has no argument for one.
assert.equal(leaf(rA, 'table-new').length, 0, 'table-new accepts an owner/heir/mode argument');
console.log(`PASS table identity isolation: runtimes ${rA.runtimeId}/${rB.runtimeId} stay disjoint`);

// ── 4. structural keys (the target's own hashKey) ────────────────────────────
const t = leaf(rA, 'table-new')();
const keyA = H.vec([H.kw('x'), H.kw('y')]);
leaf(rA, 'table-insert')(t, keyA, 'vec-pair');
// A FRESHLY built, structurally equal key finds the row ...
const hit = row(rA, t, H.vec([H.kw('x'), H.kw('y')]));
assert.ok(H.isTup(hit));
assert.equal(H.tupEl(hit, 1), 'vec-pair');
// ... and the row hands back the STORED key object, not the probe.
assert.ok(H.identical(H.tupEl(hit, 0), keyA), 'lookup must answer the stored key');
// Injectivity: a naive join once confused these two, so they stay apart.
const flat = H.vec([H.kw('x,k:y')]);
const pair = H.vec([H.kw('x'), H.kw('y')]);
assert.notEqual(H.hashKey(flat), H.hashKey(pair));
leaf(rA, 'table-insert')(t, flat, 'one');
assert.equal(val(rA, t, H.vec([H.kw('x,k:y')])), 'one');
assert.equal(val(rA, t, H.vec([H.kw('x'), H.kw('y')])), 'vec-pair', 'two distinct keys collided');
// Keyword and string are different keys; a nested map is a key.
leaf(rA, 'table-insert')(t, H.kw('a'), 'kw');
leaf(rA, 'table-insert')(t, 'a', 'str');
assert.equal(val(rA, t, H.kw('a')), 'kw');
assert.equal(val(rA, t, 'a'), 'str');
assert.equal(val(rA, t, H.bmap([[H.kw('k'), H.vec([1, 2])]])), null);
leaf(rA, 'table-insert')(t, H.bmap([[H.kw('k'), H.vec([1, 2])]]), 'nested');
assert.equal(val(rA, t, H.bmap([[H.kw('k'), H.vec([1, 2])]])), 'nested');
// nil and booleans are keys, and a row holding nil is distinguishable from a miss.
leaf(rA, 'table-insert')(t, null, 'nil-key');
leaf(rA, 'table-insert')(t, H.kw('nil-valued'), null);
assert.equal(val(rA, t, null), 'nil-key');
assert.equal(val(rA, t, H.kw('nil-valued')), null);
assert.ok(H.isTup(row(rA, t, H.kw('nil-valued'))), 'a present nil-valued row must not read as a miss');
assert.equal(row(rA, t, H.kw('absent')), null);
console.log('PASS table structural keys: vectors, keyword/string, nested maps, nil');

// ── 5. mutation visibility, values by reference, mapPut unchanged ────────────
const deep = H.vec([H.kw('deep'), H.bmap([[H.kw('k'), H.tup([1, 'two'])]]), H.cons(1, H.ENIL)]);
leaf(rA, 'table-insert')(t, H.kw('v'), deep);
assert.ok(H.identical(val(rA, t, H.kw('v')), deep), 'the value must round-trip by reference (no clone)');
// A write is visible through every alias of the SAME handle (in-place), and
// `table-insert` answers `true` — a mutation — never a replacement handle.
const alias = t;
leaf(rA, 'table-insert')(t, H.kw('v'), 'replaced');
assert.equal(val(rA, alias, H.kw('v')), 'replaced');
assert.equal(leaf(rA, 'table-insert')(t, H.kw('fresh'), 1), true);
// The BL map path stays a persistent value: mapPut answers a NEW map and the
// original is untouched. That behaviour is protected here.
const m0 = H.bmap([[H.kw('a'), 1]]);
const m1 = H.mapPut(m0, H.kw('b'), 2);
assert.notEqual(m0, m1);
assert.equal(H.mapGet(m0, H.kw('b')), null, 'mapPut mutated its input');
assert.equal(H.mapSize(m0), 1);
assert.equal(H.mapGet(m1, H.kw('b')), 2);
const m2 = H.mapRemove(m1, H.kw('b'));
assert.equal(H.mapHas(m1, H.kw('b')), true, 'mapRemove mutated its input');
assert.equal(H.mapHas(m2, H.kw('b')), false);
console.log('PASS table mutation visibility + mapPut/BMap immutability preserved');

// ── 6. delete and size ───────────────────────────────────────────────────────
const s0 = size(rA, t);
assert.equal(leaf(rA, 'table-delete')(t, H.kw('fresh')), true, 'delete of a present row answers true');
assert.equal(size(rA, t), s0 - 1);
assert.equal(row(rA, t, H.kw('fresh')), null);
assert.equal(leaf(rA, 'table-delete')(t, H.kw('fresh')), false, 'delete of an absent row is a no-op');
assert.equal(size(rA, t), s0 - 1);
console.log(`PASS table delete/size: ${s0} -> ${size(rA, t)} rows`);

// ── 7. snapshot copy ─────────────────────────────────────────────────────────
assert.ok(H.isEnil(leaf(rA, 'table-snapshot')(leaf(rA, 'table-new')())), 'an empty snapshot is the empty list');
const snap = leaf(rA, 'table-snapshot')(t);
assert.ok(H.isList(snap));
const rows = H.listToArray(snap);
assert.equal(rows.length, size(rA, t));
for (const r of rows) { assert.ok(H.isTup(r)); assert.equal(H.tupSize(r), 2); }
for (const r of rows) assert.ok(H.eq(val(rA, t, H.tupEl(r, 0)), H.tupEl(r, 1)), 'snapshot row disagrees with the live table');
// A later write does not change an earlier snapshot.
leaf(rA, 'table-insert')(t, H.kw('after-snapshot'), 1);
assert.equal(H.listToArray(snap).length, rows.length, 'the snapshot was not a copy');
console.log(`PASS table snapshot: ${rows.length} stable rows, insertion order`);

// ── 8. invalid handle and use-after-destroy ─────────────────────────────────
const d = leaf(rA, 'table-new')();
leaf(rA, 'table-insert')(d, H.kw('k'), 1);
assert.equal(leaf(rA, 'table-destroy')(d), true);
assert.throws(() => row(rA, d, H.kw('k')), /destroyed/);
assert.throws(() => leaf(rA, 'table-insert')(d, H.kw('k'), 1), /destroyed/);
assert.throws(() => leaf(rA, 'table-delete')(d, H.kw('k')), /destroyed/);
assert.throws(() => size(rA, d), /destroyed/);
assert.throws(() => leaf(rA, 'table-snapshot')(d), /destroyed/);
assert.throws(() => leaf(rA, 'table-destroy')(d), /destroyed/, 'a second destroy must be refused');
assert.equal(H.isTable(d), true, 'the predicate names the handle; only operations refuse it');
assert.ok(size(rA, t) > 0, 'destroying one table disturbed another');
console.log('PASS table use-after-destroy refused, siblings intact');

// ── 9. loud memory/key bounds ────────────────────────────────────────────────
assert.ok(H.TABLE_LIMITS.entries > 0 && H.TABLE_LIMITS.key > 0 && H.TABLE_LIMITS.tables > 0);
assert.throws(() => leaf(rA, 'table-insert')(t, 'x'.repeat(H.TABLE_LIMITS.key), 1), /key is too large/,
  'an over-size key must be refused, not hashed');
const big = leaf(rA, 'table-new')();
const cap = H.TABLE_LIMITS.entries;
for (let i = 0; i < cap; i++) leaf(rA, 'table-insert')(big, i, i);
assert.equal(size(rA, big), cap);
assert.throws(() => leaf(rA, 'table-insert')(big, cap, cap), /table is full/, 'the entry bound must be loud');
assert.equal(leaf(rA, 'table-insert')(big, cap - 1, 'over'), true, 'an overwrite is allowed at the bound');
leaf(rA, 'table-destroy')(big);
const rC = H.newRuntime();
const tcap = H.TABLE_LIMITS.tables;
for (let i = 0; i < tcap; i++) leaf(rC, 'table-new')();
assert.throws(() => leaf(rC, 'table-new')(), /too many live tables/, 'the live-table bound must be loud');
console.log(`PASS table bounds: entries=${H.TABLE_LIMITS.entries} key=${H.TABLE_LIMITS.key} tables=${H.TABLE_LIMITS.tables}`);

// ── 10. scaling, measured ────────────────────────────────────────────────────
// Per-operation cost at two table sizes 16x apart. An in-place store is flat
// (ratio ~1, plus a cache constant); a copy-per-write store grows with the
// table. The gate is on the RATIO, so it does not depend on machine speed:
// O(n) at a 16x size gap crosses 8x, a flat store does not.
function perOp(tableSize, ops) {
  const th = leaf(rA, 'table-new')();
  for (let i = 0; i < tableSize; i++) leaf(rA, 'table-insert')(th, i, i);
  for (let i = 0; i < 2000; i++) leaf(rA, 'table-lookup')(th, i % tableSize);   // warm
  let bestLook = Infinity, bestIns = Infinity;
  for (let pass = 0; pass < PASSES; pass++) {
    let t0 = now();
    for (let i = 0; i < ops; i++) leaf(rA, 'table-lookup')(th, i % tableSize);
    bestLook = Math.min(bestLook, (now() - t0) / ops);
    t0 = now();
    for (let i = 0; i < ops; i++) leaf(rA, 'table-insert')(th, (pass * ops + i) % tableSize, i);
    bestIns = Math.min(bestIns, (now() - t0) / ops);
  }
  leaf(rA, 'table-destroy')(th);
  return { lookup: bestLook, insert: bestIns };
}
// The contrast: `mapPut` copies the whole map, so its per-op cost grows with
// size. The base map is built by the `bmap` constructor (O(n)), not by repeated
// `mapPut` (O(n^2)), so the SAME sizes as the table can be measured.
function mapPutPerOp(mapSize, ops) {
  const pairs = [];
  for (let i = 0; i < mapSize; i++) pairs.push([i, i]);
  let m = H.bmap(pairs);
  let best = Infinity;
  for (let pass = 0; pass < 3; pass++) {
    const t0 = now();
    for (let i = 0; i < ops; i++) m = H.mapPut(m, i % mapSize, i);
    best = Math.min(best, (now() - t0) / ops);
  }
  return best;
}

const S_SMALL = 4000, S_LARGE = 64000, OPS = 40000, PASSES = 7;   // 16x apart
const small = perOp(S_SMALL, OPS);
const large = perOp(S_LARGE, OPS);
const lookupRatio = large.lookup / small.lookup;
const insertRatio = large.insert / small.insert;
console.log(`MEASURE table per-op (ms): size ${S_SMALL} lookup=${small.lookup.toFixed(4)} insert=${small.insert.toFixed(4)}`);
console.log(`MEASURE table per-op (ms): size ${S_LARGE} lookup=${large.lookup.toFixed(4)} insert=${large.insert.toFixed(4)}`);
console.log(`MEASURE ratio at 16x size: lookup=${lookupRatio.toFixed(2)}x insert=${insertRatio.toFixed(2)}x`);
assert.ok(lookupRatio < 8, `lookup per-op grew ${lookupRatio.toFixed(2)}x when the table grew 16x — O(n), not O(1)`);
assert.ok(insertRatio < 8, `write per-op grew ${insertRatio.toFixed(2)}x when the table grew 16x — O(n), not O(1)`);
const MP_SMALL = S_SMALL, MP_LARGE = S_LARGE;   // same sizes as the table, for a direct contrast
const mpSmall = mapPutPerOp(MP_SMALL, 300);
const mpLarge = mapPutPerOp(MP_LARGE, 300);
const mpRatio = mpLarge / mpSmall;
console.log(`MEASURE mapPut per-op (ms): size ${MP_SMALL}=${mpSmall.toFixed(4)} size ${MP_LARGE}=${mpLarge.toFixed(4)} ratio=${mpRatio.toFixed(2)}x`);
assert.ok(mpRatio > 4, `mapPut should still clone per write (ratio ${mpRatio.toFixed(2)}x) — the contrast is the point`);
console.log('PASS table scaling: flat lookup/write per-op vs mapPut\'s growing copy cost');

console.log(`TABLE-LEAVES PASS — ABI: ${LEAVES.map(n => 'host/' + n).join(', ')}`);
