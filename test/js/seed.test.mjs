// Seeded first-class values stay raw; direct-call adapters are shared by value.
// The adapter interface is the host ABI's (priv/lib/js/abi.mjs): a `{:$blfn …}`
// value is dispatched by the ABI itself; every OTHER callee is the compiled
// runtime's one calling rule, reached through the bound runtime seam.
// Run: node --test test/js/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import * as R from "../../priv/lib/js/rt.mjs";
import * as A from "../../priv/lib/js/abi.mjs";
import { ENV, reset } from "../../priv/lib/js/env.mjs";

const multi = (fixed, variadic = null) => R.tup([R.kw("$blfn"), fixed, variadic]);
const fixed = R.EMPTY_MAP.assoc(1, (x) => x + 1).assoc(2, (x, y) => x + y);

test("a raw multi-fn has one shared adapter, not one wrapper per module", () => {
  const raw = multi(fixed);
  const a = A.blfnFn(raw), b = A.blfnFn(raw);
  assert.strictEqual(a, b);
  assert.notStrictEqual(a, raw);
  assert.equal(typeof raw, "object", "first-class value is the BEAM-shaped tuple");
  assert.equal(a(4), 5);
  assert.equal(a(4, 5), 9);
  assert.throws(() => a(), /wrong number of args/);
  assert.throws(() => a(1, 2, 3), /wrong number of args/);
});

test("adapter fixed arities win and variadic rest is one proper list", () => {
  const raw = multi(fixed, R.tup([2, (x, y, rest) => R.tup([x, y, rest])]));
  const call = A.blfnFn(raw);
  assert.equal(call(3, 4), 7);
  const value = call(3, 4, 5, 6);
  assert.deepEqual(value.items.slice(0, 2), [3, 4]);
  assert.equal(value.items[2].n, 2);
  assert.equal(R.printStr(value.items[2]), "(5 6)");
  assert.equal(R.keyEq(A.invoke(raw, 3, 4, 5, 6), value), true);
  // the list spelling is the same call, no second dispatch
  assert.equal(R.keyEq(A.invokeList(raw, R.list(3, 4, 5, 6)), value), true);
});

test("non-fn callables delegate to the bound compiled runtime (one rule)", () => {
  // A real-shaped captured helper: the compiled runtime's own entry point
  // (`d_call_invoke(f, argsList)`), bound exactly as registerNamespace('rt')
  // binds it. This pins the DELEGATION, not a ported dispatcher.
  const seen = [];
  A.bindRuntime({ d_call_invoke: (f, args) => { seen.push([f, args]); return 42; } });
  try {
    const keyword = R.kw("seed-test");
    // adapter identity by RAW value, shared across every module that asks
    assert.strictEqual(A.blfnFn(keyword), A.blfnFn(keyword));
    assert.equal(A.blfnFn(keyword)(R.EMPTY_MAP), 42);
    assert.equal(seen.length, 1);
    assert.strictEqual(seen[0][0], keyword, "the callee is passed unchanged");
    assert.equal(R.printStr(seen[0][1]), "({})", "the arguments arrive as ONE BL list");
    // a plain function is called directly and never reaches the bridge
    const fn = (x) => x;
    assert.strictEqual(A.blfnFn(fn), fn);
    assert.equal(A.blfnFn(fn)(7), 7);
    assert.equal(seen.length, 1);
  } finally {
    A.bindRuntime(null);
  }
});

test("live seed lookup sees a rebind without changing captured values", () => {
  reset();
  try {
    const old = multi(fixed);
    ENV.intern("core", "seed-test", old);
    const capture = ENV["fetch!"]("core", "seed-test");
    const adaptedCapture = A.blfnFn(capture);
    assert.strictEqual(ENV["fetch!"]("core", "seed-test"), capture);
    const replacement = multi(R.EMPTY_MAP.assoc(1, (x) => x + 100));
    ENV.intern("core", "seed-test", replacement);
    assert.strictEqual(ENV["fetch!"]("core", "seed-test"), replacement);
    assert.notStrictEqual(A.blfnFn(replacement), adaptedCapture);
    assert.equal(A.blfnFn(replacement)(5), 105);
    assert.equal(adaptedCapture(5), 6);
    assert.equal(A.invoke(capture, 5), 6);
    ENV.intern("core", "seed-test", old);
    assert.strictEqual(A.blfnFn(ENV["fetch!"]("core", "seed-test")), adaptedCapture);
    ENV.delete_key(R.tup(["core", "seed-test"]));
    assert.throws(() => ENV["fetch!"]("core", "seed-test"), /undefined var/);
  } finally {
    reset();
  }
});
