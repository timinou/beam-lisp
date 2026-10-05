// test/js/leaves.test.mjs — the leaf table is ONE table: every key has one
// owner, and the table refuses a second definition (PLAN-163 structural fix 2).
// Run: node --test test/js/
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import * as R from "../../priv/lib/js/rt.mjs";
import { ERLANG } from "../../priv/lib/js/host-leaves.mjs";

const dir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../priv/lib/js");

test("the leaf table loads (no key is defined twice)", async () => {
  const L = await import(path.join(dir, "leaves.mjs"));
  assert.ok(L.NAMES.length > 300, "expected the full table, got " + L.NAMES.length);
  assert.equal(new Set(L.NAMES).size, L.NAMES.length);
});

// The load check above only sees keys that reach the table. A static scan
// catches a duplicate the table would never get to see (a key repeated
// inside one object literal: JS keeps the LAST silently).
test("no leaf key is spelled twice in the leaf sources", () => {
  const seen = new Map();
  const dups = [];
  for (const f of ["leaves.mjs", "host-leaves.mjs", "lazy.mjs"]) {
    const src = fs.readFileSync(path.join(dir, f), "utf8");
    const lines = src.split("\n");
    lines.forEach((line, i) => {
      const m = line.match(/^\s*(?:\[LS \+ )?"([^"]+\/\d+)"\]?\s*:/);
      if (!m) return;
      const key = line.includes("[LS + ") ? "Elixir.BeamLisp.LazySeq/" + m[1] : m[1];
      if (seen.has(key)) dups.push(key + " at " + seen.get(key) + " and " + f + ":" + (i + 1));
      else seen.set(key, f + ":" + (i + 1));
    });
  }
  assert.deepEqual(dups, []);
});

// ─── erlang/bnot: exact integer complement (PLAN-163 R3) ─────────────────────
// The regression: JS `~` coerces a Number to signed 32 bits, so `(bnot
// 4294967296)` answered -1 instead of -4294967297. The leaf complements in
// BigInt and lets R.add normalize, matching the BEAM's arbitrary-precision
// integers over rt's one safe/BigInt model.
const bnot = ERLANG["erlang/bnot/1"];

test("bnot: exact complement across the 32- and 53-bit boundaries", () => {
  assert.equal(bnot(0), -1);
  assert.equal(bnot(5), -6);
  assert.equal(bnot(-1), 0);
  // 32-bit boundaries must not wrap.
  assert.equal(bnot(2147483647), -2147483648);
  assert.equal(bnot(2147483648), -2147483649);
  assert.equal(bnot(4294967295), -4294967296);
  assert.equal(bnot(4294967296), -4294967297); // was -1 without the fix
  assert.equal(bnot(-4294967296), 4294967295);
});

test("bnot: promotes past the safe-integer limit and normalizes back", () => {
  const MAXI = Number.MAX_SAFE_INTEGER; // 9007199254740991
  // A Number operand whose complement crosses the safe limit must promote …
  assert.equal(typeof bnot(MAXI), "bigint");
  assert.equal(bnot(MAXI), BigInt(-(MAXI + 1))); // -(2^53)
  // … and a BigInt operand whose complement fits must fall back to a Number.
  assert.equal(bnot(BigInt(-(MAXI + 1))), MAXI);
  assert.equal(typeof bnot(BigInt(-(MAXI + 1))), "number");
  // The negative boundary's complement is still a Number.
  assert.equal(bnot(Number.MIN_SAFE_INTEGER), MAXI - 1);
  // BigInt beyond the safe range keeps exact precision (no 32-bit truncation).
  assert.equal(bnot(9007199254740993n), -9007199254740994n);
  assert.equal(typeof bnot(9007199254740993n), "bigint");
});

test("bnot: rejects every non-integer with the Erlang-shaped badarg", () => {
  const isBadarg = (e) => e instanceof R.BLError && e.blType === R.kw("Elixir.ArgumentError");
  // floats stay distinct values (even whole), as do exact decimals; a
  // non-integer Number, a string, nil, booleans, keywords and lists are not
  // integers on the BEAM either.
  const invalid = [1.5, R.flt(5), R.flt(5.5), R.dec(5n, 0), "5", null, true, false, R.kw("a"), R.EMPTY];
  invalid.forEach((x, i) => assert.throws(() => bnot(x), isBadarg, "invalid operand #" + i));
});
// ─── lists/reverse: ONE exact reverse, arbitrary shared tail (PLAN-163) ──────
// `lists:reverse/2` reverses a PROPER first list onto an arbitrary tail and
// never forces it; `/1` is `/2` with the empty tail. `R.reverseI` is the one
// helper the emitter intrinsic and the `LEAVES` dispatch both call, so their
// values and their badarg cannot disagree.
const L = await import(path.join(dir, "leaves.mjs"));
const Z = await import(path.join(dir, "lazy.mjs"));
const xs = (l) => { const a = []; for (let p = l; p instanceof R.Cons; p = p.t) a.push(p.h); return a; };
const isBadarg = (e) => e instanceof R.BLError && e.blType === R.kw("Elixir.ArgumentError");

test("reverse/1: a proper list reverses, order and value exact", () => {
  assert.deepEqual(xs(R.reverseI(R.EMPTY)), []);
  assert.deepEqual(xs(R.reverseI(R.list(1, 2, 3))), [3, 2, 1]);
  assert.equal(R.reverseI(R.list(1, 2, 3)).n, 3);          // proper list
  assert.deepEqual(xs(R.reverseI(R.list("a", R.kw("b"), 3))), [3, R.kw("b"), "a"]);
  // the leaf is the intrinsic at arity 1
  assert.deepEqual(xs(L.LEAVES["lists/reverse/1"](R.list(1, 2, 3))), [3, 2, 1]);
});

test("reverse/2: the tail is shared and never forced; `/1` tails ()", () => {
  let forced = 0;
  const tail = Z.newLazy(() => { forced++; return R.list(9); });
  const r = R.reverseI(R.list(1, 2, 3), tail);
  assert.deepEqual(xs(r), [3, 2, 1]);
  assert.equal(r.t.t.t, tail);            // EXACT identity, not a copy
  assert.equal(r.n, -1);                  // improper: a lazy tail
  assert.equal(forced, 0);                // never forced
  assert.deepEqual(xs(R.reverseI(R.list(1, 2))), [2, 1]); // default tail
  const s = R.reverseI(R.list(1, 2), R.kw("end"));        // scalar tail allowed
  assert.deepEqual(xs(s), [2, 1]);
  assert.equal(s.t.t, R.kw("end"));
});

test("reverse/2: an empty first list returns the tail EXACTLY, unforced", () => {
  let forced = 0;
  const tail = Z.newLazy(() => { forced++; return R.list(1); });
  assert.equal(R.reverseI(R.EMPTY, tail), tail);
  assert.equal(R.reverseI(R.EMPTY, 42), 42);
  assert.equal(R.reverseI(R.EMPTY, R.kw("any")), R.kw("any"));
  assert.equal(forced, 0);
});

test("reverse: null/non-list/improper first arg is the Erlang-shaped badarg", () => {
  const improper = [new R.Cons(1, 2), new R.Cons(1, new R.Cons(2, 3)),
                    new R.Cons(1, Z.newLazy(() => R.list()))];
  const bad = [null, 5, "s", R.kw("k"), R.tup([1]), R.flt(1), ...improper];
  bad.forEach((x, i) => assert.throws(() => R.reverseI(x), isBadarg, "invalid/1 #" + i));
  bad.forEach((x, i) => assert.throws(() => R.reverseI(x, R.EMPTY), isBadarg, "invalid/2 #" + i));
});

test("reverse: the intrinsic and the LEAVES dispatch agree", () => {
  const l1 = L.LEAVES["lists/reverse/1"], l2 = L.LEAVES["lists/reverse/2"];
  const src = R.list(1, 2, 3), tail = R.list(9);
  assert.deepEqual(xs(l1(src)), xs(R.reverseI(src)));
  const a = l2(src, tail), b = R.reverseI(src, tail);
  assert.deepEqual(xs(a), xs(b));
  assert.equal(a.t.t.t, tail);
  assert.equal(b.t.t.t, tail);
  assert.throws(() => l1(new R.Cons(1, 2)), isBadarg);
  assert.throws(() => l2(new R.Cons(1, 2), tail), isBadarg);
});


test("Enumerable input cells use host map entries and graphemes", async () => {
  const Z = await import("../../priv/lib/js/lazy.mjs");
  const entry = Z.cell(R.EMPTY_MAP.assoc(R.kw("doc"), "doc"));
  assert.ok(entry instanceof R.Cons);
  assert.ok(entry.h instanceof R.Tup);
  assert.deepEqual(entry.h.items, [R.kw("doc"), "doc"]);
  assert.strictEqual(Z.cell(R.EMPTY_MAP), null);
  const chars = Z.toList("e\u0301👍🏽");
  assert.equal(chars.n, 2);
  assert.deepEqual([chars.h, chars.t.h], ["e\u0301", "👍🏽"]);
});
