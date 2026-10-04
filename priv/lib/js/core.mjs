// priv/lib/js/core.mjs — Beam Lisp's core library, native to the JS sync profile.
//
// ONE semantics, one implementation per target (PLAN-161 D5): BEAM runs
// priv/boot/core.bl + rt.bl; JS runs this file. Each export is the BL name it
// implements. The emitter resolves BOTH spellings the compiler produces —
// `:global {:ns "core" :name n}` and `:remote {:mod Ns.Rt|Ns.Core :fun f}` —
// through `CORE` (below) at BUILD time, so a name with no implementation is a
// build error, never a runtime `undefined var`.
//
// Laziness: BEAM core is lazy where Clojure is (map/filter/range/…). This
// profile is for interactive UI code, where every sequence is finite and is
// consumed immediately; `map`/`filter`/`range`/`concat`/… return EAGER lists.
// That is observable only through side effects inside the mapped fn or through
// infinite sequences, both of which the profile's audit refuses (iterate,
// repeat/1, cycle are not exported). Equality and printing agree with BEAM:
// a list and a vector are one sequential family, `(map inc [1 2])` prints `(2 3)`.

import * as R from "./rt.mjs";
const { EMPTY, EMPTY_VEC, EMPTY_MAP, EMPTY_SET, Cons, Vec, HMap, HSet, Kw, Sym, Flt, Tup, BLError, Atom } = R;

// ─── callables ──────────────────────────────────────────────────────────────
//
// A BL fn is a JS function. A multi-arity / variadic BL fn is a JS function
// that dispatches on arguments.length (the emitter builds it). Keywords, maps,
// sets and vectors are callable as in Clojure; `invoke` is the ONE dispatcher.

export function invoke(f, ...args) {
  if (typeof f === "function") return f(...args);
  if (f instanceof Kw) return get(args[0], f, args.length > 1 ? args[1] : null);
  if (f instanceof HMap) return f.get(args[0], args.length > 1 ? args[1] : null);
  if (f instanceof HSet) return f.has(args[0]) ? args[0] : (args.length > 1 ? args[1] : null);
  if (f instanceof Vec) { const v = f.nth(args[0], NF); if (v === NF) throw new BLError("index " + R.printStr(args[0]) + " out of bounds"); return v; }
  if (f instanceof Sym) return get(args[0], f, args.length > 1 ? args[1] : null);
  throw new BLError(R.printStr(f) + " is not a function");
}
const NF = { nf: true };
/** The sentinel compiled map patterns compare against (`{:keys [a]}` in a fn
    head is a pmap: a key that is ABSENT fails the clause). */
export const NOT_FOUND = NF;

// ─── seqs: every sequential op reads through `toArray`/`seqIter` ────────────

/** Iterate any seqable (nil, list, vector, map entries, set, string). */
export function* seqIter(x) {
  if (x === null || x === undefined || x === EMPTY) return;
  if (x instanceof Cons) { for (let p = x; p instanceof Cons; p = p.t) yield p.h; return; }
  if (x instanceof Vec) { yield* x; return; }
  if (x instanceof HMap) { for (const [k, v] of x.entries()) yield R.vec(k, v); return; }
  if (x instanceof HSet) { yield* x.elements().sort(R.compare); return; }
  if (typeof x === "string") { for (const ch of x) yield ch; return; }
  if (x instanceof Tup) { yield* x.items; return; }
  throw new BLError("don't know how to create a seq from " + R.printStr(x));
}
export function toArray(x) {
  if (x instanceof Vec) return x.toArray();
  const a = []; for (const e of seqIter(x)) a.push(e); return a;
}
const L = (a) => R.listFromArray(a);

export function seq(x) {
  if (x === null || x === undefined) return null;
  if (x instanceof Cons) return x;
  if (x === EMPTY) return null;
  if (x instanceof Vec || x instanceof HMap || x instanceof HSet) return x.cnt === 0 ? null : L(toArray(x));
  if (typeof x === "string") return x.length === 0 ? null : L(toArray(x));
  return L(toArray(x));
}
export function first(x) {
  if (x === null || x === undefined || x === EMPTY) return null;
  if (x instanceof Cons) return x.h;
  if (x instanceof Vec) return x.cnt === 0 ? null : x.nth(0);
  for (const e of seqIter(x)) return e;
  return null;
}
export function rest(x) {
  if (x instanceof Cons) return x.t;
  if (x === null || x === undefined || x === EMPTY) return EMPTY;
  const a = toArray(x); return a.length <= 1 ? EMPTY : L(a.slice(1));
}
export function next(x) { const r = rest(x); return r === EMPTY ? null : r; }
export function second(x) { return first(next(x)); }
export function last(x) {
  if (x instanceof Vec) return x.cnt === 0 ? null : x.nth(x.cnt - 1);
  let l = null; for (const e of seqIter(x)) l = e; return l;
}
export function butlast(x) { const a = toArray(x); return a.length <= 1 ? null : L(a.slice(0, -1)); }
export function cons(h, t) { return R.cons(h, t instanceof Cons || t === EMPTY ? t : (seq(t) || EMPTY)); }
/** Grapheme clusters (BEAM `count` on a string is String.length: graphemes,
    measured (count "é👍🏽") = 2). Intl.Segmenter where the host has it. */
const SEG = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
export function graphemes(s) { if (SEG) { const out = []; for (const g of SEG.segment(s)) out.push(g.segment); return out; } return [...s]; }
function strCount(s) { if (s.length < 64 ? /^[\x00-\x7f]*$/.test(s) : asciiLong(s)) return s.length; return graphemesCached(s).length; }
export function count(x) {
  if (x === null || x === undefined || x === EMPTY) return 0;
  if (x instanceof Cons) return x.n;
  if (x instanceof Vec || x instanceof HMap || x instanceof HSet) return x.cnt;
  if (typeof x === "string") return strCount(x);
  if (x instanceof Tup) return x.items.length;
  throw new BLError("count not supported on " + R.printStr(x));
}
/** BEAM `nth` (measured 2026-10-03): out of range on a vector or list is nil,
    not an error; on a string it raises (Rt.nth has no string clause). */
export function nth(x, i, dflt) {
  const d = arguments.length > 2 ? dflt : null;
  if (x instanceof Vec) return x.nth(i, d);
  if (x instanceof Cons) { let p = x, k = i; while (k > 0 && p instanceof Cons) { p = p.t; k--; } return (k === 0 && p instanceof Cons) ? p.h : d; }
  if (x === null || x === undefined || x === EMPTY) return d;
  if (typeof x === "string") throw new BLError("nth is not supported on a string");
  const a = toArray(x); return i >= 0 && i < a.length ? a[i] : d;
}
export function empty_Q(x) { return x === null || x === undefined || x === EMPTY || count(x) === 0; }
export function not_empty(x) { return empty_Q(x) ? null : x; }

// ─── collections ────────────────────────────────────────────────────────────

export function vector(...xs) { return R.vecFromArray(xs); }
export function vec(x) { return x instanceof Vec ? (x.meta ? new Vec(x.cnt, x.shift, x.root, x.tail, null) : x) : R.vecFromArray(toArray(x)); }
export function list(...xs) { return L(xs); }
export function hash_map(...kvs) { return R.hashMap(...kvs); }
export function hash_set(...xs) { return R.hashSet(...xs); }
export function set(x) { let s = EMPTY_SET; for (const e of seqIter(x)) s = s.conj(e); return s; }

export function get(m, k, dflt = null) {
  if (m instanceof HMap) return m.get(k, dflt);
  // BEAM coll-get: a vector index lookup answers nil when out of range,
  // NOT the default (measured: (get [1 2 3] 9 :none) is nil)
  if (m instanceof Vec) return (typeof k === "number") ? m.nth(k, null) : dflt;
  if (m instanceof HSet) return m.has(k) ? k : dflt;
  if (typeof m === "string" && typeof k === "number") return k >= 0 && k < R.cpCount(m) ? R.subs(m, k, k + 1) : dflt;
  return dflt;
}
export function get_in(m, ks, dflt = null) {
  let cur = m;
  for (const k of seqIter(ks)) { cur = get(cur, k, NF); if (cur === NF) return dflt; }
  return cur;
}
export function contains_Q(m, k) {
  if (m instanceof HMap) return m.has(k);
  if (m instanceof HSet) return m.has(k);
  if (m instanceof Vec) return typeof k === "number" && k >= 0 && k < m.cnt;
  if (m === null || m === undefined) return false;
  throw new BLError("contains? not supported on " + R.printStr(m));
}
export function assoc(m, k, v, ...kvs) {
  let out;
  if (m === null || m === undefined) out = EMPTY_MAP.assoc(k, v);
  else if (m instanceof HMap) out = m.assoc(k, v);
  else if (m instanceof Vec) {
    if (typeof k !== "number") throw new BLError("vector assoc needs an integer index, got " + R.printStr(k));
    out = m.assocN(k, v);
  } else throw new BLError("assoc not supported on " + R.printStr(m));
  for (let i = 0; i < kvs.length; i += 2) out = assoc(out, kvs[i], kvs[i + 1]);
  return out;
}
export function dissoc(m, ...ks) {
  if (m === null || m === undefined) return null;
  let out = m; for (const k of ks) out = out.dissoc(k); return out;
}
export function assoc_in(m, ks, v) {
  const a = toArray(ks);
  if (a.length === 0) throw new BLError("assoc-in needs a non-empty key path");
  const go = (cur, i) => assoc(cur, a[i], i === a.length - 1 ? v : go(get(cur, a[i]), i + 1));
  return go(m, 0);
}
export function update(m, k, f, ...args) { return assoc(m, k, invoke(f, get(m, k), ...args)); }
export function update_in(m, ks, f, ...args) {
  const a = toArray(ks);
  const go = (cur, i) => i === a.length - 1 ? assoc(cur, a[i], invoke(f, get(cur, a[i]), ...args)) : assoc(cur, a[i], go(get(cur, a[i]), i + 1));
  return go(m, 0);
}
export function conj(c, ...xs) {
  let out = c;
  for (const x of xs) {
    if (out === null || out === undefined) out = R.list(x);
    else if (out instanceof Vec) out = out.conj(x);
    else if (out instanceof Cons || out === EMPTY) out = R.cons(x, out);
    else if (out instanceof HSet) out = out.conj(x);
    else if (out instanceof HMap) {
      if (x === null) continue;
      if (x instanceof Vec && x.cnt === 2) out = out.assoc(x.nth(0), x.nth(1));
      else if (x instanceof HMap) { for (const [k, v] of x) out = out.assoc(k, v); }
      else throw new BLError("conj on a map needs a [k v] entry, got " + R.printStr(x));
    } else throw new BLError("conj not supported on " + R.printStr(out));
  }
  return out;
}
export function disj(s, ...xs) { let out = s; for (const x of xs) out = out.disj(x); return out; }
export function peek(c) { if (c instanceof Vec) return c.cnt ? c.nth(c.cnt - 1) : null; return first(c); }
export function pop(c) { if (c instanceof Vec) return c.pop(); if (c instanceof Cons) return c.t; throw new BLError("can't pop " + R.printStr(c)); }
export function into(to, from) {
  if (to instanceof HMap) { let out = to; for (const e of seqIter(from)) out = conj(out, e); return out; }
  let out = to; for (const e of seqIter(from)) out = conj(out, e); return out;
}
export function keys(m) { if (m === null || m === undefined || m.cnt === 0) return null; return L(m.entries().map(e => e[0])); }
export function vals(m) { if (m === null || m === undefined || m.cnt === 0) return null; return L(m.entries().map(e => e[1])); }
export function key(e) { return e.nth(0); }
export function val(e) { return e.nth(1); }
export function select_keys(m, ks) { let out = EMPTY_MAP; for (const k of seqIter(ks)) { const v = get(m, k, NF); if (v !== NF) out = out.assoc(k, v); } return out; }
export function merge(...ms) {
  let out = null;
  for (const m of ms) { if (m === null || m === undefined) continue; if (out === null) { out = m; continue; } for (const [k, v] of m) out = out.assoc(k, v); }
  return out;
}
export function merge_with(f, ...ms) {
  let out = null;
  for (const m of ms) { if (!m) continue; if (out === null) { out = m; continue; } for (const [k, v] of m) out = out.has(k) ? out.assoc(k, invoke(f, out.get(k), v)) : out.assoc(k, v); }
  return out;
}
export function zipmap(ks, vs) { let out = EMPTY_MAP; const a = toArray(ks), b = toArray(vs); for (let i = 0; i < Math.min(a.length, b.length); i++) out = out.assoc(a[i], b[i]); return out; }
export function subvec(v, from, to) { return R.subvec(v, from, to); }
export function update_vals(m, f) { let out = EMPTY_MAP; for (const [k, v] of m) out = out.assoc(k, invoke(f, v)); return out; }
export function update_keys(m, f) { let out = EMPTY_MAP; for (const [k, v] of m) out = out.assoc(invoke(f, k), v); return out; }
export function find(m, k) { const v = get(m, k, NF); return v === NF ? null : R.vec(k, v); }
export function empty(c) { if (c instanceof Vec) return EMPTY_VEC; if (c instanceof HMap) return EMPTY_MAP; if (c instanceof HSet) return EMPTY_SET; if (c instanceof Cons || c === EMPTY) return EMPTY; return null; }

// ─── sequence functions (eager, finite) ─────────────────────────────────────

export function map(f, ...colls) {
  if (colls.length === 1) { const out = []; for (const e of seqIter(colls[0])) out.push(invoke(f, e)); return L(out); }
  const as = colls.map(toArray); const n = Math.min(...as.map(a => a.length)); const out = [];
  for (let i = 0; i < n; i++) out.push(invoke(f, ...as.map(a => a[i])));
  return L(out);
}
export function mapv(f, ...colls) { return R.vecFromArray(toArray(map(f, ...colls))); }
export function map_indexed(f, c) { const out = []; let i = 0; for (const e of seqIter(c)) out.push(invoke(f, i++, e)); return L(out); }
export function keep_indexed(f, c) { const out = []; let i = 0; for (const e of seqIter(c)) { const r = invoke(f, i++, e); if (r !== null && r !== undefined) out.push(r); } return L(out); }
export function filter(p, c) { const out = []; for (const e of seqIter(c)) if (R.truthy(invoke(p, e))) out.push(e); return L(out); }
export function filterv(p, c) { const out = []; for (const e of seqIter(c)) if (R.truthy(invoke(p, e))) out.push(e); return R.vecFromArray(out); }
export function remove(p, c) { const out = []; for (const e of seqIter(c)) if (!R.truthy(invoke(p, e))) out.push(e); return L(out); }
export function keep(f, c) { const out = []; for (const e of seqIter(c)) { const r = invoke(f, e); if (r !== null && r !== undefined) out.push(r); } return L(out); }
export function mapcat(f, ...colls) { const out = []; for (const part of seqIter(map(f, ...colls))) for (const e of seqIter(part)) out.push(e); return L(out); }
export function concat(...cs) { const out = []; for (const c of cs) for (const e of seqIter(c)) out.push(e); return L(out); }

// reduce with `reduced` short-circuit
export class Reduced { constructor(v) { this.v = v; } }
export function reduced(v) { return new Reduced(v); }
export function reduced_Q(x) { return x instanceof Reduced; }
export function unreduced(x) { return x instanceof Reduced ? x.v : x; }
export function reduce(f, a, b) {
  let acc, it;
  if (arguments.length === 2) { it = seqIter(a); const s = it.next(); if (s.done) return invoke(f); acc = s.value; }
  else { acc = a; it = seqIter(b); }
  for (const e of it) { acc = invoke(f, acc, e); if (acc instanceof Reduced) return acc.v; }
  return acc;
}
export function reduce_kv(f, init, m) {
  let acc = init;
  if (m instanceof Vec) { let i = 0; for (const v of m) { acc = invoke(f, acc, i++, v); if (acc instanceof Reduced) return acc.v; } return acc; }
  if (m === null || m === undefined) return acc;
  for (const [k, v] of m.entries()) { acc = invoke(f, acc, k, v); if (acc instanceof Reduced) return acc.v; }
  return acc;
}
export function some(p, c) { for (const e of seqIter(c)) { const r = invoke(p, e); if (R.truthy(r)) return r; } return null; }
export function every_Q(p, c) { for (const e of seqIter(c)) if (!R.truthy(invoke(p, e))) return false; return true; }
export function not_every_Q(p, c) { return !every_Q(p, c); }
export function not_any_Q(p, c) { return some(p, c) === null; }
export function take(n, c) { const out = []; if (n <= 0) return EMPTY; for (const e of seqIter(c)) { out.push(e); if (out.length >= n) break; } return L(out); }
export function drop(n, c) { const a = toArray(c); return L(a.slice(Math.max(0, n))); }
export function take_while(p, c) { const out = []; for (const e of seqIter(c)) { if (!R.truthy(invoke(p, e))) break; out.push(e); } return L(out); }
export function drop_while(p, c) { const a = toArray(c); let i = 0; while (i < a.length && R.truthy(invoke(p, a[i]))) i++; return L(a.slice(i)); }
export function take_last(n, c) { const a = toArray(c); return a.length === 0 ? null : L(a.slice(Math.max(0, a.length - n))); }
export function drop_last(n, c) { if (arguments.length === 1) { c = n; n = 1; } const a = toArray(c); return L(a.slice(0, Math.max(0, a.length - n))); }
export function split_at(n, c) { const a = toArray(c); return R.vec(L(a.slice(0, n)), L(a.slice(n))); }
export function split_with(p, c) { return R.vec(take_while(p, c), drop_while(p, c)); }
export function reverse(c) { return L(toArray(c).reverse()); }
export function range(a, b, step) {
  let start = 0, end, st = 1;
  if (arguments.length === 1) end = a; else { start = a; end = b; if (arguments.length > 2) st = step; }
  if (end === undefined) throw new BLError("range needs an end in the JS sync profile (infinite sequences are refused)");
  if (st === 0) throw new BLError("range step 0 would not terminate");
  const out = []; for (let i = start; st > 0 ? i < end : i > end; i += st) out.push(i); return L(out);
}
export function repeat(n, x) { if (arguments.length < 2) throw new BLError("repeat needs a count in the JS sync profile"); return L(new Array(Math.max(0, n)).fill(x)); }
export function repeatedly(n, f) { if (arguments.length < 2) throw new BLError("repeatedly needs a count in the JS sync profile"); const out = []; for (let i = 0; i < n; i++) out.push(invoke(f)); return L(out); }
export function partition(n, step, c) {
  if (arguments.length === 2) { c = step; step = n; }
  const a = toArray(c), out = [];
  for (let i = 0; i + n <= a.length; i += step) out.push(L(a.slice(i, i + n)));
  return L(out);
}
export function partition_all(n, step, c) {
  if (arguments.length === 2) { c = step; step = n; }
  const a = toArray(c), out = [];
  for (let i = 0; i < a.length; i += step) out.push(L(a.slice(i, i + n)));
  return L(out);
}
export function partition_by(f, c) {
  const out = []; let cur = [], prev = NF;
  for (const e of seqIter(c)) { const k = invoke(f, e); if (prev !== NF && !R.eqv(k, prev)) { out.push(L(cur)); cur = []; } cur.push(e); prev = k; }
  if (cur.length) out.push(L(cur));
  return L(out);
}
export function interpose(sep, c) { const out = []; for (const e of seqIter(c)) { if (out.length) out.push(sep); out.push(e); } return L(out); }
export function interleave(...cs) { const as = cs.map(toArray); const n = Math.min(...as.map(a => a.length)); const out = []; for (let i = 0; i < n; i++) for (const a of as) out.push(a[i]); return L(out); }
export function distinct(c) { let seen = EMPTY_SET; const out = []; for (const e of seqIter(c)) if (!seen.has(e)) { seen = seen.conj(e); out.push(e); } return L(out); }
export function dedupe(c) { const out = []; let prev = NF; for (const e of seqIter(c)) { if (prev === NF || !R.eqv(e, prev)) out.push(e); prev = e; } return L(out); }
export function flatten(c) {
  const out = [];
  const go = (x) => { if (x instanceof Vec || x instanceof Cons || x === EMPTY) { for (const e of seqIter(x)) go(e); } else out.push(x); };
  for (const e of seqIter(c)) go(e);
  return L(out);
}
export function frequencies(c) { let m = EMPTY_MAP; for (const e of seqIter(c)) m = m.assoc(e, m.get(e, 0) + 1); return m; }
export function group_by(f, c) { let m = EMPTY_MAP; for (const e of seqIter(c)) { const k = invoke(f, e); m = m.assoc(k, m.get(k, EMPTY_VEC).conj(e)); } return m; }
export function index_by(f, c) { let m = EMPTY_MAP; for (const e of seqIter(c)) m = m.assoc(invoke(f, e), e); return m; }

// sort: stable merge sort with BL `compare` (or a comparator returning a number or boolean)
function cmpFn(c) {
  if (c === undefined) return R.compare;
  return (a, b) => { const r = invoke(c, a, b); if (typeof r === "number") return r; if (r === true) return -1; if (r === false) return R.truthy(invoke(c, b, a)) ? 1 : 0; return Number(r); };
}
export function sort(c, coll) { if (arguments.length === 1) { coll = c; c = undefined; } return L(toArray(coll).sort(cmpFn(c))); }
export function sort_by(kf, c, coll) {
  if (arguments.length === 2) { coll = c; c = undefined; }
  const cf = cmpFn(c);
  return L(toArray(coll).map(e => [invoke(kf, e), e]).sort((x, y) => cf(x[0], y[0])).map(p => p[1]));
}
export function max_key(f, ...xs) { let best = xs[0], bk = invoke(f, best); for (const x of xs.slice(1)) { const k = invoke(f, x); if (k >= bk) { best = x; bk = k; } } return best; }
export function min_key(f, ...xs) { let best = xs[0], bk = invoke(f, best); for (const x of xs.slice(1)) { const k = invoke(f, x); if (k <= bk) { best = x; bk = k; } } return best; }

// ─── functions ──────────────────────────────────────────────────────────────

export function identity(x) { return x; }
export function constantly(x) { return () => x; }
export function comp(...fs) { if (fs.length === 0) return identity; return (...args) => { let r = invoke(fs[fs.length - 1], ...args); for (let i = fs.length - 2; i >= 0; i--) r = invoke(fs[i], r); return r; }; }
export function partial(f, ...pre) { return (...args) => invoke(f, ...pre, ...args); }
export function complement(f) { return (...args) => !R.truthy(invoke(f, ...args)); }
export function juxt(...fs) { return (...args) => R.vecFromArray(fs.map(f => invoke(f, ...args))); }
export function fnil(f, ...ds) { return (...args) => invoke(f, ...args.map((a, i) => (a === null || a === undefined) && i < ds.length ? ds[i] : a)); }
/** RT.invocable?(v, n): can value `v` be called with `n` arguments? The
    compiler asks this when a LOCAL in call position shadows a linked core
    name (`(name x)` with a parameter called `name`). A JS function's arity is
    not reliable (variadics report 0), so any function answers true; data
    callables follow Clojure: keywords, maps, sets take 1-2, vectors 1. */
export function invocable_Q(v, n) {
  if (typeof v === "function") return true;
  if (v instanceof Kw || v instanceof Sym || v instanceof HMap || v instanceof HSet) return n === 1 || n === 2;
  if (v instanceof Vec) return n === 1;
  return false;
}
export function apply(f, ...args) { const lastArg = args.pop(); return invoke(f, ...args, ...toArray(lastArg)); }
export function memoize(f) { let cache = EMPTY_MAP; return (...args) => { const k = R.vecFromArray(args); const v = cache.get(k, NF); if (v !== NF) return v; const r = invoke(f, ...args); cache = cache.assoc(k, r); return r; }; }

// ─── predicates ─────────────────────────────────────────────────────────────

export const nil_Q = (x) => x === null || x === undefined;
export const some_Q = (x) => x !== null && x !== undefined;
export const true_Q = (x) => x === true;
export const false_Q = (x) => x === false;
export const boolean_Q = (x) => x === true || x === false;
export const string_Q = (x) => typeof x === "string";
export const keyword_Q = (x) => x instanceof Kw;
export const symbol_Q = (x) => x instanceof Sym;
export const number_Q = (x) => R.isNumber(x);
export const int_Q = (x) => R.isInt(x);
export const integer_Q = (x) => R.isInt(x);
export const float_Q = (x) => x instanceof Flt;
export const fn_Q = (x) => typeof x === "function";
export const ifn_Q = (x) => typeof x === "function" || x instanceof Kw || x instanceof HMap || x instanceof HSet || x instanceof Vec;
export const map_Q = (x) => x instanceof HMap;
export const vector_Q = (x) => x instanceof Vec;
export const set_Q = (x) => x instanceof HSet;
export const list_Q = (x) => x instanceof Cons || x === EMPTY;
export const seq_Q = (x) => x instanceof Cons || x === EMPTY;
export const sequential_Q = (x) => x instanceof Vec || x instanceof Cons || x === EMPTY;
export const coll_Q = (x) => x instanceof Vec || x instanceof Cons || x === EMPTY || x instanceof HMap || x instanceof HSet;
export const associative_Q = (x) => x instanceof HMap || x instanceof Vec;
export const zero_Q = (x) => R.numEq(x, 0);
export const pos_Q = (x) => R.gt(x, 0);
export const neg_Q = (x) => R.lt(x, 0);
export const even_Q = (x) => R.rem(x, 2) === 0;
export const odd_Q = (x) => R.rem(x, 2) !== 0;
export const not = (x) => !R.truthy(x);
export const is_Q = some_Q;

// ─── equality, comparison, numbers ──────────────────────────────────────────

export function eqv(a, b, ...more) { if (!R.eqv(a, b)) return false; for (const c of more) if (!R.eqv(b, c)) return false; return true; }
export function not_eq(a, b) { return !R.eqv(a, b); }
export function identical_Q(a, b) { return a === b; }
export function compare(a, b) { return R.compare(a, b); }
export function hash(x) { return R.hashOf(x); }
export function inc(x) { return R.add(x, 1); }
export function dec(x) { return R.sub(x, 1); }
export function abs(x) { if (x instanceof Flt) return R.flt(Math.abs(x.v)); return R.lt(x, 0) ? R.sub(0, x) : x; }
export function max(a, ...xs) { let m = a; for (const x of xs) if (R.gt(x, m)) m = x; return m; }
export function min(a, ...xs) { let m = a; for (const x of xs) if (R.lt(x, m)) m = x; return m; }
export const quot = R.quot, rem = R.rem, mod = R.mod;
export function plus(...xs) { let s = 0; for (const x of xs) s = R.add(s, x); return s; }
export function minus(a, ...xs) { if (xs.length === 0) return R.sub(0, a); let s = a; for (const x of xs) s = R.sub(s, x); return s; }
export function times(...xs) { let s = 1; for (const x of xs) s = R.mul(s, x); return s; }
export function divide(a, ...xs) { if (xs.length === 0) return R.div(1, a); let s = a; for (const x of xs) s = R.div(s, x); return s; }
function chain(op) { return (a, ...xs) => { let p = a; for (let i = 0; i < xs.length; i++) { if (!op(p, xs[i])) return false; p = xs[i]; } return true; }; }
export const lt = chain(R.lt), gt = chain(R.gt), le = chain(R.le), ge = chain(R.ge), num_eq = chain(R.numEq);
export function int(x) { if (x instanceof Flt) return Math.trunc(x.v); if (typeof x === "string" && x.length === 1) return x.codePointAt(0); return x; }
export function double(x) { return R.flt(R.toNumber(x)); }
/** NOT in BEAM core (2026-10-03): kept for JS-only code; portable code
    parses with plain BL (see apps/bl-ed/ed/num.bl). */
export function parse_long(s) { return /^[+-]?\d+$/.test(s) ? (Number.isSafeInteger(Number(s)) ? Number(s) : BigInt(s)) : null; }
export function parse_double(s) { const v = Number(s); return s.trim() === "" || Number.isNaN(v) ? null : R.flt(v); }
export function rand_int(n) { return Math.floor(Math.random() * n); }
export function bit_and(a, b) { return a & b; }
export function bit_or(a, b) { return a | b; }

// ─── strings, keywords, symbols ─────────────────────────────────────────────

export function str(...xs) { let s = ""; for (const x of xs) s += R.strOf(x); return s; }
export function pr_str(...xs) { return xs.map(R.printStr).join(" "); }
export function name(x) { if (typeof x === "string") return x; if (x instanceof Kw) return x.name; if (x instanceof Sym) return x.name; throw new BLError("name of " + R.printStr(x)); }
export function namespace(x) { return x instanceof Kw ? x.ns : null; }
export function keyword(a, b) { if (b !== undefined) return R.kw(a + "/" + b); if (a instanceof Kw) return a; return R.kw(a instanceof Sym ? a.name : a); }
export function symbol(x) { return R.sym(x instanceof Kw ? x.fq : x); }
/** `subs` by GRAPHEME index, as BEAM's String.slice (é and 👍🏽 are one each).
 *
 *  Hot in UI code (a scanner calls `(subs l i (inc i))` per character), so:
 *  ASCII strings slice directly; other strings cache their grapheme array
 *  in a small LRU keyed by the string itself (strings are values: a cached
 *  segmentation can never go stale), making repeated subs O(1) after the
 *  first instead of O(n) each. */
const ASCII = /^[\x00-\x7f]*$/;
const GCACHE = new Map(); const GCACHE_MAX = 256;
function graphemesCached(s) {
  let g = GCACHE.get(s);
  if (g !== undefined) { GCACHE.delete(s); GCACHE.set(s, g); return g; }
  g = graphemes(s);
  GCACHE.set(s, g);
  if (GCACHE.size > GCACHE_MAX) GCACHE.delete(GCACHE.keys().next().value);
  return g;
}
export function subs(s, start, end) {
  if (s.length < 64 ? ASCII.test(s) : asciiLong(s)) {
    const n = s.length; if (end === undefined) end = n;
    if (start < 0 || end > n || end < start) throw new BLError("subs: index out of range " + start + " " + end + " for length " + n);
    return s.slice(start, end);
  }
  const g = graphemesCached(s), n = g.length;
  if (end === undefined) end = n;
  if (start < 0 || end > n || end < start) throw new BLError("subs: index out of range " + start + " " + end + " for length " + n);
  if (end === start + 1) return g[start];
  return g.slice(start, end).join("");
}
/** ASCII test for long strings, memoized per string (same value argument). */
const ACACHE = new Map();
function asciiLong(s) {
  let v = ACACHE.get(s);
  if (v === undefined) { v = ASCII.test(s); ACACHE.set(s, v); if (ACACHE.size > GCACHE_MAX) ACACHE.delete(ACACHE.keys().next().value); }
  return v;
}
export function join(sep, coll) { if (coll === undefined) { coll = sep; sep = ""; } return toArray(coll).map(R.strOf).join(sep); }
export function split(s, sep, limit) {
  const parts = sep instanceof RegExp ? s.split(sep) : s.split(sep);
  if (limit !== undefined && parts.length > limit) { const head = parts.slice(0, limit - 1); head.push(parts.slice(limit - 1).join(sep)); return R.vecFromArray(head); }
  return R.vecFromArray(parts);
}
export function split_lines(s) { return R.vecFromArray(s.split(/\r?\n/)); }
export function trim(s) { return s.trim(); }
export function triml(s) { return s.trimStart(); }
export function trimr(s) { return s.trimEnd(); }
export function upper_case(s) { return s.toUpperCase(); }
export function lower_case(s) { return s.toLowerCase(); }
export function starts_with_Q(s, p) { return s.startsWith(p); }
export function ends_with_Q(s, p) { return s.endsWith(p); }
export function includes_Q(s, p) { return s.includes(p); }
export function blank_Q(s) { return s === null || s === undefined || /^\s*$/.test(s); }
/** Grapheme index of the first `p` in `s` (BEAM splits on graphemes). */
export function index_of(s, p) { const u = s.indexOf(p); return u < 0 ? null : count(s.slice(0, u)); }
export function last_index_of(s, p) { const u = s.lastIndexOf(p); return u < 0 ? null : count(s.slice(0, u)); }
export function replace_str(s, a, b) { return s.split(a).join(b); }
export const replace = replace_str;
export function char_at(s, i) { return subs(s, i, i + 1); }
export function codepoints(s) { const out = []; for (const ch of s) out.push(ch.codePointAt(0)); return R.vecFromArray(out); }
export function from_codepoints(v) { return String.fromCodePoint(...toArray(v)); }
export function repeat_str(s, n) { return s.repeat(Math.max(0, n)); }

// ─── atoms ──────────────────────────────────────────────────────────────────

export function atom(v) { return new Atom(v); }
export function deref(a) { return a.v; }
export function reset_BANG(a, v) { const old = a.v; a.v = v; notify(a, old, v); return v; }
export function swap_BANG(a, f, ...args) { const old = a.v; const v = invoke(f, old, ...args); a.v = v; notify(a, old, v); return v; }
export function add_watch(a, k, f) { a.watches = (a.watches || EMPTY_MAP).assoc(k, f); return a; }
export function remove_watch(a, k) { if (a.watches) a.watches = a.watches.dissoc(k); return a; }
function notify(a, old, nu) { if (a.watches && old !== nu) for (const [k, f] of a.watches) invoke(f, k, a, old, nu); }

// ─── errors ─────────────────────────────────────────────────────────────────

export function ex_info(msg, data, cause) { return new BLError(msg, data === undefined ? EMPTY_MAP : data, cause); }
export function ex_message(e) { return e instanceof Error ? e.message : null; }
export function ex_data(e) { return e instanceof BLError ? e.data : null; }
export function ex_cause(e) { return e instanceof BLError ? e.blCause : null; }
export function throw_(e) { throw e; }
/** The frontend lowers every `catch` through Exception.normalize(kind, value,
    stack) and re-raises a miss with erlang:raise(kind, value, stack). A JS
    throw is already the normalized value; a non-Error is wrapped once so
    ex-message/ex-data see a BLError. */
export function exception_normalize(_kind, v, _stack) {
  if (v instanceof Error) return v;
  return new BLError(R.strOf(v), R.hashMap(R.kw("thrown"), v));
}
export function erlang_raise(_kind, v, _stack) { throw v; }
/** `catch` clause type tests compile to a struct check against the
    exception's module; on JS the class IS the type. */
export const K_error = R.kw("error");

// ─── printing ───────────────────────────────────────────────────────────────

let OUT = (s) => { if (typeof console !== "undefined") console.log(s); };
export function set_out_BANG(f) { OUT = f; }
export function println(...xs) { OUT(xs.map(R.strOf).join(" ")); return null; }
export function prn(...xs) { OUT(xs.map(R.printStr).join(" ")); return null; }
export function type(x) {
  if (x === null || x === undefined) return R.kw("nil");
  if (typeof x === "string") return R.kw("string");
  if (typeof x === "boolean") return R.kw("boolean");
  if (R.isInt(x)) return R.kw("integer");
  if (x instanceof Flt) return R.kw("float");
  if (x instanceof Kw) return R.kw("keyword");
  if (x instanceof Sym) return R.kw("symbol");
  if (x instanceof Vec) return R.kw("vector");
  if (x instanceof HMap) return R.kw("map");
  if (x instanceof HSet) return R.kw("set");
  if (x instanceof Cons || x === EMPTY) return R.kw("list");
  if (typeof x === "function") return R.kw("fn");
  if (x instanceof Atom) return R.kw("atom");
  return R.kw("host");
}

// ─── the registry: BL name → implementation ─────────────────────────────────
//
// JS identifiers cannot carry `?`, `!`, `-`, `=`, so exports use _Q/_BANG/_
// spellings; the registry maps every BL name the compiler can emit to them.

export const CORE = {
  "invoke": invoke, "seq": seq, "first": first, "rest": rest, "next": next, "second": second, "last": last, "butlast": butlast,
  "cons": cons, "count": count, "nth": nth, "empty?": empty_Q, "not-empty": not_empty,
  "vector": vector, "vec": vec, "list": list, "hash-map": hash_map, "hash-set": hash_set, "set": set,
  "get": get, "get-in": get_in, "contains?": contains_Q, "assoc": assoc, "dissoc": dissoc, "assoc-in": assoc_in,
  "update": update, "update-in": update_in, "conj": conj, "disj": disj, "peek": peek, "pop": pop, "into": into,
  "keys": keys, "vals": vals, "key": key, "val": val, "select-keys": select_keys, "merge": merge, "merge-with": merge_with,
  "zipmap": zipmap, "subvec": subvec, "update-vals": update_vals, "update-keys": update_keys, "find": find, "empty": empty,
  "map": map, "mapv": mapv, "map-indexed": map_indexed, "keep-indexed": keep_indexed, "filter": filter, "filterv": filterv,
  "remove": remove, "keep": keep, "mapcat": mapcat, "concat": concat, "reduce": reduce, "reduce-kv": reduce_kv,
  "reduced": reduced, "reduced?": reduced_Q, "unreduced": unreduced,
  "some": some, "every?": every_Q, "not-every?": not_every_Q, "not-any?": not_any_Q,
  "take": take, "drop": drop, "take-while": take_while, "take_while": take_while,
  // runtime-function spellings the COMPILER emits (Ns.Rt/<fun>), when their
  // argument order or meaning differs from the BL name of the same word:
  // destructuring `[a & more]` emits Rt/drop in RT order (coll, n)
  "rt:drop": (c, n) => drop(n, c), "rt:drop_clj": drop,
  // (apply f a b … coll) lowers to Rt.apply_variadic(f, a, REST) where REST is
  // the list (b … coll): every element but the last is a leading argument
  "rt:apply_variadic": (f, a, rest) => { const r = toArray(rest); const last = r.pop(); return invoke(f, a, ...r, ...toArray(last)); },
  "rt:apply_to": (f, args) => invoke(f, ...toArray(args)),
  // (map f c1 c2 …) lowers to Rt.map_multi(f, c1, (c2 …))
  "rt:map_multi": (f, c1, rest) => map(f, c1, ...toArray(rest)),
  "drop-while": drop_while, "drop_while": drop_while, "take-last": take_last, "drop-last": drop_last,
  "split-at": split_at, "split-with": split_with, "reverse": reverse, "range": range, "repeat": repeat, "repeatedly": repeatedly,
  "partition": partition, "partition-all": partition_all, "partition-by": partition_by, "interpose": interpose,
  "interleave": interleave, "distinct": distinct, "dedupe": dedupe, "flatten": flatten, "frequencies": frequencies,
  "group-by": group_by, "index-by": index_by, "sort": sort, "sort-by": sort_by, "max-key": max_key, "min-key": min_key,
  "identity": identity, "constantly": constantly, "comp": comp, "partial": partial, "complement": complement,
  "juxt": juxt, "fnil": fnil, "apply": apply, "invocable?": invocable_Q, "apply_to": (f, args) => invoke(f, ...toArray(args)), "memoize": memoize,
  "nil?": nil_Q, "some?": some_Q, "true?": true_Q, "false?": false_Q, "boolean?": boolean_Q, "string?": string_Q,
  "keyword?": keyword_Q, "symbol?": symbol_Q, "number?": number_Q, "int?": int_Q, "integer?": integer_Q, "float?": float_Q,
  "fn?": fn_Q, "ifn?": ifn_Q, "map?": map_Q, "vector?": vector_Q, "set?": set_Q, "list?": list_Q, "seq?": seq_Q,
  "sequential?": sequential_Q, "coll?": coll_Q, "associative?": associative_Q, "zero?": zero_Q, "pos?": pos_Q,
  "neg?": neg_Q, "even?": even_Q, "odd?": odd_Q, "not": not, "is?": is_Q,
  "=": eqv, "eqv": eqv,
  // Erlang term comparison (erlang/=:= exact, /= and =/= the negations)
  "erlang/=:=": (a, b) => R.keyEq(a, b), "erlang//=": (a, b) => !R.eqv(a, b), "erlang/=/=": (a, b) => !R.keyEq(a, b), "not=": not_eq, "identical?": identical_Q, "compare": compare, "hash": hash, "hash_key": identity,
  "inc": inc, "dec": dec, "abs": abs, "max": max, "min": min, "quot": quot, "rem": rem, "mod": mod,
  "+": plus, "-": minus, "*": times, "/": divide, "<": lt, ">": gt, "<=": le, ">=": ge, "==": num_eq,
  "int": int, "double": double, "parse-long": parse_long, "parse-double": parse_double, "rand-int": rand_int,
  "bit-and": bit_and, "bit-or": bit_or,
  "str": str, "pr-str": pr_str, "name": name, "namespace": namespace, "keyword": keyword, "symbol": symbol,
  "subs": subs, "join": join, "split": split, "split-lines": split_lines, "trim": trim, "triml": triml, "trimr": trimr,
  "upper-case": upper_case, "lower-case": lower_case, "starts-with?": starts_with_Q, "ends-with?": ends_with_Q,
  "includes?": includes_Q, "blank?": blank_Q, "index-of": index_of, "last-index-of": last_index_of,
  "replace-str": replace_str, "replace": replace, "char-at": char_at, "codepoints": codepoints,
  "from-codepoints": from_codepoints, "repeat-str": repeat_str,
  "atom": atom, "deref": deref, "reset!": reset_BANG, "swap!": swap_BANG, "add-watch": add_watch, "remove-watch": remove_watch,
  "ex-info": ex_info, "ex-message": ex_message, "ex-data": ex_data, "ex-cause": ex_cause,
  "Exception/normalize": exception_normalize, "erlang/raise": erlang_raise, "throw": throw_,
  "println": println, "prn": prn, "type": type,
};
