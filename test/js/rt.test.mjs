// test/js/rt.test.mjs — the sync profile's value layer against plain models.
// Run: node --test test/js/
import { test } from "node:test";
import assert from "node:assert/strict";
import * as R from "../../priv/lib/js/rt.mjs";

function rng(seed) { let s = seed >>> 0; return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296); }

test("vector: random conj/assoc/pop against an array model", () => {
  const r = rng(7);
  let v = R.EMPTY_VEC; let a = [];
  const snapshots = [];
  for (let step = 0; step < 20000; step++) {
    const op = r();
    if (op < 0.55 || a.length === 0) { const x = Math.floor(r() * 1e6); v = v.conj(x); a.push(x); }
    else if (op < 0.85) { const i = Math.floor(r() * a.length); const x = -step; v = v.assocN(i, x); a[i] = x; }
    else { v = v.pop(); a.pop(); }
    if (step % 997 === 0) snapshots.push([v, a.slice()]);
    assert.equal(v.cnt, a.length);
  }
  assert.deepEqual(v.toArray(), a);
  // structural sharing must not leak: every old snapshot still reads its own items
  for (const [sv, sa] of snapshots) assert.deepEqual(sv.toArray(), sa);
  for (let i = 0; i < a.length; i += 37) assert.equal(v.nth(i), a[i]);
});

test("vector: crosses trie depths both ways", () => {
  let v = R.EMPTY_VEC;
  const N = 32 * 32 * 33 + 5;  // past two levels of root growth
  for (let i = 0; i < N; i++) v = v.conj(i);
  assert.equal(v.cnt, N);
  for (let i = 0; i < N; i += 101) assert.equal(v.nth(i), i);
  for (let i = N; i > 0; i--) { v = v.pop(); if (i % 503 === 0) assert.equal(v.nth(v.cnt - 1), v.cnt - 1); }
  assert.equal(v.cnt, 0);
});

test("map: random assoc/dissoc against a Map model, with colliding hashes", () => {
  const r = rng(11);
  let m = R.EMPTY_MAP; const model = new Map();
  const keyOf = (n) => (n % 3 === 0 ? R.kw("k" + n) : n % 3 === 1 ? "s" + n : n);
  for (let step = 0; step < 30000; step++) {
    const n = Math.floor(r() * 3000);
    const k = keyOf(n);
    if (r() < 0.7) { m = m.assoc(k, step); model.set(n, step); }
    else { m = m.dissoc(k); model.delete(n); }
    assert.equal(m.cnt, model.size);
  }
  for (const [n, v] of model) assert.equal(m.get(keyOf(n)), v);
  assert.equal(m.get("absent", "dflt"), "dflt");
});

test("map: forced full-hash collisions are kept apart and removable", () => {
  // two distinct vectors, same items in a different collection kind collide on
  // purpose? No — build keys that collide by brute force on a tiny space.
  const seen = new Map(); let a, b;
  for (let i = 0; i < 2e6 && a === undefined; i++) {
    const h = R.hashOf("c" + i);
    if (seen.has(h)) { a = seen.get(h); b = "c" + i; } else seen.set(h, "c" + i);
  }
  assert.ok(a !== undefined, "found a 32-bit collision");
  let m = R.hashMap(a, 1, b, 2, "x", 3);
  assert.equal(m.get(a), 1); assert.equal(m.get(b), 2); assert.equal(m.cnt, 3);
  m = m.dissoc(a);
  assert.equal(m.get(a, null), null); assert.equal(m.get(b), 2); assert.equal(m.cnt, 2);
});

test("equality: sequential family under =, distinct under key equality", () => {
  const v = R.vec(1, 2), l = R.list(1, 2);
  assert.ok(R.eqv(v, l));
  assert.ok(!R.keyEq(v, l));
  const m = R.hashMap(v, "v");
  assert.equal(m.get(l, null), null);
  assert.equal(m.get(R.vec(1, 2)), "v");
  // measured on BEAM 2026-10-03: (= 1 1.0) true, (= [1] [1.0]) true,
  // but (get {1 :a} 1.0) nil and (contains? #{1} 1.0) false
  assert.ok(R.eqv(1, R.flt(1)), "(= 1 1.0) is true on BEAM");
  assert.ok(R.eqv(R.vec(1), R.vec(R.flt(1))));
  assert.ok(!R.keyEq(1, R.flt(1)), "1 and 1.0 are distinct keys");
  assert.equal(R.hashMap(1, "a").get(R.flt(1), null), null);
  assert.ok(!R.eqv(2, R.flt(2.5)));
  assert.ok(R.numEq(1, R.flt(1)), "(== 1 1.0) is true");
  assert.ok(R.eqv(R.hashMap(R.kw("a"), R.vec(1)), R.hashMap(R.kw("a"), R.list(1))));
});

test("exact integers: promotion to BigInt and back", () => {
  const big = R.mul(9007199254740993n, 3);
  assert.equal(big, 27021597764222979n);
  assert.equal(R.sub(R.add(9007199254740991, 2), 2), 9007199254740991);
  assert.equal(typeof R.sub(R.add(9007199254740991, 2), 2), "number");
  // the Elm bug: (a + b) / 2 on epoch millis must not wrap
  const t = 1759490000000;
  assert.equal(R.quot(R.add(t, t), 2), t);
  assert.equal(R.printStr(R.div(8, 2)), "4.0");
  assert.equal(R.mod(-7, 3), 2); assert.equal(R.rem(-7, 3), -1); assert.equal(R.quot(-7, 2), -3);
});

test("strings: codepoint subs and compare", () => {
  const s = "a👍🏽b";
  assert.equal(R.cpCount(s), 4);
  assert.equal(R.subs(s, 1, 2), "👍");
  assert.equal(R.subs(s, 3), "b");
  assert.throws(() => R.subs(s, 2, 9));
  assert.ok(R.strCmp("\u{1F600}", "\uFF5E") > 0, "codepoint order, not UTF-16");
});

test("printing is deterministic for maps and sets", () => {
  const m = R.hashMap(R.kw("b"), 2, R.kw("a"), 1, "s", 3, 4, 4);
  assert.equal(R.printStr(m), '{4 4, :a 1, :b 2, "s" 3}');
  assert.equal(R.printStr(R.hashSet(3, 1, 2)), "#{1 2 3}");
});
