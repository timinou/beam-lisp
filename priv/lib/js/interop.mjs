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
import {createBoundary} from './native-values.mjs';
const boundary = createBoundary(R, (fn, args) => A.invoke(fn, ...args), A.toArray);
export const {argument, result, blToJS, jsToBL, propertyKey, convertToJS, convertToBL} = boundary;

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


/** Release a request's namespace, including its live public export getters. */
export function releaseNamespace(name) {
  dropNamespace(name);
  publicNamespaces.delete(name);
}
