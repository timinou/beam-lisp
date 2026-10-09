// Native JavaScript values, public BL APIs and optional owned host namespaces.
// This is an API/lifetime boundary, not a sandbox for untrusted JavaScript.
import * as R from './rt.mjs';
import { ENV, lookup, deleteKey, dropNamespace } from './env.mjs';

const row = (...xs) => new R.Tup(xs);
const exists = key => lookup(key) instanceof R.Tup;
const identifier = /^[A-Za-z_][A-Za-z0-9_.!?*+<>=-]*$/;

/** Install a fresh namespace from an explicit name -> {fn, arities} manifest.
 * Values cross unchanged: adapters own conversion and resource limits.
 * dispose() revokes captured functions too; it removes only owned rows.
 */
export function installNamespace(name, exports) {
  if (typeof name !== 'string' || !identifier.test(name))
    throw new TypeError('interop: invalid namespace');
  if (ENV['ns_exists?'](name)) throw new Error(`interop: namespace already exists: ${name}`);
  if (!exports || Object.getPrototypeOf(exports) !== Object.prototype)
    throw new TypeError('interop: exports must be a plain manifest');
  const entries = Object.entries(exports);
  if (!entries.length) throw new TypeError('interop: empty manifest');
  // Validate everything before mutating the registry.
  for (const [key, spec] of entries) {
    if (!identifier.test(key) || key.includes('.') || !spec || typeof spec.fn !== 'function' ||
        !Array.isArray(spec.arities) || !spec.arities.length ||
        spec.arities.some(n => !Number.isSafeInteger(n) || n < 0))
      throw new TypeError(`interop: invalid export: ${name}/${key}`);
    if (exists(row(name, key))) throw new Error(`interop: binding already exists: ${name}/${key}`);
  }
  let active = true;
  const bindings = Object.create(null);
  for (const [key, spec] of entries) {
    const fn = spec.fn, arities = new Set(spec.arities);
    bindings[key] = (...args) => {
      if (!active) throw new Error(`interop: namespace disposed: ${name}`);
      if (!arities.has(args.length)) throw new Error(`interop: wrong number of args: ${name}/${key}: ${args.length}`);
      return fn(...args);
    };
  }
  ENV.declare_ns(name);
  for (const [key, fn] of Object.entries(bindings)) ENV.intern(name, key, fn);
  return Object.freeze({
    name, bindings: Object.freeze(bindings),
    dispose() {
      if (!active) return;
      active = false;
      for (const [key, fn] of Object.entries(bindings)) {
        const current = lookup(row(name, key));
        if (current instanceof R.Tup && current.items[1] === fn) deleteKey(row(name, key));
      }
      // Keep the declaration: aliases and independently added vars may still
      // refer to it. Reinstallation requires a fresh namespace name.
    },
  });
}

// Native calls convert numeric boxes and callable ABI tuples, not collections.
import * as A from './abi.mjs';
const callbacks = new WeakMap();
const nativeFunctions = new WeakMap();
const nativeOriginals = new WeakMap();
export function argument(value) {
  if (typeof value === 'function' && nativeOriginals.has(value)) return nativeOriginals.get(value);
  if (value instanceof R.Flt) return value.v;
  if (value instanceof R.Vec || value instanceof R.HMap || value instanceof R.HSet || value instanceof R.Lazy || value instanceof R.Cons || value === R.EMPTY)
    throw new TypeError('JS interop: BL collection needs #js or bl->js');
  if (value instanceof R.Dec) throw new TypeError('JS interop: decimal needs explicit conversion');
  const callable = typeof value === 'function' ||
    (value instanceof R.Tup && value.items[0] === R.kw('$blfn'));
  if (callable) {
    if (!callbacks.has(value)) callbacks.set(value, function (...args) {
      return argument(A.invoke(value, ...args.map(result)));
    });
    return callbacks.get(value);
  }
  return value;
}
export function result(value) {
  if (typeof value === 'function' && nativeOriginals.has(value)) return value;
  if (typeof value === 'function') {
    if (!nativeFunctions.has(value)) {
      const wrapped = (...args) => result(Reflect.apply(value, undefined, args.map(argument)));
      nativeFunctions.set(value, wrapped);
      nativeOriginals.set(wrapped, value);
    }
    return nativeFunctions.get(value);
  }
  return typeof value === 'number' && !Number.isSafeInteger(value) ? R.flt(value) : value;
}

export function blToJS(value) {
  const seen = new WeakSet();
  function convert(x) {
    if (x === null || x === undefined || typeof x === 'string' || typeof x === 'boolean' ||
        typeof x === 'number' || typeof x === 'bigint' || typeof x === 'symbol') return x;
    if (x instanceof R.Flt) return x.v;
    if (x instanceof R.Dec) throw new TypeError('bl->js: exact decimal needs explicit conversion');
    if (x instanceof R.Kw) return x.fq;
    if (typeof x === 'function') return argument(x);
    if (seen.has(x)) throw new TypeError('bl->js: cyclic value');
    seen.add(x);
    try {
      if (x instanceof R.Vec) return x.toArray().map(convert);
      if (x === R.EMPTY || x instanceof R.Cons) return A.toArray(x).map(convert);
      if (x instanceof R.HMap) {
        const out = {};
        for (const [key, v] of x.entries()) {
          const k = key instanceof R.Kw ? key.fq : key;
          if (typeof k !== 'string') throw new TypeError('bl->js: object keys must be keywords or strings');
          if (Object.hasOwn(out, k)) throw new TypeError('bl->js: duplicate object property: ' + k);
          Object.defineProperty(out, k, { value: convert(v), enumerable: true, writable: true, configurable: true });
        }
        return out;
      }
      if (x instanceof R.Lazy) throw new TypeError('bl->js: realize lazy sequences explicitly');
      if (x instanceof R.HSet) throw new TypeError('bl->js: set conversion is not implicit');
      if (x instanceof R.Tup) {
        if (x.items[0] === R.kw('$blfn')) return argument(x);
        throw new TypeError('bl->js: symbols and tuples need explicit conversion');
      }
      // Foreign objects are opaque and retain identity.
      return x;
    } finally { seen.delete(x); }
  }
  return convert(value);
}

export function jsToBL(value, option, enabled) {
  if (option !== undefined && (option !== R.kw('keywordize-keys') || typeof enabled !== 'boolean'))
    throw new TypeError('js->bl: expected :keywordize-keys boolean');
  const seen = new WeakSet();
  function convert(x) {
    if (x === null || typeof x !== 'object') return result(x);
    if (x instanceof R.Flt || x instanceof R.Dec || x instanceof R.Kw || x instanceof R.Vec ||
        x instanceof R.HMap || x instanceof R.HSet || x instanceof R.Tup || x instanceof R.Cons || x === R.EMPTY) return x;
    if (!Array.isArray(x) && Object.getPrototypeOf(x) !== Object.prototype && Object.getPrototypeOf(x) !== null) return x;
    if (seen.has(x)) throw new TypeError('js->bl: cyclic value');
    seen.add(x);
    try {
      if (Array.isArray(x)) return R.vecFromArray(Array.from(x, convert));
      let out = R.EMPTY_MAP;
      for (const [key, v] of Object.entries(x)) out = out.assoc(enabled ? R.kw(key) : key, convert(v));
      return out;
    } finally { seen.delete(x); }
  }
  return convert(value);
}

const publicNamespaces = new Map();
export function registerPublic(name, accessors) {
  publicNamespaces.set(name, Object.freeze({ ...accessors }));
}
/** Original BL names, adapted through the existing callable ABI. */
export function requireNamespace(name) {
  const accessors = publicNamespaces.get(name);
  if (!accessors) throw new Error('no public JS interface: ' + name);
  const out = Object.create(null);
  for (const [key, read] of Object.entries(accessors)) {
    Object.defineProperty(out, key, { enumerable: true, get() {
      const value = read();
      return typeof value === 'function' || (value instanceof R.Tup && value.items[0] === R.kw('$blfn'))
        ? (...args) => blToJS(A.invoke(value, ...args.map(x => jsToBL(x))))
        : blToJS(value);
    } });
  }
  return Object.freeze(out);
}
export function publishLive(name, key, privateVar = false) {
  const accessors = { ...publicNamespaces.get(name) };
  if (privateVar) delete accessors[key];
  else accessors[key] = () => ENV['fetch_exact!'](name, key);
  registerPublic(name, accessors);
}

// Force native ToPropertyKey before an assignment's right-hand side executes.
export function propertyKey(value) {
  return Reflect.ownKeys({ [argument(value)]: null })[0];
}

// First-class BL conversion entry: keep numeric boxing identical to direct syntax.
export function convertToJS(value) {
  if (arguments.length !== 1) throw new TypeError('bl->js expects one argument');
  return result(blToJS(value));
}
export function convertToBL(...args) {
  if (args.length !== 1 && args.length !== 3) throw new TypeError('js->bl expects one or three arguments');
  return jsToBL(...args);
}

/** Release a request's namespace, including its live public export getters. */
export function releaseNamespace(name) {
  dropNamespace(name);
  publicNamespaces.delete(name);
}
