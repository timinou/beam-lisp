import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installNamespace } from '../../priv/lib/js/interop.mjs';
import { ENV, reset } from '../../priv/lib/js/env.mjs';

test('explicit exports resolve through aliases; signatures are snapshotted', () => {
  reset();
  const spec = { fn: x => x + 1, arities: [1] };
  const ns = installNamespace('browser.clock', { tick: spec });
  spec.fn = () => 99; spec.arities.push(0);
  ENV.add_alias('user', 'clock', ns.name);
  const tick = ENV['fetch!']('user', 'clock/tick');
  assert.equal(tick(4), 5);
  assert.throws(() => tick(), /wrong number/);
  assert.throws(() => ENV['fetch_exact!'](ns.name, 'globalThis'), /undefined var/);
  ns.dispose(); ns.dispose();
  assert.throws(() => tick(4), /disposed/);
  assert.throws(() => ENV['fetch!']('user', 'clock/tick'), /undefined var/);
});

test('validation is atomic and existing namespaces cannot be overwritten', () => {
  reset();
  assert.throws(() => installNamespace('host.bad', {
    ok: { fn: () => 1, arities: [0] }, bad: { fn: () => 2, arities: [-1] },
  }), /invalid export/);
  assert.equal(ENV['ns_exists?']('host.bad'), false);
  ENV.declare_ns('core');
  assert.throws(() => installNamespace('core', { x: { fn: () => 1, arities: [0] } }), /already exists/);
  assert.throws(() => installNamespace('host/bad', {}), /invalid namespace/);
});

test('disposal preserves independently rebound and added values', () => {
  reset();
  const ns = installNamespace('host.owned', { read: { fn: () => 1, arities: [0] } });
  const captured = ns.bindings.read;
  ENV.intern(ns.name, 'read', 42);
  ENV.intern(ns.name, 'extra', 7);
  ns.dispose();
  assert.equal(ENV['fetch_exact!'](ns.name, 'read'), 42);
  assert.equal(ENV['fetch_exact!'](ns.name, 'extra'), 7);
  assert.throws(captured, /disposed/);
});

import * as R from '../../priv/lib/js/rt.mjs';
import { argument, blToJS, jsToBL, convertToJS, convertToBL, registerPublic, requireNamespace } from '../../priv/lib/js/interop.mjs';

test('explicit conversion preserves exact values and rejects ambiguous data', () => {
  const input = R.hashMap(R.kw('x'), R.vec(1, R.flt(1.5), 9007199254740993n));
  assert.deepEqual(blToJS(input), { x: [1, 1.5, 9007199254740993n] });
  assert.equal(jsToBL({ x: 1 }, R.kw('keywordize-keys'), true).get(R.kw('x')), 1);
  assert.equal(jsToBL(undefined), undefined);
  assert.equal(jsToBL(null), null);
  assert.equal(convertToJS(R.flt(1.5)).v, 1.5);
  assert.throws(() => convertToJS(), /one argument/);
  assert.throws(() => convertToBL({}, true), /one or three/);
  assert.throws(() => blToJS(R.dec(15, 1)), /exact decimal/);
  assert.throws(() => blToJS(R.hashMap(R.kw('x'), 1, 'x', 2)), /duplicate/);
  const cyclic = {}; cyclic.self = cyclic;
  assert.throws(() => jsToBL(cyclic), /cyclic/);
  const foreign = new Date(); assert.equal(jsToBL(foreign), foreign);
});

test('callback adapters preserve identity and numeric calling conventions', () => {
  const callback = x => { assert.ok(x instanceof R.Flt); return R.flt(x.v + .25); };
  assert.equal(argument(callback), argument(callback));
  assert.equal(argument(callback)(1.5), 1.75);
  const target = new EventTarget(); let count = 0;
  const listener = () => ++count;
  target.addEventListener('tick', argument(listener));
  target.dispatchEvent(new Event('tick'));
  target.removeEventListener('tick', argument(listener));
  target.dispatchEvent(new Event('tick'));
  assert.equal(count, 1);
});

test('public bridge uses original names, adapts data and follows live accessors', () => {
  let value = (x, y) => x + y;
  registerPublic('bridge.test', { 'add-values': () => value });
  const api = requireNamespace('bridge.test');
  assert.deepEqual(Object.keys(api), ['add-values']);
  assert.equal(api['add-values'](2, 3), 5);
  value = (x, y) => x * y;
  assert.equal(api['add-values'](2, 3), 6);
});

import { result, propertyKey } from '../../priv/lib/js/interop.mjs';
test('first-class native functions adapt BL numbers and preserve round-trip identity', () => {
  const sin = result(Math.sin);
  assert.equal(sin, result(Math.sin));
  assert.equal(argument(sin), Math.sin);
  assert.equal(sin(R.flt(.5)).v, Math.sin(.5));
});

test('native boundaries reject unconverted collections and preserve symbol property keys', () => {
  assert.throws(() => argument(R.vec(1)), /#js or bl->js/);
  assert.throws(() => argument(R.hashMap('x', 1)), /#js or bl->js/);
  assert.deepEqual(argument(blToJS(R.vec(1))), [1]);
  const key = Symbol('native');
  assert.equal(propertyKey(key), key);
});

test('the shared runtime OS environment seam is explicitly unavailable in JS', () => {
  assert.throws(() => ENV.os_env_call(R.kw('get_env'), R.list('HOME')), /System\/get_env is unavailable/);
});
