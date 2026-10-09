// priv/lib/js/abi.mjs — the IRREDUCIBLE host ABI of the sync JS profile
// (PLAN-163 U3).
//
// This is NOT a renamed copy of the old hand-written core and NOT a port of
// the language's collection, equality, sort or string algorithms. Those live
// once, in Beam Lisp, compiled
// to `ns/*.mjs`. What lives here is only what a compiled BL function cannot
// express over the JS value model (rt.mjs):
//
//   calling    `invoke`/`invokeList` — the BEAM's `Rt.invoke(f, args)`: a plain
//              JS fn is called directly; a `{:$blfn …}` value is a fixed/variadic
//              dispatch; ANY other callee (keyword, map, set, vector, sorted
//              collection, remote handle) goes to the COMPILED runtime's own
//              `call-invoke`, so the callable rule has one implementation.
//   values     `blfnFn` — a `{:$blfn …}` raw seed value as ONE JS function,
//              shared by raw value (identity holds across namespaces); a rebind
//              to a new raw value yields a new adapter, a captured one is
//              untouched.
//   seq        `toArray` — a Vec or a PROPER native Cons chain is walked
//              directly; every other seqable goes through the compiled runtime's
//              `k-to-list`, never a parallel seq semantics.
//   sentinels  `NOT_FOUND` (the compiled map-pattern miss) and `K_error`
//              (the `catch` kind test).
//   host       metadata wrappers (`meta`/`with_meta`/`vary_meta`), atoms and
//              deref/swap!/reset! (watches preserved), and the error primitives
//              (`ex_info`/`ex_message`/`ex_data`/`ex_cause`/`throw_`/
//              `exception_normalize`), plus `type` — the ONE value classifier
//              the language's `Multi/type_of` leaf answers.
//
// THE RUNTIME SEAM. `bindRuntime(rtNamespace)` is called once, by
// leaves.mjs `registerNamespace('rt', …)`, with the compiled rt module's
// exports. After that the general language operations above delegate to it.
// Before it (a bare `leaf-names` import, a unit test) the ABI still answers
// everything a caller does not need the language for; an operation that does
// need it fails loud naming the gap, never with a wrong answer.
//
// This module imports rt.mjs and lazy.mjs ONLY. leaves.mjs and host-leaves.mjs
// import it, so it must never import them (an ES import cycle would leave one
// side uninitialised).

import * as R from "./rt.mjs";
import * as Z from "./lazy.mjs";

// ─── the compiled runtime seam ──────────────────────────────────────────────

let RT = null;

/** Bind the compiled `rt` namespace (the `ns/rt.mjs` exports). Idempotent; a
    later binding replaces an earlier one (a rebuilt runtime). */
export function bindRuntime(ns) { RT = ns; }
/** Is the general language runtime bound yet? */
export function runtimeBound() { return RT !== null; }
function runtime(op) {
  if (RT === null) throw new R.BLError(op + " needs the compiled language runtime (rt is not loaded yet)");
  return RT;
}

// ─── sentinels ──────────────────────────────────────────────────────────────

/** The compiled map-pattern miss (`{:keys [a]}` in a fn head is a pmap: a key
    that is ABSENT fails the clause). One object, so identity comparison works. */
export const NOT_FOUND = { nf: true };
const NF = NOT_FOUND;

/** The `:error` kind `catch` clauses test against. */
export const K_error = R.kw("error");

// ─── calling: the BEAM's Rt.invoke(f, args) ─────────────────────────────────
//
// A `$blfn` multi-fn VALUE is `{:$blfn fixed {min clause} | nil}` where `fixed`
// maps an arity to its fn and the variadic clause takes the fixed args then the
// rest as ONE list (the BEAM ABI). `blfnFn` resolves each fixed arity once so a
// call is a length switch plus a direct call, not a map lookup and two spreads.

const BLFN = R.kw("$blfn");
const isBlfn = (f) => f instanceof R.Tup && f.items.length === 3 && f.items[0] === BLFN;

function invokeBlfn(f, args) {
  const fixed = f.items[1], v = f.items[2];
  const g = fixed instanceof R.HMap ? fixed.get(args.length, NF) : NF;
  if (g !== NF) return invoke(g, ...args);
  if (v instanceof R.Tup) {
    const mn = v.items[0];
    if (args.length >= mn) return invoke(v.items[1], ...args.slice(0, mn), R.listFromArray(args.slice(mn)));
  }
  throw new R.BLError("wrong number of args (" + args.length + ") passed to a multi-arity fn");
}

/** A `{:$blfn …}` multi-fn value as ONE JS function, resolved once and cached
    by the RAW value: every module that calls the same seeded value shares ONE
    JS identity (`identical?` holds across namespaces); a rebind yields a new
    dispatcher while an already-captured one is untouched. Any other value keeps
    `invoke` (the wrapper calls through it, so a rebind stays live). */
const BLFN_CACHE = new WeakMap();
export function blfnFn(f) {
  if (typeof f === "function") return f;
  const key = f !== null && typeof f === "object" ? f : null;
  if (key !== null) { const hit = BLFN_CACHE.get(key); if (hit !== undefined) return hit; }
  let g;
  if (!isBlfn(f)) {
    g = (...a) => invoke(f, ...a);
  } else {
    const fixed = f.items[1];
    const at = (n) => { const h = fixed instanceof R.HMap ? fixed.get(n, NF) : NF; return h === NF ? null : typeof h === "function" ? h : (...a) => invoke(h, ...a); };
    const f1 = at(1), f2 = at(2), f3 = at(3);
    // `(...args)`: length 0, the shape every emitted multi-arity dispatcher has
    // (`is_function/2` reads a 0-length fn as accepting any arity)
    g = function blfn(...args) {
      const n = args.length;
      if (n === 2 && f2 !== null) return f2(args[0], args[1]);
      if (n === 1 && f1 !== null) return f1(args[0]);
      if (n === 3 && f3 !== null) return f3(args[0], args[1], args[2]);
      return invokeBlfn(f, args);
    };
  }
  if (key !== null) BLFN_CACHE.set(key, g);
  return g;
}

function listToArray(l) { const a = []; for (let p = l; p instanceof R.Cons; p = p.t) a.push(p.h); return a; }

/** Call `f` with the argument LIST `args` (the BEAM ABI). A plain fn and a
    `$blfn` are answered here; every other callee is the compiled runtime's
    `call-invoke` — the ONE callable rule (keyword/map/set/vector/sorted/…). */
export function invokeList(f, args) {
  if (typeof f === "function") return f(...listToArray(args));
  if (isBlfn(f)) return blfnFn(f)(...listToArray(args));
  return runtime(R.printStr(f) + " is not a function").d_call_invoke(f, args);
}

/** Call `f` with spread arguments (the host-side spelling of `invokeList`). */
export function invoke(f, ...args) {
  if (typeof f === "function") return f(...args);
  if (isBlfn(f)) return blfnFn(f)(...args);
  return runtime(R.printStr(f) + " is not a function").d_call_invoke(f, R.listFromArray(args));
}

/** `(apply f a b args)`: the trailing seqable's elements appended to the fixed
    args, then `invoke`. */
export function apply(f, ...args) {
  const last = args.pop();
  return invoke(f, ...args, ...toArray(last));
}

// ─── seqs ───────────────────────────────────────────────────────────────────

/** Iterate any seqable to a JS array. A vector and a PROPER native list are
    walked directly (they ARE the storage); every other seqable — a lazy seq, a
    string, a map's entries, a set, a tuple — goes through the compiled
    runtime's `k-to-list`, so there is no second seq semantics here. */
export function toArray(x) {
  if (x instanceof R.Vec) return x.toArray();
  if (x === null || x === undefined || x === R.EMPTY) return [];
  if (x instanceof R.Cons) {
    if (x.n >= 0) { const a = new Array(x.n); let i = 0; for (let p = x; p instanceof R.Cons; p = p.t) a[i++] = p.h; return a; }
  }
  const rt = runtime("toArray(" + R.printStr(x) + ")");
  return listToArray(rt.d_k_to_list(x));
}

// ─── host primitives: metadata, references, errors, type ────────────────────

/** `(meta x)`: the value-owned metadata map, or nil. A collection/fn carries it
    in its own field; a lazy seq in the struct's `:metadata` (the BEAM's one
    identity-bearing metadata). */
export function meta(x) { return x !== null && (typeof x === "object" || typeof x === "function") ? (x.meta ?? null) : null; }

function withMetaColl(x, m) {
  if (x instanceof R.Vec) return new R.Vec(x.cnt, x.shift, x.root, x.tail, m);
  if (x instanceof R.HMap) return new R.HMap(x.cnt, x.root, m);
  if (x instanceof R.HSet) return new R.HSet(x.m, m);
  // a lazy seq: the owning leaf (Z.withMeta) shares the source's native memo
  // RESOURCE, so successful realization, retry and the cycle guard are shared
  // and changing metadata never repeats an effect or forks the node.
  if (x instanceof Z.LazySeq) return Z.withMeta(x, m);
  if (x instanceof R.Cons) { const c = new R.Cons(x.h, x.t); c.meta = m; return c; }
  if (typeof x === "function") { const f = (...a) => x(...a); f.meta = m; return R.inheritCallable(f, x); }
  throw new R.BLError("with-meta: " + R.printStr(x) + " cannot carry metadata");
}
export function with_meta(x, m) { return withMetaColl(x, m); }
export function vary_meta(x, f, ...args) { return withMetaColl(x, invoke(f, meta(x), ...args)); }

/** A reference: an atom (Clojure's, watches included). */
export function atom(v) { return new R.Atom(v); }
/** `(deref x)`: an atom's or volatile's value, or a delay forced. */
export function deref(a) { return a instanceof Z.Delay ? Z.deferredForce(a) : a.v; }
export function reset_BANG(a, v) { const old = a.v; a.v = v; notify(a, old, v); return v; }
export function swap_BANG(a, f, ...args) { const old = a.v; const v = invoke(f, old, ...args); a.v = v; notify(a, old, v); return v; }
export function add_watch(a, k, f) { a.watches = (a.watches || R.EMPTY_MAP).assoc(k, f); return a; }
export function remove_watch(a, k) { if (a.watches) a.watches = a.watches.dissoc(k); return a; }
function notify(a, old, nu) { if (a.watches && old !== nu) for (const [k, f] of a.watches) invoke(f, k, a, old, nu); }

// ─── errors ─────────────────────────────────────────────────────────────────

export function ex_info(msg, data, cause) { return new R.BLError(msg, data === undefined ? R.EMPTY_MAP : data, cause); }
/** BEAM: `(ex-message "plain")` is "\"plain\"" — a non-exception's message is
    its printed form. */
export function ex_message(e) { return e instanceof Error ? e.message : R.printStr(e); }
export function ex_data(e) { return e instanceof R.BLError ? e.data : null; }
export function ex_cause(e) { return e instanceof R.BLError ? e.blCause : null; }
export function throw_(e) {
  if (e instanceof Error) throw e;
  const err = new R.BLError(R.printStr(e), e instanceof R.HMap ? e : null); err.blOriginal = e; throw err;
}
/** The frontend lowers every `catch` through Exception.normalize(kind, value,
    stack) and re-raises a miss with erlang:raise(kind, value, stack). A JS
    throw is already the normalized value; a non-Error is wrapped once so
    ex-message/ex-data see a BLError. */
export function exception_normalize(_kind, v, _stack) {
  if (v instanceof Error) return v;
  const err = new R.BLError(R.printStr(v), v instanceof R.HMap ? v : null); err.blOriginal = v; return err;
}
export function erlang_raise(_kind, v, _stack) { throw v; }

/** `type`, measured against BEAM: nil → nil, a string is :binary, a symbol (a
    {:symbol name} tuple) is :tuple, a set is :Elixir.BeamLisp.Set, a decimal
    :Elixir.BeamLisp.Decimal, an atom ref :Elixir.BeamLisp.Atom; lists/vectors/
    maps/fns as their names. The language's `Multi/type_of` leaf answers this. */
export function type(x) {
  if (x === null || x === undefined) return null;
  if (typeof x === "string") return R.kw("binary");
  if (typeof x === "boolean") return R.kw("boolean");
  if (R.isInt(x)) return R.kw("integer");
  if (x instanceof R.Flt) return R.kw("float");
  if (x instanceof R.Dec) return R.kw("Elixir.BeamLisp.Decimal");
  if (x instanceof R.Kw) return R.kw("keyword");
  if (x instanceof R.Tup) return R.kw("tuple");
  if (x instanceof R.Vec) return R.kw("vector");
  if (x instanceof R.HMap) return R.kw("map");
  if (x instanceof R.HSet) return R.kw("Elixir.BeamLisp.Set");
  if (x instanceof R.Cons || x === R.EMPTY) return R.kw("list");
  if (x instanceof Z.LazySeq) return R.kw("seq");
  if (x instanceof Z.Delay) return R.kw("Elixir.BeamLisp.Delay");
  if (typeof x === "function") return R.kw("fn");
  if (x instanceof R.Atom) return R.kw("Elixir.BeamLisp.Atom");
  return R.kw("host");
}

/** `(get coll k default)` through the compiled runtime — the language's one
    collection read (a transient leaf reads its live state this way). */
export function get(coll, k, d = null) { return runtime("get").d_get(coll, k, d); }
