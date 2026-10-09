// One native-value boundary for compiled BL and actor entrypoints. Only callable
// dispatch is supplied by the execution engine; conversion semantics live here.
export function createBoundary(R, invoke, toArray, assertCallback = () => {}) {
  const callbacks = new WeakMap();
  const nativeFunctions = new WeakMap();
  const nativeOriginals = new WeakMap();
  function argument(value) {
    if (typeof value === 'function' && nativeOriginals.has(value)) return nativeOriginals.get(value);
    if (value instanceof R.Flt) return value.v;
    if (value instanceof R.Vec || value instanceof R.HMap || value instanceof R.HSet || value instanceof R.Lazy || value instanceof R.Cons || value === R.EMPTY)
      throw new TypeError('JS interop: BL collection needs #js or bl->js');
    if (value instanceof R.Dec) throw new TypeError('JS interop: decimal needs explicit conversion');
    const callable = typeof value === 'function' ||
      (value instanceof R.Tup && value.items[0] === R.kw('$blfn'));
    if (callable) {
      assertCallback(value);
      if (!callbacks.has(value)) callbacks.set(value, function (...args) {
        return argument(invoke(value, args.map(result)));
      });
      return callbacks.get(value);
    }
    return value;
  }
  function result(value) {
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

  function blToJS(value) {
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
        if (x === R.EMPTY || x instanceof R.Cons) return toArray(x).map(convert);
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

  function jsToBL(value, option, enabled) {
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

  // Force native ToPropertyKey before an assignment's right-hand side executes.
  function propertyKey(value) {
    return Reflect.ownKeys({ [argument(value)]: null })[0];
  }

  // First-class BL conversion entry: keep numeric boxing identical to direct syntax.
  function convertToJS(value) {
    if (arguments.length !== 1) throw new TypeError('bl->js expects one argument');
    return result(blToJS(value));
  }
  function convertToBL(...args) {
    if (args.length !== 1 && args.length !== 3) throw new TypeError('js->bl expects one or three arguments');
    return jsToBL(...args);
  }

  return Object.freeze({argument, result, blToJS, jsToBL, propertyKey, convertToJS, convertToBL});
}
