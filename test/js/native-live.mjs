// Invoked by js_native_live_test.bl against its freshly built language.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [out, root] = process.argv.slice(2);
const { start } = await import(pathToFileURL(path.join(out, 'repl.mjs')));
const vm = await start(f => fs.readFileSync(path.join(root, f), 'utf8'));
const run = source => vm.evalString(source);
run('(ns ^:js live.native)');
assert.equal(run('(js/Math.max 3 8)'), 8);
assert.equal(run('(let [f js/Math.sin] (f 0))'), 0);
assert.equal(run('(let [x #js {:n 3}] (set! (.-n x) 4) (.-n x))'), 4);
assert.equal(run('(let [x #js [1]] (aset x 0 9) (aget x 0))'), 9);
assert.equal(run('(.-length (bl->js [1 2 3]))'), 3);
assert.equal(run('(let [convert bl->js] (.-length (convert [1 2 3])))'), 3);
assert.equal(run('(float? (let [convert bl->js] (convert 1.5)))'), true);
assert.equal(run('(:n (js->bl #js {:n 7} :keywordize-keys true))'), 7);
assert.equal(run('(js/undefined? js/undefined)'), true);
assert.throws(() => run('(js/JSON.stringify {:n 7})'), /missing #js|bl->js/);
assert.throws(() => run('(let [x [1]] (.push x 2))'), /#js|bl->js/);
run('(defn sum [a b] (+ a b)) (defn- secret [] 9)');
const api = vm.require('live.native');
assert.equal(api.sum(2, 3), 5);
assert.equal(api.secret, undefined);
run('(defn sum [a b] (* a b))');
assert.equal(api.sum(2, 3), 6);
// Annotation resets when the namespace is redeclared without it.
run('(ns live.native)');
assert.throws(() => run('#js [1]'), /requires.*\^:js/);
run('(ns ^{:interop :javascript} live.longhand)');
assert.equal(run('(js/Math.max 4 5)'), 5);
// Macro output is checked under its caller, not its defining namespace.
run('(defmacro native-array [] (quote (js/native [1])))');
run('(ns live.consumer)');
assert.throws(() => run('(live.longhand/native-array)'), /requires.*\^:js/);
// Native evaluation order and receiver binding, including computed assignment.
const order = [];
globalThis.nativeOrder = {
  get method() { order.push('method'); return function (x) { assert.equal(this, globalThis.nativeOrder); order.push(x); }; },
  arg() { order.push('argument'); return 'called'; },
  key: { toString() { order.push('key'); return 'x'; } },
  rhs() { order.push('rhs'); return 4; },
};
run('(ns ^:js live.order)');
run('(.method js/nativeOrder (js/nativeOrder.arg))');
assert.deepEqual(order.splice(0), ['method', 'argument', 'called']);
run('(aset js/nativeOrder js/nativeOrder.key (js/nativeOrder.rhs))');
assert.deepEqual(order.splice(0), ['key', 'rhs']);
assert.equal(globalThis.nativeOrder.x, 4);
delete globalThis.nativeOrder;

console.log('native live interop: passed');
