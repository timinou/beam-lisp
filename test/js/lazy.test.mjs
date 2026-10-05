// test/js/lazy.test.mjs — `BeamLisp.LazySeq/input` and `SeqCursor` on the
// sync profile: only a PROPER finite list longer than one chunk cursorizes, a
// chain ending in a lazy (or any non-`()`) tail is returned UNCHANGED and
// walks through its suffix. Run: node --test test/js/
import { test } from "node:test";
import assert from "node:assert/strict";
import * as R from "../../priv/lib/js/rt.mjs";
import * as Z from "../../priv/lib/js/lazy.mjs";

/** 1..n as a proper eager list. */
const proper = (n) => R.listFromArray(Array.from({ length: n }, (_, i) => i + 1));

/** n cons cells (n..1, in build order) then `tail` — n=-1 chains. */
function stack(n, tail) { let xs = tail; for (let i = n; i >= 1; i--) xs = new R.Cons(i, xs); return xs; }

test("input: a proper finite list cursorizes only past one chunk", () => {
  for (const n of [0, 1, 31, 32]) {
    const xs = n === 0 ? R.EMPTY : proper(n);
    assert.strictEqual(Z.input(xs), xs, `proper list of ${n} must stay itself`);
  }
  for (const n of [33, 40, 65]) {
    assert.ok(Z.input(proper(n)) instanceof Z.SeqCursor, `proper list of ${n} must cursorize`);
  }
});

test("input: a lazy-tailed chain of any length is left intact, without forcing", () => {
  for (const n of [1, 31, 32, 33, 40, 65]) {
    let forced = 0;
    const xs = stack(n, Z.newLazy(() => { forced++; return R.list(99); }));
    assert.strictEqual(Z.input(xs), xs, `lazy-tailed chain of ${n} must not cursorize`);
    assert.equal(forced, 0, `input of a ${n}-cell chain must not force the tail`);
  }
});

test("input: a lazy-tailed chain walks through to its suffix", () => {
  const cases = [
    [31, () => R.list(99), 32],
    [32, () => R.list(99), 33],
    [33, () => R.list(99), 34],
    [40, () => R.list(99), 41],
    [65, () => R.list(99), 66],
    [31, () => null, 31],          // lazy nil tail: nothing after the prefix
    [33, () => R.EMPTY, 33],
    [40, () => null, 40],
    [65, () => null, 65],
  ];
  for (const [n, tail, want] of cases) {
    const inp = Z.input(stack(n, Z.newLazy(tail)));
    assert.equal(Z.count(inp), want, `count of ${n} + tail`);
    assert.equal(Z.toList(inp).n, want, `toList of ${n} + tail`);
  }
});

test("input: the suffix is realised exactly once across walks", () => {
  let forced = 0;
  const xs = stack(40, Z.newLazy(() => { forced++; return R.list(99); }));
  assert.strictEqual(Z.input(xs), xs);
  assert.equal(Z.toList(xs).n, 41);
  assert.equal(Z.toList(xs).n, 41);
  assert.equal(Z.count(xs), 41);
  assert.equal(forced, 1, "one shared lazy node realises once");
});

test("input: vectors unwrap and reclassify like the BEAM input/1", () => {
  const v33 = R.vecFromArray(Array.from({ length: 33 }, (_, i) => i));
  assert.ok(Z.input(v33) instanceof Z.SeqCursor);
  const v32 = R.vecFromArray(Array.from({ length: 32 }, (_, i) => i));
  const r = Z.input(v32);
  assert.ok(r instanceof R.Cons);
  assert.equal(Z.count(r), 32);
  assert.strictEqual(Z.input(R.EMPTY_VEC), R.EMPTY);
});

test("input: a malformed scalar-tailed chain is not silently cursorized", () => {
  const xs = stack(40, 2);                     // 40 conses ending in a scalar
  assert.strictEqual(Z.input(xs), xs, "an improper list is left for the walk");
  assert.throws(() => Z.toList(xs), /not a list cell/);
  // short scalar-tailed list: same answer before and after the change
  const short = stack(3, 2);
  assert.strictEqual(Z.input(short), short);
});

test("SeqCursor.cell: [head | cursor'] over a proper list, nil at the end", () => {
  const cur = Z.input(proper(40));
  assert.ok(cur instanceof Z.SeqCursor);
  const seen = [];
  for (let c = cur.cell(); c !== null; c = c.t.cell()) {
    assert.ok(c instanceof R.Cons);
    assert.equal(c.h, seen.length + 1);
    assert.ok(c.t instanceof Z.SeqCursor, "every cell tail is a sub-cursor");
    seen.push(c.h);
  }
  assert.deepEqual(seen, Array.from({ length: 40 }, (_, i) => i + 1));
  // a list at or below the chunk boundary stays a plain list, never a cursor
  assert.ok(Z.input(proper(3)) instanceof R.Cons);
});

test("cell(): the cursor and the plain list agree element for element", () => {
  const xs = proper(40);
  const a = Z.cell(Z.input(xs));
  const b = Z.cell(xs);
  assert.ok(a instanceof R.Cons);
  assert.equal(a.h, b.h);
  assert.equal(Z.count(Z.input(xs)), Z.count(xs));
});

test("input: nil and () normalize to nil, not a cursor", () => {
  assert.equal(Z.cell(null), null);
  assert.strictEqual(Z.input(null), null);
  assert.strictEqual(Z.input(R.EMPTY), R.EMPTY);
});

// ─── with-meta: ONE native memo resource per node ──────────────────────────
// `with-meta` on a lazy node is an immutable metadata update that SHARES the
// node's native memo (the BEAM struct's `:resource`), exactly like
// `BeamLisp.Meta/with_meta` (priv/host/meta.bl). Realization, retry, the fold
// claim protocol and the cycle guard belong to the node, never to a
// per-metadata copy.

/** The state tag (the first field) `Z.memoState` reports. */
const tag = (x) => Z.memoState(x).items[0].fq;

test("withMeta: alias and original share one realization", () => {
  let calls = 0;
  const s = Z.newLazy(() => { calls++; return R.list(1, 2); });
  const a = Z.withMeta(s, R.EMPTY_MAP);
  assert.equal(calls, 0, "with-meta forces nothing");
  assert.equal(Z.count(Z.force(a)), 2);
  assert.equal(tag(a), "completed");
  assert.equal(tag(s), "completed", "the original sees the alias's realization");
  assert.equal(Z.count(Z.force(s)), 2);
  assert.equal(calls, 1, "one shared node realises once");
});

test("withMeta: retry and terminal flags are shared", () => {
  let calls = 0;
  const flaky = Z.newLazy(() => {
    if (++calls < 2) throw new Error("boom");
    return R.list(7);
  });
  const alias = Z.withMeta(flaky, R.EMPTY_MAP);
  assert.throws(() => Z.force(alias), /boom/);
  assert.equal(tag(alias), "failed");
  assert.equal(tag(flaky), "failed", "the failure is the node's, seen through both");
  // retriable: the alias's failure leaves the ORIGINAL able to run again
  assert.equal(R.printStr(Z.force(flaky)), "(7)");
  assert.equal(tag(alias), "completed");
  assert.equal(calls, 2);
});

test("withMeta: claim/completion/release are the shared node state", () => {
  const recipe = () => R.list(3, 4);
  const s = Z.newLazy(recipe, recipe);
  const a = Z.withMeta(s, R.EMPTY_MAP);
  const claim = Z.claimRecipe(s);
  assert.notEqual(claim, null);
  assert.equal(tag(a), "running", "the claim is visible through the alias");
  Z.completeAttempt(s, claim.items[1], R.list(3, 4));
  assert.equal(tag(a), "completed");
  assert.equal(R.printStr(Z.force(a)), "(3 4)");

  const g = Z.newLazy(recipe, recipe);
  const ga = Z.withMeta(g, R.EMPTY_MAP);
  const cl = Z.claimRecipe(g);
  assert.equal(tag(ga), "running");
  Z.releaseRecipe(g, cl.items[1], cl.items[2]);
  assert.equal(tag(ga), "pending", "release hands the node back through the alias");
});

test("withMeta: metadata is value-owned, immutable and independent", () => {
  const s = Z.newLazy(() => R.list(1));
  const a = Z.withMeta(s, R.EMPTY_MAP);
  const b = Z.withMeta(s, R.EMPTY_MAP.assoc(R.kw("k"), 1));
  assert.equal(s.meta, null, "the original's metadata is untouched");
  assert.equal(R.printStr(a.meta), "{}");
  assert.equal(R.printStr(b.meta), "{:k 1}");
  assert.equal(a.memo, s.memo, "aliases name the same native resource");
  assert.equal(b.memo, s.memo);
  // the clone shares the memo, but is not the same value object
  assert.notEqual(a, s);
});

test("withMeta: a self-cycle through the alias stays terminal cyclic_memo", () => {
  let calls = 0;
  const s = Z.newLazy(() => { calls++; return new R.Cons(1, alias); });
  const alias = Z.withMeta(s, R.EMPTY_MAP);
  assert.throws(() => Z.force(alias), /cyclic_memo/);
  assert.equal(tag(s), "terminal");
  assert.equal(tag(alias), "terminal", "node identity is the shared memo");
  assert.throws(() => Z.force(s), /cyclic_memo/);
  assert.equal(calls, 1, "the terminal verdict is not recomputed");
});

test("withMeta: recursive force across the alias is terminal, no repeat", () => {
  let calls = 0;
  const s = Z.newLazy(() => { calls++; return new R.Cons(1, Z.force(alias)); });
  const alias = Z.withMeta(s, R.EMPTY_MAP);
  assert.throws(() => Z.force(alias), /recursive_force/);
  assert.equal(tag(s), "terminal");
  assert.throws(() => Z.force(s), /recursive_force/);
  assert.equal(calls, 1, "the terminal verdict is not recomputed");
});
