// ─────────────────────────────────────────────────────────────────────────────
// host.mjs — the irreducible JavaScript host for the beam-lisp ANF→JS
// prototype in research/js-actors.
//
// OWNERSHIP SPLIT (the point of the prototype; see README.md):
//
//   THIS FILE owns exactly four things, none of which is actor policy:
//     1. the value representation (keyword / list / tuple / vector / map /
//        record) and leaf operations over it,
//     2. the machine that drives compiled BL generators — the control ABI
//        (call / tail / park / host-wait) and its frame stack,
//     3. the registry of compiled BL globals (`ref` / `def` / `alias`),
//     4. the bridge to host tasks: a monotonic clock and `setTimeout`.
//
//   BLOWNN BY BL (runtime.bl, compiled by compiler.bl, in the same emitter):
//     every list/vector/map semantic above the leaf ops, the process
//     registry, the runnable queue, mailbox scanning, receive selection,
//     receive cursors, deadlines, wait registration and wakeups.
//
// There is no ANF interpreter here and no re-parser: the only thing this file
// "runs" is a JavaScript generator the compiler emitted.
//
// Browser-compatible: the only host APIs used are `performance.now` (with a
// `Date.now` fallback) and `setTimeout`. Nothing Node-specific is required to
// run; only the optional exit-code reporting touches `process`.
// ─────────────────────────────────────────────────────────────────────────────

// ── values ───────────────────────────────────────────────────────────────────

/** A keyword. Interned so identity and equality agree for the same name. */
export class KW {
  constructor(n) { this.n = n; }
  toString() { return ":" + this.n; }
}

const kwCache = new Map();
export function kw(n) {
  let k = kwCache.get(n);
  if (k === undefined) { k = new KW(n); kwCache.set(n, k); }
  return k;
}
export function isKw(x) { return x instanceof KW; }
export function kwName(x) { return x.n; }

/** A cons cell. A beam-lisp list is a chain of these ending in ENIL. */
export class Cons {
  constructor(h, t) { this.h = h; this.t = t; }
}
/** The empty list — distinct from `nil`, which is `null`. */
export const ENIL = Object.freeze({ __enil: true });
export function isEnil(x) { return x === ENIL; }
export function isCons(x) { return x instanceof Cons; }
export function cons(h, t) { return new Cons(h, t); }
export function consHead(x) { return x.h; }
export function consTail(x) { return x.t; }
export function isList(x) {
  let p = x;
  while (p instanceof Cons) p = p.t;
  return p === ENIL;
}
export function listFromArray(a) {
  let l = ENIL;
  for (let i = a.length - 1; i >= 0; i--) l = new Cons(a[i], l);
  return l;
}
export function listToArray(l) {
  const out = [];
  let p = l;
  while (p instanceof Cons) { out.push(p.h); p = p.t; }
  if (p !== ENIL) throw new Error("not a proper list");
  return out;
}

/** A data tuple (Erlang tuple). */
export class T {
  constructor(items) { this.items = items; }
}
export function tup(items) { return new T(items); }
export function isTup(x) { return x instanceof T; }
export function tupEl(x, i) { return x.items[i]; }
export function tupSize(x) { return x.items.length; }

/** A record / struct: `%Mod{...}` and, notably, a beam-lisp Vector. */
export function struct(mod, fields) {
  const o = { __struct: mod };
  for (const k of Object.keys(fields)) o[k] = fields[k];
  return o;
}
export function isStruct(x) { return !!x && typeof x === "object" && typeof x.__struct === "string"; }
export function structMod(x) { return x.__struct; }
export function structField(x, name) { return x[name]; }

export const VECTOR_MOD = "Elixir.BeamLisp.Vector";
export function isVec(x) { return isStruct(x) && x.__struct === VECTOR_MOD; }
export function vecFromArray(items) { return struct(VECTOR_MOD, { items: new T(items) }); }
export function vec(items) { return vecFromArray(items); }
export function vecItems(x) { return x.items.items; }
export function vecSize(x) { return x.items.items.length; }
export function vecEl(x, i) { return x.items.items[i]; }
export function vecAppend(v, x) { return vecFromArray(vecItems(v).concat([x])); }
export function vecRemove(v, i) { return vecFromArray(vecItems(v).filter((_, k) => k !== i)); }
export function vecToList(v) { return listFromArray(vecItems(v)); }
export function vecFromList(l) { return vecFromArray(listToArray(l)); }

export const SET_MOD = "Elixir.BeamLisp.Set";
export function isSet(x) { return isStruct(x) && x.__struct === SET_MOD; }

/** A beam-lisp map. Keys are canonical strings so structural equality is a
 *  string compare, exactly as `RT.hash_key/1` makes BEAM map keys canonical. */
export class BMap {
  constructor(m) { this.m = m; }
}
export function bmap(pairs) {
  const m = new Map();
  for (const p of pairs) m.set(hashKey(p[0]), p);
  return new BMap(m);
}
export function isBMap(x) { return x instanceof BMap; }
export function isMap(x) { return isBMap(x); }
export function mapHas(m, k) { return m instanceof BMap && m.m.has(hashKey(k)); }
export function mapGet(m, k, dflt) {
  if (m === null || m === undefined) return dflt === undefined ? null : dflt;
  if (m instanceof BMap) {
    const e = m.m.get(hashKey(k));
    return e === undefined ? (dflt === undefined ? null : dflt) : e[1];
  }
  if (isStruct(m)) { const v = m[kwName(k)]; return v === undefined ? (dflt === undefined ? null : dflt) : v; }
  return dflt === undefined ? null : dflt;
}
export function mapPut(m, k, v) {
  const out = m instanceof BMap ? new BMap(new Map(m.m)) : new BMap(new Map());
  out.m.set(hashKey(k), [k, v]);
  return out;
}
export function mapKeys(m) { return listFromArray(m instanceof BMap ? [...m.m.values()].map(p => p[0]) : []); }
export function mapRemove(m, k) {
  const out = m instanceof BMap ? new BMap(new Map(m.m)) : new BMap(new Map());
  out.m.delete(hashKey(k));
  return out;
}
export function emptyMap() { return new BMap(new Map()); }
export function mapSize(m) { return m instanceof BMap ? m.m.size : 0; }

// ── leaf predicates / conversions ────────────────────────────────────────────

export function isNil(x) { return x === null || x === undefined; }
export function isInt(x) { return typeof x === "number" && Number.isInteger(x); }
export function isFloat(x) { return typeof x === "number" && !Number.isInteger(x); }
export function isNum(x) { return typeof x === "number"; }
export function isStr(x) { return typeof x === "string"; }
export function isBool(x) { return x === true || x === false; }
export function isFn(x) { return !!x && x.__blfn === true; }
export function identical(a, b) { return a === b; }
export function truthy(x) { return x !== null && x !== undefined && x !== false; }

/** Canonical structural key. Equality for every data value is this compare;
 *  functions and host handles compare by identity.
 *
 *  The encoding is INJECTIVE, so distinct values never share a key: every
 *  string / keyword leaf is length-prefixed (`s3:abc`, `k3:abc`) and every
 *  composite carries its child count plus each child's length, so `[:x :y]`
 *  and `[(keyword "x,k:y")]` — equal under a naive `join(",")` — stay apart. */
function enc(tag, kids) {
  let out = tag + kids.length + "[";
  for (const k of kids) out += k.length + ":" + k;
  return out + "]";
}
export function hashKey(x) {
  if (x === null || x === undefined) return "nil";
  if (x === true) return "b:1";
  if (x === false) return "b:0";
  const t = typeof x;
  if (t === "number") return "n:" + (Object.is(x, -0) ? 0 : x);
  if (t === "string") return "s" + x.length + ":" + x;
  if (x instanceof KW) return "k" + x.n.length + ":" + x.n;
  if (x === ENIL) return "l:()";
  if (x instanceof Cons) return enc("l", [hashKey(x.h), hashKey(x.t)]);
  if (x instanceof T) return enc("t", x.items.map(hashKey));
  if (isStruct(x)) {
    if (isVec(x)) return enc("v", vecItems(x).map(hashKey));
    const keys = Object.keys(x).filter(k => k !== "__struct").sort();
    return enc("r", [x.__struct].concat(keys.flatMap(k => [k, hashKey(x[k])])));
  }
  if (x instanceof BMap) {
    const keys = [...x.m.keys()].sort();
    return enc("m", keys.flatMap(k => [k, hashKey(x.m.get(k)[1])]));
  }
  if (typeof x === "function" || x.__blfn) return "f:" + (x.__id ||= ++idCounter);
  return "o:" + (x.__id ||= ++idCounter);
}
let idCounter = 0;

export function eq(a, b) {
  if (a === b) return true;
  if (a === null || a === undefined || b === null || b === undefined) return a === b;
  return hashKey(a) === hashKey(b);
}

export function lt(a, b) {
  if (typeof a === "number" && typeof b === "number") return a < b;
  if (typeof a === "string" && typeof b === "string") return a < b;
  throw new Error("`<` needs two numbers or two strings, got " + describe(a) + " and " + describe(b));
}

export function describe(x) {
  if (x === null || x === undefined) return "nil";
  if (x instanceof KW) return ":" + x.n;
  if (x instanceof Cons || x === ENIL) { try { return "(" + listToArray(x).map(describe).join(" ") + ")"; } catch (_) { return "(improper list)"; } }
  if (x instanceof T) return "{" + x.items.map(describe).join(", ") + "}";
  if (isVec(x)) return "[" + vecItems(x).map(describe).join(" ") + "]";
  if (isStruct(x)) return "#" + x.__struct + "{}";
  if (x instanceof BMap) return "{" + mapKeys(x).map(k => describe(k) + " " + describe(mapGet(x, k))).join(", ") + "}";
  if (typeof x === "string") return JSON.stringify(x);
  if (typeof x === "function") return "#<fn>";
  if (isFn(x)) return "#<fn " + x.name + ">";
  return String(x);
}

export function toStr(x) {
  // BL's `str` is the printer WITHOUT readable quoting: a keyword contributes
  // its bare name (`(str :b)` is "b" on this host), a string contributes its
  // characters. `describe` is the readable form, used for diagnostics only.
  if (typeof x === "string") return x;
  if (x === null || x === undefined) return "nil";
  if (x === true) return "true";
  if (x === false) return "false";
  if (x instanceof KW) return x.n;
  if (typeof x === "number") return String(x);
  return describe(x);
}

// ── arithmetic ───────────────────────────────────────────────────────────────

export function arith(op, a, b) {
  switch (op) {
    // Integers are carried as EXACT SAFE INTEGERS: when both operands are
    // integers, both inputs and the result must fit in ±(2^53-1), otherwise we
    // raise instead of silently losing precision. Floats are a documented
    // SUBSET: if either operand is a float the operation is IEEE-754 double
    // arithmetic (the receive deadline clock is a float, so this path is
    // load-bearing) and no overflow check is applied.
    case "add": case "sub": case "mul": {
      if (typeof a !== "number" || typeof b !== "number")
        throw new Error("[" + op + "] needs two numbers, got " + describe(a) + " and " + describe(b));
      if (Number.isInteger(a) && Number.isInteger(b)) {
        if (!Number.isSafeInteger(a) || !Number.isSafeInteger(b))
          throw new Error("integer out of safe range in [" + op + "]");
        const r = op === "add" ? a + b : op === "sub" ? a - b : a * b;
        if (!Number.isSafeInteger(r)) throw new Error("integer overflow in [" + op + "]");
        return r;
      }
      return op === "add" ? a + b : op === "sub" ? a - b : a * b;
    }
    case "div": {
      if (typeof a !== "number" || typeof b !== "number")
        throw new Error("[div] needs two numbers, got " + describe(a) + " and " + describe(b));
      if (b === 0) throw new Error("divide by zero");
      const q = a / b;
      if (Number.isInteger(q) && Number.isInteger(a) && Number.isInteger(b) && !Number.isSafeInteger(q))
        throw new Error("integer overflow in [div]");
      return q;
    }
    case "rem": {
      if (typeof a !== "number" || typeof b !== "number")
        throw new Error("[rem] needs two numbers, got " + describe(a) + " and " + describe(b));
      if (b === 0) throw new Error("rem by zero");
      if (Number.isInteger(a) && Number.isInteger(b)) {
        if (!Number.isSafeInteger(a) || !Number.isSafeInteger(b))
          throw new Error("integer out of safe range in [rem]");
        const r = a % b;
        if (!Number.isSafeInteger(r)) throw new Error("integer overflow in [rem]");
        return r;
      }
      return a % b;
    }
    case "lt": return lt(a, b);
    case "gt": return lt(b, a);
    case "le": return !lt(b, a);
    case "ge": return !lt(a, b);
    case "num_eq": return eq(a, b);
    default: throw new Error("unknown arithmetic op " + op);
  }
}

// ── control steps ────────────────────────────────────────────────────────────
//
// A step is a HOST object, never a BL value: a BL map is a `BMap`, a BL tuple
// is a `T`, a record is a `{__struct}`. A user value that "looks like" a step
// therefore stays data, as the design requires.

export class Step {
  constructor(k, extra) { this.__step = true; this.k = k; if (extra) Object.assign(this, extra); }
}
export function isStep(x) { return !!x && x.__step === true; }

// ── the machine ──────────────────────────────────────────────────────────────

/** Resolve a callee to a generator factory, or null when it is a native fn. */
export function resolveCallee(f, args) {
  const arity = args.length;
  if (f && f.__blfn === true) {
    const a = f.arities.get(arity);
    if (a) return a;
    if (f.variadic) {
      const [min, fn] = f.variadic;
      if (arity >= min) {
        return (rt, as) => fn(rt, as.slice(0, min).concat([listFromArray(as.slice(min))]));
      }
    }
    throw new Error("no arity " + arity + " on fn " + (f.name || "?"));
  }
  if (isTup(f) && f.items.length === 3 && isKw(f.items[0]) && f.items[0].n === "$blfn") {
    const fixed = f.items[1]; // a BL map arity → fn
    const hit = mapGet(fixed, arity);
    if (hit !== null && hit !== undefined) return resolveCallee(hit, args);
    const variadic = f.items[2];
    if (isTup(variadic)) {
      const min = tupEl(variadic, 0);
      const fn = tupEl(variadic, 1);
      if (arity >= min) {
        return (rt, as) => {
          const packed = as.slice(0, min).concat([listFromArray(as.slice(min))]);
          return resolveCallee(fn, packed)(rt, packed);
        };
      }
    }
    throw new Error("no arity " + arity + " on $blfn");
  }
  return null;
}

export function invokeNative(rt, f, args) {
  if (f === null || f === undefined) throw new Error("cannot call nil");
  if (f instanceof KW) {
    if (args.length === 1) return mapGet(args[0], f);
    if (args.length === 2) return mapGet(args[0], f, args[1]);
    throw new Error("keyword call takes 1 or 2 arguments");
  }
  if (isVec(f)) return vecEl(f, args[0]);
  if (isBMap(f)) return mapGet(f, args[0], args[1]);
  if (isSet(f)) return mapGet(f, args[0]);
  if (typeof f === "function") return f.apply(null, args);
  throw new Error("cannot call " + describe(f));
}

/** Run one bounded turn of the generator stack `frames`.
 *
 *  Returns a BL map: {:status :done|:park|:yield|:host-wait|:error
 *                     :value v :ms n :message s :frames frames}
 *
 *  The frame array is mutated in place and handed back so a suspended
 *  process is a value the BL scheduler can store in its registry. */
export function runTurn(rt, frames, budget) {
  let steps = 0;
  // The critical depth this turn entered with. A failed turn is unwound to it,
  // so a BL function that raised between critical-enter and critical-leave does
  // not leave the depth positive and defer every future slice forever.
  const cd0 = rt.criticalDepth || 0;
  // The pending resume value is MACHINE STATE, not a local: a slice can end
  // exactly between "a callee finished" and "its caller is resumed", and a
  // value dropped there would silently become nil. It rides on the frame
  // stack (the one object a suspended process already is).
  let sent = frames.__sent === undefined ? null : frames.__sent;
  const finish = (r) => { frames.__sent = sent; return r; };
  const fail = (message) => { rt.criticalDepth = cd0; return finish(mkResult("error", frames, { message })); };
  while (true) {
    if (frames.length > (rt.maxFrames || 0)) rt.maxFrames = frames.length;
    // A bounded slice normally ends here. While a critical section is open the
    // boundary is DEFERRED: splitting a read-modify-write of `rt.state` across
    // a slice would let another process mutate the same root underneath it.
    if (steps >= budget && (rt.criticalDepth || 0) === 0) return finish(mkResult("yield", frames, {}));
    const g = frames[frames.length - 1];
    let res;
    try { res = g.next(sent); }
    catch (e) { steps = 0; return fail(String((e && e.stack) || e)); }
    sent = null;
    steps++;
    if (res.done) {
      frames.pop();
      if (frames.length === 0) return finish(mkResult("done", frames, { value: res.value }));
      sent = res.value;
      continue;
    }
    let step = res.value;
    while (true) {
      if (!isStep(step)) { sent = step; break; }
      if (step.k === "park") return finish(mkResult("park", frames, {}));
      if (step.k === "host-wait") return finish(mkResult("host-wait", frames, { ms: step.ms }));
      if (step.k === "call" || step.k === "tail") {
        let factory = null;
        try { factory = resolveCallee(step.f, step.args); }
        catch (e) { return fail(String((e && e.stack) || e)); }
        if (factory) {
          let ng;
          try { ng = factory(rt, step.args); }
          catch (e) { return fail(String((e && e.stack) || e)); }
          if (step.k === "tail") frames[frames.length - 1] = ng; else frames.push(ng);
          break;
        }
        let v;
        try { v = invokeNative(rt, step.f, step.args); }
        catch (e) { return fail(String((e && e.stack) || e)); }
        steps++;
        if (step.k === "tail") frames.pop();
        if (frames.length === 0) return finish(mkResult("done", frames, { value: isStep(v) ? null : v }));
        if (isStep(v)) { step = v; continue; }
        sent = v;
        break;
      }
      return fail("unknown control step " + step.k);
    }
    if (frames.length === 0) return finish(mkResult("done", frames, { value: sent }));
  }
}

function mkResult(status, frames, extra) {
  return bmap([
    [kw("status"), kw(status)],
    [kw("frames"), frames],
    [kw("value"), extra.value === undefined ? null : extra.value],
    [kw("ms"), extra.ms === undefined ? null : extra.ms],
    [kw("message"), extra.message === undefined ? null : extra.message],
  ]);
}
export function resultStatus(r) { return kwName(mapGet(r, kw("status"))); }
export function resultValue(r) { return mapGet(r, kw("value")); }
export function resultMs(r) { return mapGet(r, kw("ms")); }
export function resultMessage(r) { return mapGet(r, kw("message")); }

// ── runtime + registry ───────────────────────────────────────────────────────

export function newRuntime() {
  return {
    globals: new Map(),
    state: bmap([]),
    self: null,
    // The scheduler's own slice. It is deliberately large: every real yield to
    // the host goes through `host-wait` (a deadline), never through the slice.
    // The slice that matters for FAIRNESS is the per-process one in `rt-run-pid`.
    budget: 100000,
    // A generic critical-section depth. It is MACHINE state, not actor state:
    // BL functions are generators, so a slice can end between the read and the
    // write of a read-modify-write on `rt.state`. While the depth is positive
    // `runTurn` defers the slice boundary, so the RMW completes atomically
    // with respect to other processes. `host/park` is refused inside one.
    criticalDepth: 0,
    // A generic error counter. The BL runtime records a process failure (and
    // a scheduler deadlock) here, and `boot` rejects the run when it is nonzero.
    // No actor policy lives here — it is a count.
    errors: 0,
    // High-water mark of the generator frame stack, for a stack-safety test.
    maxFrames: 0,
    out: (s) => { console.log(s); },
  };
}

export function def(rt, key, v) { rt.globals.set(key, v); return v; }
export function alias(rt, key, target) { return ref(rt, splitNs(target), splitName(target)); }
function splitNs(k) { return k.slice(0, k.lastIndexOf("/")); }
function splitName(k) { return k.slice(k.lastIndexOf("/") + 1); }
export function defAlias(rt, key, targetKey) {
  const v = rt.globals.get(targetKey);
  if (v === undefined) throw new Error("alias target not defined: " + targetKey);
  rt.globals.set(key, v);
  return v;
}

/** Resolve a global, with the same fallback beam-lisp's `Env.fetch!` has:
 *  a name bound in the current namespace, else the same name in `core`. */
export function ref(rt, ns, name) {
  const direct = rt.globals.get(ns + "/" + name);
  if (direct !== undefined) return direct;
  if (ns !== "core") {
    const c = rt.globals.get("core/" + name);
    if (c !== undefined) return c;
  }
  throw new Error("unresolved global " + ns + "/" + name);
}

// ── BL function construction ─────────────────────────────────────────────────

export function blFn(name, arities, variadic) {
  return { __blfn: true, name, arities, variadic: variadic || null };
}

// ── host intrinsics (`host/…` in BL) ─────────────────────────────────────────

export const PURE = {
  kw,
  "kw-name": kwName,
  "is-kw": isKw,
  cons,
  "is-cons": isCons,
  "is-enil": isEnil,
  "cons-head": consHead,
  "cons-tail": consTail,
  "is-list": isList,
  "empty-list": () => ENIL,
  "list->array": listToArray,
  tup,
  "is-tup": isTup,
  "tup-el": tupEl,
  "tup-size": tupSize,
  struct,
  "is-struct": isStruct,
  "struct-mod": structMod,
  "struct-field": structField,
  "is-vec": isVec,
  "vec-size": vecSize,
  "vec-el": vecEl,
  "vec-append": vecAppend,
  "vec-remove": vecRemove,
  "vec-to-list": vecToList,
  "vec-from-list": vecFromList,
  "is-set": isSet,
  bmap,
  "empty-map": emptyMap,
  "is-map": isBMap,
  "map-get": mapGet,
  "map-put": mapPut,
  "map-remove": mapRemove,
  "map-keys": mapKeys,
  "map-size": mapSize,
  eq,
  identical,
  lt,
  "is-nil": isNil,
  "is-int": isInt,
  "is-float": isFloat,
  "is-num": isNum,
  "is-str": isStr,
  "is-bool": isBool,
  "is-fn": isFn,
  "to-str": toStr,
  describe,
  arith,
  "str-cat": (...xs) => xs.map(toStr).join(""),
  "str-size": (s) => s.length,
  truthy,
};

/** Intrinsics that need the runtime: the retained mutable root and the
 *  scheduler bridge. Everything else is `PURE` above.
 *
 *  `critical-enter`/`critical-leave` are the ONE generic machine service the BL
 *  runtime needs to make a read-modify-write on `rt.state` atomic across a
 *  slice boundary. They carry no actor meaning — only a depth counter — and
 *  `runTurn` defers its slice boundary while the depth is positive. */
export const RT_HOST = {
  park: (rt) => {
    if ((rt.criticalDepth || 0) > 0) throw new Error("host/park inside a critical section");
    return new Step("park");
  },
  "park-release": (rt) => {
    if (rt.criticalDepth !== 1) throw new Error("host/park-release requires one critical section");
    rt.criticalDepth = 0;
    return new Step("park");
  },
  "wait-until": (rt, ms) => new Step("host-wait", { ms: ms < 0 ? 0 : ms }),
  now: () => (globalThis.performance && globalThis.performance.now ? globalThis.performance.now() : Date.now()),
  state: (rt) => rt.state,
  "set-state": (rt, s) => { rt.state = s; return s; },
  self: (rt) => rt.self,
  "set-self": (rt, p) => { rt.self = p; return p; },
  "critical-enter": (rt) => { rt.criticalDepth = (rt.criticalDepth || 0) + 1; return rt.criticalDepth; },
  "critical-leave": (rt) => { rt.criticalDepth = Math.max(0, (rt.criticalDepth || 0) - 1); return rt.criticalDepth; },
  "run-turn": (rt, frames, budget) => runTurn(rt, frames, budget),
  "make-frames": (rt, f, args) => { const as = argsArray(args); return [resolveCallee(f, as)(rt, as)]; },
  ref: (rt, ns, name) => ref(rt, ns, name),
  write: (rt, s) => { rt.out(toStr(s)); return null; },
  raise: (rt, msg) => { throw new Error(toStr(msg)); },
  "record-error": (rt, msg) => { rt.errors = (rt.errors || 0) + 1; rt.lastError = toStr(msg); return rt.errors; },
  "max-frames": (rt) => rt.maxFrames || 0,
};

/** The callee a compiled call site uses for a `host/…` intrinsic. Cached per
 *  runtime so the code generator can emit one expression per reference. */
export function hostRef(rt, name) {
  let cache = rt.__hostRefs;
  if (!cache) { cache = new Map(); rt.__hostRefs = cache; }
  let f = cache.get(name);
  if (f === undefined) {
    if (Object.prototype.hasOwnProperty.call(RT_HOST, name)) {
      const impl = RT_HOST[name];
      f = (...args) => impl(rt, ...args);
    } else if (Object.prototype.hasOwnProperty.call(PURE, name)) {
      f = PURE[name];
    } else {
      throw new Error("unknown host intrinsic host/" + name);
    }
    cache.set(name, f);
  }
  return f;
}

/** A BL argument vector/list as a JS array — the one conversion the spawn
 *  bridge needs, since BL code writes arguments as BL data. */
export function argsArray(x) {
  if (Array.isArray(x)) return x;
  if (isVec(x)) return vecItems(x);
  if (isCons(x) || x === ENIL) return listToArray(x);
  if (x === null || x === undefined) return [];
  throw new Error("expected an argument vector or list, got " + describe(x));
}

export function hostNames() { return Object.keys(PURE).concat(Object.keys(RT_HOST)); }

/** Every `erlang/…` bif the backend will emit a call to. */
export function erlangRef(name) {
  const f = ERLANG[name];
  if (f === undefined) throw new Error("unknown erlang bif :erlang/" + name);
  return f;
}

export function erlangNames() { return Object.keys(ERLANG); }

// ── :erlang bif table (`erlang/…` in guards, and any raw bif call) ───────────

export const ERLANG = {
  "==": eq,
  "/=": (a, b) => !eq(a, b),
  "=:=": eq,
  "=/=": (a, b) => !eq(a, b),
  "<": lt,
  ">": (a, b) => lt(b, a),
  "=<": (a, b) => !lt(b, a),
  ">=": (a, b) => !lt(a, b),
  "+": (a, b) => arith("add", a, b),
  "-": (a, b) => arith("sub", a, b),
  "*": (a, b) => arith("mul", a, b),
  "rem": (a, b) => arith("rem", a, b),
  "is_integer": isInt,
  "is_float": isFloat,
  "is_number": isNum,
  "is_binary": isStr,
  "is_tuple": isTup,
  "is_list": isList,
  "is_pid": (x) => typeof x === "number" && x >= 0 && Number.isInteger(x) && false,
  "is_reference": () => false,
  "is_port": () => false,
  "is_atom": (x) => isKw(x) || x === null || x === true || x === false,
  "is_map": isBMap,
  "tuple_size": tupSize,
  "map_size": mapSize,
  "abs": Math.abs,
  "length": (l) => listToArray(l).length,
  "self": () => null,
};

// ── the driver: hand turns to the host task queue between scheduler slices ───

export async function init(rt) {
  const initFn = rt.globals.get("js/__init");
  if (initFn === undefined) return;
  const frames = [resolveCallee(initFn, [])(rt, [])];
  const r = runTurn(rt, frames, 100000000);
  const st = resultStatus(r);
  if (st !== "done") {
    rt.out("js-actors: bundle init failed (" + st + ")"
           + (st === "error" ? ": " + resultMessage(r) : ""));
    if (globalThis.process) globalThis.process.exitCode = 1;
    throw new Error("bundle init failed");
  }
}

/** Hand one turn to the host TASK queue. It MUST be a macrotask (`setTimeout`),
 *  not a microtask: only a macrotask lets timers and I/O run, which is the whole
 *  point of returning from a bounded root slice. */
function yieldToHostTasks() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

export async function boot(rt) {
  const entry = ref(rt, "js", "entry");
  const mainFn = ref(rt, "js", "bl-main");
  const frames = [resolveCallee(mainFn, [entry])(rt, [entry])];
  for (;;) {
    const r = runTurn(rt, frames, rt.budget);
    const st = resultStatus(r);
    if (st === "done") {
      const errors = rt.errors || 0;
      if (errors > 0) {
        rt.out("actor runtime: " + errors + " error(s) recorded; failing boot");
        if (globalThis.process) globalThis.process.exitCode = 1;
        throw new Error("actor runtime recorded " + errors + " error(s)");
      }
      return resultValue(r);
    }
    // The scheduler's own bounded slice ended. Yield to the host TASK queue so
    // timers and I/O run before the next slice: a bare `continue` here would
    // chain microtasks and starve them. `host-wait` (the scheduler asking for a
    // deadline) already sleeps for real.
    if (st === "yield") { await yieldToHostTasks(); continue; }
    if (st === "error") {
      rt.out("actor runtime error: " + resultMessage(r));
      if (globalThis.process) globalThis.process.exitCode = 1;
      throw new Error("actor runtime error: " + resultMessage(r));
    }
    if (st === "host-wait") {
      const ms = resultMs(r);
      await new Promise((resolve) => setTimeout(resolve, ms === null ? 0 : ms));
      continue;
    }
    // A `park` at the scheduler root means the scheduler itself suspended with
    // nothing to resume it: a scheduler bug, not a user program's.
    rt.out("scheduler parked with no resumer");
    if (globalThis.process) globalThis.process.exitCode = 1;
    throw new Error("scheduler parked with no resumer");
  }
}
