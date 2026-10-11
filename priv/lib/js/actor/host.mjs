// ─────────────────────────────────────────────────────────────────────────────
// host.mjs — the irreducible JavaScript host for the beam-lisp ANF→JS
// actor execution target.
//
// OWNERSHIP SPLIT (see research/js-actors/NATIVE.md):
//
//   THIS FILE owns exactly four things, none of which is actor policy:
//     1. adapters to the canonical JS value runtime and host leaf operations,
//     2. the machine that drives compiled BL generators — the control ABI
//        (call / tail / park / host-wait) and its frame stack. A turn that died
//        REPORTS the thrown value's class and reason; what a reason then means
//        to a process is BL's business (see `runtime.bl` `rt-terminate!`),
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

// One value implementation for both direct calls and actor frames. The actor
// machine owns control; it does not own a competing scalar/list/tuple model.
import * as V from '../rt.mjs';
export {V as values};
export const Flt=V.Flt, Dec=V.Dec, flt=V.flt, dec=V.dec;
export const numberValue=V.toNumber;
export const KW=V.Kw,kw=V.kw;
export function isKw(x) { return x instanceof KW; }
export function kwName(x) { return x.fq; }
export const Cons=V.Cons,ENIL=V.EMPTY;
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
/** `apply`'s final argument, as BEAM's seq_to_args reads it: nil, a list or
 *  a vector. Anything else is not a sequence. */
export function seqToArray(x) {
  if (x === null || x === undefined) return [];
  if (isVec(x)) return vecItems(x).slice();
  return listToArray(x);
}
export function listToArray(l) {
  const out = [];
  let p = l;
  while (p instanceof Cons) { out.push(p.h); p = p.t; }
  if (p !== ENIL) throw new Error("not a proper list");
  return out;
}

/** A data tuple (Erlang tuple). */
export const T=V.Tup;
export function tup(items) { return new T(items); }
export function isTup(x) { return x instanceof T; }
export function tupEl(x, i) { return x.items[i]; }
export function tupSize(x) { return x.items.length; }

/** A record / struct: `%Mod{...}` and, notably, a beam-lisp Vector. */
export const struct=V.struct,isStruct=V.isStruct,structMod=V.structMod,structField=V.structField;
export const VECTOR_MOD=V.VECTOR_MOD;

export function isVec(x) { return x instanceof V.Vec; }
export function vecFromArray(items) { return V.vecFromArray(items); }
export function vec(items) { return vecFromArray(items); }
export function vecItems(x) { return x.toArray(); }
export function vecSize(x) { return x.cnt; }
export function vecEl(x, i) { return x.nth(i); }
export function vecAppend(v, x) { return v.conj(x); }
export function vecRemove(v, i) { return vecFromArray(vecItems(v).filter((_, k) => k !== i)); }
export function vecToList(v) { return listFromArray(vecItems(v)); }
export function vecFromList(l) { return vecFromArray(listToArray(l)); }

export const SET_MOD = "Elixir.BeamLisp.Set";
/** Canonical persistent set; enumeration retains the measured actor order. */
export const BSet = V.HSet;
export function bset(elems) { let s = V.EMPTY_SET; for (const e of elems) s = s.conj(e); return s; }
export function isSet(x) { return x instanceof BSet; }
export function setFromList(l) { return bset(listToArray(l)); }
export function setHas(s, x) { return isSet(s) && s.has(x); }
export function setPut(s, x) { return (isSet(s) ? s : V.EMPTY_SET).conj(x); }
export function setRemove(s, x) { return (isSet(s) ? s : V.EMPTY_SET).disj(x); }
export function setSize(s) { return isSet(s) ? s.cnt : 0; }
export function setElements(s) { return isSet(s) ? [...s].sort(keyOrder) : []; }
export function setToList(s) { return listFromArray(setElements(s)); }

/** Canonical persistent HAMT. Actor frames and direct modules share values. */
export const BMap = V.HMap;
export function bmap(pairs) { let m = V.EMPTY_MAP; for (const [k,v] of pairs) m = m.assoc(k,v); return m; }
export function isBMap(x) { return x instanceof BMap; }
export function isMap(x) { return isBMap(x); }
export function mapHas(m, k) { return isBMap(m) && m.has(k); }
export function mapGet(m, k, dflt = null) {
  if (isBMap(m)) return m.get(k, dflt);

  return dflt;
}
export function mapPut(m, k, v) { return (isBMap(m) ? m : V.EMPTY_MAP).assoc(k,v); }
export function mapKeys(m) { return listFromArray(isBMap(m) ? [...m].map(p => p[0]).sort(keyOrder) : []); }
export function mapRemove(m, k) { return (isBMap(m) ? m : V.EMPTY_MAP).dissoc(k); }
export function emptyMap() { return V.EMPTY_MAP; }
export function mapSize(m) { return isBMap(m) ? m.cnt : 0; }

// ── mutable tables (host storage primitive) ─────────────────────────────────
//
// A TABLE is SHARED MUTABLE state: the host keeps ONE native `Map` and updates
// it IN PLACE, so a row write is amortized O(1) in the table's size — unlike
// `mapPut`, which shares persistent HAMT nodes and answers a NEW value. That difference
// is the reason this primitive exists, and the reason a table is NOT a BL map
// and has no alias to one: `is-map` is false for a handle, and `mapPut` never
// sees one.
//
// The handle is a HOST object. A BL program can only obtain one from
// `table-new`, so BL data cannot forge one, and it records the runtime that
// minted it, so a leaf called on ANOTHER runtime refuses it. That is the whole
// of the host's policy. Ownership, heir, access mode, naming, lifecycle and
// atomic counters are NOT decided here — the host does not know what a process
// is. A BL table service owns all of that and calls these leaves.
//
// A row is `[key, value]` filed under the canonical `hashKey(key)` — exactly
// how `BMap` files an entry — so structural equality and distinctness are the
// target's existing ones. Key and value are held BY REFERENCE: typed BL values
// round-trip without being copied.
//
// Memory is bounded the way the prototype bounds its browser inbox: loud
// refusal, never silent growth.

const TABLE_MAX_ENTRIES = 1 << 20;      // rows in one table
const TABLE_MAX_KEY = 1 << 16;          // characters in one canonical key
const TABLE_MAX_PER_RUNTIME = 1 << 16;  // live tables in one runtime
let tableHandleCounter = 0;

/** The host's table bounds, as data — a BL service reports them instead of
 *  hard-coding a second copy. */
export const TABLE_LIMITS = Object.freeze({
  entries: TABLE_MAX_ENTRIES, key: TABLE_MAX_KEY, tables: TABLE_MAX_PER_RUNTIME,
});

/** An opaque, non-forgeable handle to one live table, bound to the runtime that
 *  minted it. It is a host object, so no BL value can pretend to be one. */
export class TableHandle {
  constructor(runtimeId, m) {
    this.__table = true;   // a marker for diagnostics, never a validity check
    this.rt = runtimeId;   // the runtime identity this handle belongs to
    this.id = (tableHandleCounter += 1);
    this.m = m;
    this.dead = false;
  }
}
export function isTable(x) { return x instanceof TableHandle; }

/** Validate a handle for a leaf called on `rt`: right kind, right runtime,
 *  still alive. The errors name the reason so a BL caller can report it. */
function tableCheck(rt, h) {
  if (!(h instanceof TableHandle)) throw new Error("not a table handle: " + describe(h));
  if (h.rt !== rt.runtimeId) throw new Error("table handle belongs to another runtime");
  if (h.dead) throw new Error("table has been destroyed");
  return h;
}

/** Canonical key, with the one key-size bound. */
function tableKey(k) {
  const kk = hashKey(k);
  if (kk.length > TABLE_MAX_KEY) throw new Error("table key is too large");
  return kk;
}

export function tableNew(rt) {
  const live = (rt.tables ||= new Set());
  if (live.size >= TABLE_MAX_PER_RUNTIME) throw new Error("too many live tables in this runtime");
  const h = new TableHandle(rt.runtimeId, new Map());
  live.add(h);
  return h;
}
/** The stored `[key, value]` row as a BL tuple, or nil when absent. The key in
 *  the answer is the STORED key, not the probe — BEAM `:ets.lookup/2` does the
 *  same, and nil stays distinguishable from a row holding nil. */
export function tableLookup(rt, h, k) {
  tableCheck(rt, h);
  const row = h.m.get(tableKey(k));
  return row === undefined ? null : tup([row[0], row[1]]);
}
export function tableInsert(rt, h, k, v) {
  tableCheck(rt, h);
  const kk = tableKey(k);
  if (!h.m.has(kk) && h.m.size >= TABLE_MAX_ENTRIES) throw new Error("table is full");
  h.m.set(kk, [k, v]);
  return true;
}
/** Answer whether a row was removed. Deleting an absent key is a no-op. */
export function tableDelete(rt, h, k) {
  tableCheck(rt, h);
  return h.m.delete(tableKey(k));
}
export function tableSize(rt, h) { tableCheck(rt, h); return h.m.size; }
export function tableDestroy(rt, h) {
  tableCheck(rt, h);
  h.dead = true;
  h.m.clear();
  h.m = null;
  if (rt.tables) rt.tables.delete(h);
  return true;
}
/** A stable COPY of the rows (insertion order), for BL iteration: a later write
 *  does not change it, and the table is not held after the call returns. */
export function tableSnapshot(rt, h) {
  tableCheck(rt, h);
  const rows = [];
  for (const row of h.m.values()) rows.push(tup([row[0], row[1]]));
  return listFromArray(rows);
}

// ── leaf predicates / conversions ────────────────────────────────────────────

export function isNil(x) { return x === null || x === undefined; }
export function isInt(x) { return typeof x === "bigint" || (typeof x === "number" && Number.isInteger(x)); }
export function isFloat(x) { return x instanceof Flt || (typeof x === "number" && !Number.isInteger(x)); }
export function isNum(x) { return typeof x === "number" || typeof x === "bigint" || x instanceof Flt || x instanceof Dec; }
export function isStr(x) { return typeof x === "string"; }
export function isBool(x) { return x === true || x === false; }
export function isFn(x) { return !!x && V.callableTarget(x).__blfn === true; }
export const identical = V.keyEq;
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

/** The order BEAM enumerates a small map's keys (and a set's elements) in:
 *  Erlang's internal flatmap key order, derived from observation, not from
 *  `rt-compare` (BL's total order, a different relation — `compare` is
 *  numeric across int/float and alphabetical across atoms).
 *
 *  Kinds: number < atom < tuple < map < empty-list < list < string. Within
 *  numbers, ALL integers sort before ALL floats, each numerically — a flatmap
 *  orders by representation, so `-1` precedes `-2.5`. Within atoms, BEAM
 *  orders by atom-table index (creation order), which a JavaScript target
 *  cannot reproduce; this uses `false < true < nil < keywords by name`, a
 *  documented divergence (parity avoids maps whose order depends on it). This
 *  is the ONE ordering maps and sets enumerate in: `mapKeys` and `setToList`. */
export function keyOrder(a, b) {
  const ra = keyRank(a), rb = keyRank(b);
  if (ra !== rb) return ra < rb ? -1 : 1;
  switch (ra) {
    case 0: {                                     // number: ints before floats
      const ai = isInt(a), bi = isInt(b);
      if (ai !== bi) return ai ? -1 : 1;
      if (a instanceof Dec || b instanceof Dec) return V.compare(canonicalNumber(a), canonicalNumber(b));
      const av = a instanceof Flt ? a.v : a, bv = b instanceof Flt ? b.v : b;
      return av < bv ? -1 : av > bv ? 1 : 0;
    }
    case 1: {                                     // atom
      const fa = atomRank(a), fb = atomRank(b);
      if (fa !== fb) return fa < fb ? -1 : 1;
      if (isKw(a) && isKw(b)) return strCmp(kwName(a), kwName(b));
      return 0;
    }
    case 2: return cmpItems(a.items, b.items);    // tuple
    case 3: return cmpMapish(a, b);               // map / vector / struct / set
    case 5: return cmpCons(a, b);                 // non-empty list
    case 6: return strCmp(a, b);                  // string
    default: return 0;
  }
}
function keyRank(x) {
  if (isNum(x)) return 0;
  if (isKw(x) || x === null || x === true || x === false) return 1;
  if (x instanceof T) return 2;
  if (x instanceof BMap || x instanceof BSet || isVec(x) || isStruct(x)) return 3;
  if (x === ENIL) return 4;
  if (x instanceof Cons) return 5;
  if (typeof x === "string") return 6;
  return 7;
}
function atomRank(x) {
  if (x === false) return 0;
  if (x === true) return 1;
  if (x === null || x === undefined) return 2;
  return 3;
}
function cmpItems(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) { const c = keyOrder(a[i], b[i]); if (c !== 0) return c; }
  return a.length === b.length ? 0 : a.length < b.length ? -1 : 1;
}
function cmpCons(a, b) {
  for (;;) {
    const c = keyOrder(a.h, b.h);
    if (c !== 0) return c;
    if (a.t === ENIL || b.t === ENIL) return a.t === b.t ? 0 : a.t === ENIL ? -1 : 1;
    if (!(a.t instanceof Cons) || !(b.t instanceof Cons)) return 0;
    a = a.t; b = b.t;
  }
}
function cmpMapish(a, b) {
  const ea = mapishEntries(a), eb = mapishEntries(b);
  if (ea.length !== eb.length) return ea.length < eb.length ? -1 : 1;
  for (let i = 0; i < ea.length; i++) {
    const c = keyOrder(ea[i][0], eb[i][0]);
    if (c !== 0) return c;
    const c2 = keyOrder(ea[i][1], eb[i][1]);
    if (c2 !== 0) return c2;
  }
  return 0;
}
function mapishEntries(x) {
  if (x instanceof BSet) return setElements(x).map(e => [e, null]);
  if (isVec(x)) return vecItems(x).map((e, i) => [i, e]);
  if (x instanceof BMap) return [...x].sort((p, q) => keyOrder(p[0], q[0]));
  return Object.keys(x).filter(k => k !== "__struct").sort().map(k => [x[k], null]);
}
export function hashKey(x) {
  if (x === null || x === undefined) return "nil";
  if (x === true) return "b:1";
  if (x === false) return "b:0";
  if (x instanceof Flt) return "f:" + x.v;
  if (x instanceof Dec) return "d:" + x.u + ":" + x.s;
  const t = typeof x;
  if (t === "number") return "n:" + (Object.is(x, -0) ? 0 : x);
  // A BigInt is an exact integer beyond the safe range. Its canonical form is
  // its decimal digits, so a safe integer and the BigInt of equal value would
  // share a key — they cannot both exist, because a result that fits the safe
  // range normalizes back to a Number (see `arith`).
  if (t === "bigint") return "n:" + x;
  if (t === "string") return "s" + x.length + ":" + x;
  if (x instanceof KW) return "k" + kwName(x).length + ":" + kwName(x);
  if (x === ENIL) return "l:()";
  if (x instanceof Cons) return enc("l", [hashKey(x.h), hashKey(x.t)]);
  if (x instanceof T) return enc("t", x.items.map(hashKey));
  if (isVec(x)) return enc("v", vecItems(x).map(hashKey));
  if (x instanceof BMap) {
    const entries = [...x].map(([k,v]) => [hashKey(k), hashKey(v)]).sort((a,b) => strCmp(a[0],b[0]));
    return enc("m", entries.flat());
  }
  if (x instanceof BSet) return enc("s", [...x].map(hashKey).sort());
  if (typeof x === "function" || x.__blfn) return "f:" + opaqueId(x);
  return "o:" + opaqueId(x);
}
const opaqueIds = new WeakMap();
let idCounter = 0;
function opaqueId(value) {
  let id = opaqueIds.get(value);
  if (id === undefined) { id = ++idCounter; opaqueIds.set(value,id); }
  return id;
}
// Runtime identities are ALLOCATED, never read from a clock: two runtimes in the
// same process get disjoint ids even if they are created in the same instant,
// so `[:pid runtime serial]` can never name a process in another runtime. Thin
// identity allocation only — no actor policy.
let runtimeIdCounter = 0;

// Language equality is owned by the canonical runtime, including numeric,
// sequential-family, improper-list and collection rules. The injective codec
// above is only for bounded mutable host-table keys.
export const eq = V.eqv;

function strCmp(a, b) {
  if (typeof a !== "string" || typeof b !== "string")
    throw new Error("string order needs two strings, got " + describe(a) + " and " + describe(b));
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n;) {
    const ca = a.codePointAt(i), cb = b.codePointAt(i);
    if (ca !== cb) return ca < cb ? -1 : 1;
    i += ca > 0xffff ? 2 : 1;
  }
  return a.length === b.length ? 0 : a.length < b.length ? -1 : 1;
}

export function lt(a, b) {
  if (isNum(a) && isNum(b)) return V.lt(canonicalNumber(a),canonicalNumber(b));
  if (typeof a === "string" && typeof b === "string") return strCmp(a, b) < 0;
  throw new Error("`<` needs two numbers or two strings, got " + describe(a) + " and " + describe(b));
}

export function describe(x) {
  if (x instanceof Flt || x instanceof Dec) return V.printStr(x);
  if (x === null || x === undefined) return "nil";
  if (x instanceof KW) return ":" + kwName(x);
  if (x instanceof Cons || x === ENIL) { try { return "(" + listToArray(x).map(describe).join(" ") + ")"; } catch (_) { return "(improper list)"; } }
  if (x instanceof T) return "{" + x.items.map(describe).join(", ") + "}";
  if (isVec(x)) return "[" + vecItems(x).map(describe).join(" ") + "]";
  if (x instanceof BSet) return "#{" + setElements(x).map(describe).join(" ") + "}";
  if (isStruct(x)) return "#" + structMod(x) + "{}";
  // `mapKeys` answers a BL LIST (it is the language's own `keys`), so it has to
  // be walked with `listToArray` before JavaScript's `.map` sees an array.
  if (x instanceof BMap) return "{" + listToArray(mapKeys(x)).map(k => describe(k) + " " + describe(mapGet(x, k))).join(", ") + "}";
  if (typeof x === "string") return JSON.stringify(x);
  if (typeof x === "function") return "#<fn>";
  if (isFn(x)) return "#<fn " + x.name + ">";
  if (x instanceof TableHandle) return "#<table " + x.id + ">";
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
  if (x instanceof KW) return kwName(x);
  if (isNum(x)) return x instanceof Flt ? String(x.v) : x instanceof Dec ? x.plain() : String(x);
  return describe(x);
}

// ── arithmetic ───────────────────────────────────────────────────────────────

// Canonical BL arithmetic owns promotion, float identity and exact decimals.
// Raw fractional JS numbers are normalized only when entering a BL numeric op.
function canonicalNumber(x) { return typeof x === "number" && !Number.isSafeInteger(x) ? V.flt(x) : x; }
const numericOps = {add:V.add, sub:V.sub, mul:V.mul, div:V.div, quot:V.quot, rem:V.rem, mod:V.mod};
export function arith(op, a, b) {
  if (Object.hasOwn(numericOps,op)) return numericOps[op](canonicalNumber(a),canonicalNumber(b));
  switch(op) {
    case "lt": return lt(a,b);
    case "gt": return lt(b,a);
    case "le": return !lt(b,a);
    case "ge": return !lt(a,b);
    case "num_eq": return eq(a,b);
    default: throw new Error("unknown arithmetic op " + op);
  }
}

// ── control steps ────────────────────────────────────────────────────────────
//
// A step is a HOST object, never a BL value: a BL map is a `BMap`, a BL tuple
// is a `T`, a record is a canonical map with a `:__struct__` tag. A user value that "looks like" a step
// therefore stays data, as the design requires.

export class Step {
  constructor(k, extra) { this.__step = true; this.k = k; if (extra) Object.assign(this, extra); }
}
export function isStep(x) { return !!x && x.__step === true; }
// ── raised values ────────────────────────────────────────────────────────────
//
// A JavaScript `throw` carries an ENVELOPE, never a bare BL value. A BL value
// has no class, and the compiler-generated catch handler has to read the class
// (`:error` | `:throw` | `:exit`), the reason and the raw stacktrace apart
// without guessing. Like a Step, an envelope is a HOST object, so no BL program
// can forge one, and a BL value that merely looks like one stays data.
//
// `trace` is the raw stacktrace in its SHAPE, not its content: the compiler
// emits `:erlang/element(2, __STACKTRACE__)` to reach the frame list, so the
// envelope carries a 2-tuple and `element/2` on it answers a list. The frame
// list here is EMPTY — this target has no BEAM stack, and inventing frames would
// be a worse lie than reporting none.

// ── logical source frames ────────────────────────────────────────────────────
//
// The target's STACKTRACE SHAPE. `runTurn` keeps one entry per live generator
// frame — the CALL-SITE metadata of the call that created it, emitted from the
// ANF's own source span — so every frame names the BL source it was entered
// from. A frame is a BL map with EXPLICIT keys, so an unknown position is a
// null field, never a missing one: {:file :line :col :fn :arity :call}.
// `:fn`/`:arity` are the function the call was written IN (the caller) and
// `:call` is :direct | :dynamic | :tail. Nothing here is scraped out of a
// JavaScript Error, and no BEAM frame is ever fabricated. The list is capped at
// MAX_TRACE innermost frames, and a tail call REPLACES its frame's entry, so a
// tail loop stores O(depth), not O(iterations).
const MAX_TRACE = 64;
let liveFrames = null;         // the generator stack of the turn in progress

function frameValue(src) {
  return bmap([
    [kw("file"), src && typeof src.file === "string" ? src.file : null],
    [kw("line"), src && Number.isInteger(src.line) ? src.line : null],
    [kw("col"), src && Number.isInteger(src.col) ? src.col : null],
    [kw("fn"), src && typeof src.fn === "string" ? src.fn : null],
    [kw("arity"), src && Number.isInteger(src.arity) ? src.arity : null],
    [kw("call"), src && typeof src.call === "string" ? kw(src.call) : null],
  ]);
}

/** The logical stack of `frames`, INNERMOST first, capped at MAX_TRACE.
 *  Shared by `runTurn` and the `host/logical-stack` leaf so the two agree. */
export function frameValues(frames) {
  if (!frames) return ENIL;
  const srcs = frames.__srcs || [];
  const out = [];
  for (let i = frames.length - 1; i >= 0 && out.length < MAX_TRACE; i--) out.push(frameValue(srcs[i]));
  return listFromArray(out);
}

/** The raw stacktrace a NEW raise carries: a 2-tuple shaped so the compiler's
 *  `:erlang/element(2, __STACKTRACE__)` read answers the frame list. */
function capturedTrace() {
  return new T([ENIL, liveFrames ? frameValues(liveFrames) : ENIL]);
}

/** The frame list an envelope already carries, or null when it carries none. */
function raisedFrameList(x) {
  if (!isRaise(x) || !isTup(x.trace)) return null;
  const fl = x.trace.items[1];
  return isCons(fl) ? fl : null;
}

/** The logical stack of the running BL code, as a BL list (innermost first).
 *  Read-only introspection: it is the same list a new raise captures. */
export function logicalStack() { return liveFrames ? frameValues(liveFrames) : ENIL; }

export class BLRaise {
  constructor(kind, reason, trace) {
    this.__blraise = true;
    this.kind = kind;                        // a KW: :error | :throw | :exit
    this.reason = reason;                    // a BL value
    // An EXPLICIT trace is a re-raise carrying its ORIGINAL __STACKTRACE__, and
    // is preserved verbatim. A raise with NO trace captures the machine's
    // logical stack ONCE, here, at the moment of the throw: a catch in the SAME
    // frame can then read it, and a later finalizer throw — a NEW envelope —
    // captures its own stack and supersedes whatever was pending.
    this.trace = isTup(trace) ? trace : capturedTrace();
  }
}
export function isRaise(x) { return !!x && x.__blraise === true; }
export function emptyTrace() { return new T([ENIL, ENIL]); }
/** The three fields of a raise, as NAMED exports: the emitter emits
 *  `H.exKind(...)` / `H.exReason(...)` / `H.exTrace(...)` directly into a
 *  generated catch block, and the `host/…` leaves below are the same functions
 *  under their registry names. A raw JavaScript throw has no class, so it reads
 *  as `:error` with its message as the reason. */
export function exKind(x) { return isRaise(x) ? x.kind : kw("error"); }
export function exReason(x) { return isRaise(x) ? x.reason : rawReason(x); }
export function exTrace(x) { return isRaise(x) ? x.trace : emptyTrace(); }

/** The reason of a NON-envelope throw (a raw JS `Error` from a host leaf or an
 *  internal check) as the plain string a BL program can carry. */
function rawReason(x) {
  if (typeof x === "string") return x;
  if (x && typeof x.message === "string") return x.message;
  return String(x);
}

/** The message an uncaught raise contributes to a process error. A JS error
 *  keeps its stack (the prototype's one real diagnostic); an envelope prefers
 *  the reason's own `:message` over its printed form. */
export function exceptionText(e) {
  if (!isRaise(e)) return String((e && e.stack) || e);
  const kind = isKw(e.kind) ? kwName(e.kind) : String(e.kind);
  return "(" + kind + ") " + describeReason(e.reason);
}
function describeReason(reason) {
  try {
    if (reason instanceof BMap) {
      const m = mapGet(reason, kw("message"));
      if (typeof m === "string") return m;
    }
    return describe(reason);
  } catch (_) {
    return "<unprintable reason>";
  }
}

// ── the machine ──────────────────────────────────────────────────────────────

/** Resolve a callee to a generator factory, or null when it is a native fn. */
export function resolveCallee(f, args) {
  f = V.callableTarget(f);
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
  const selected = V.selectCallable(f, args);
  if (selected) {
    const factory = resolveCallee(selected.callee, selected.args);
    // Keep frame arms direct, including tail recursion. Only packing a rest
    // argument needs an adapter; there is no extra continuation to accumulate.
    if (factory) return selected.args === args ? factory : (rt, _args) => factory(rt, selected.args);
    // A linked native arm uses an ordinary call step. Keep its continuation
    // while a host control leaf parks, even when this is the root frame.
    return function* (rt, _args) {
      return yield new Step("call", {f: selected.callee, args: selected.args});
    };
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
  if (isSet(f)) return setHas(f, args[0]) ? args[0] : null;
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
export function runTurn(rt, frames, budget, hardLimit = false, rawResult = false) {
  let steps = 0;
  // Callback completion stays inside the host. Build a BL result map only
  // when returning to the BL scheduler; execution remains this same machine.
  const resultFor = (status, frames, extra) => rawResult ? {status, ...extra} : mkResult(status, frames, extra);
  // The critical depth this turn entered with. A turn that dies restores it, so
  // a raise that unwinds past a `critical-enter` cannot strand the depth.
  const cd0 = rt.criticalDepth || 0;
  // The pending completion is MACHINE STATE, not a local: a slice can end
  // exactly between "a callee finished" and "its caller is resumed" — or while
  // a thrown value is still climbing the stack — and a completion dropped there
  // would silently become nil. It rides on the frame stack (the one object a
  // suspended process already is).
  let pending = frames.__pending === undefined ? { t: "value", v: null } : frames.__pending;
  // Per-frame critical depth at entry. A frame that unwinds — normally OR by a
  // throw — restores the depth it started with, so an unpaired
  // `critical-enter` inside the frame cannot defer every future slice forever.
  // Kept in step with `frames` at every push, pop and tail replacement.
  let cds = frames.__cds;
  if (!Array.isArray(cds)) { cds = []; frames.__cds = cds; }
  // Call-site metadata, one entry per frame, in step with `frames`. It rides on
  // the frame stack for the same reason `cds` does: a slice can end with the
  // stack suspended, and the metadata must survive with it.
  let srcs = frames.__srcs;
  if (!Array.isArray(srcs)) { srcs = []; frames.__srcs = srcs; }
  // `liveFrames` is the module-level pointer a NEW raise reads to capture its
  // own trace. It is saved so a nested turn restores its caller's stack, and it
  // is refreshed at every resume below.
  const prevLive = liveFrames;
  let capturedFrames = null;
  const capture = () => { if (capturedFrames === null) capturedFrames = frameValues(frames); };
  const finish = (r) => { frames.__pending = pending; frames.__cds = cds; frames.__srcs = srcs; liveFrames = prevLive; return r; };
  // A turn that dies reports the WHOLE thrown value, not only its text: the
  // class and the reason are what `runtime.bl` turns into a process's exit
  // reason, and it is the only exit-signal input the host supplies. What that
  // reason then means — links, monitors, propagation, trap_exit — is BL policy
  // and is not even visible from here.
  const die = (thrown) => {
    rt.criticalDepth = cd0;
    pending = { t: "value", v: null };
    // A raise that already carries a raw trace (a re-raise, a finalizer throw)
    // keeps IT — that is the preserved location. A raw JavaScript error has
    // none, so the stack captured at the first escaping throw is used.
    const framesOut = raisedFrameList(thrown) || capturedFrames || frameValues(frames);
    return finish(resultFor("error", frames, {
      exception: [thrown],
      message: exceptionText(thrown),
      kind: exKind(thrown),
      reason: exReason(thrown),
      frames: framesOut,
    }));
  };
  while (true) {
    while (cds.length < frames.length) cds.push(cd0);
    while (srcs.length < frames.length) srcs.push(null);
    if (frames.length > (rt.maxFrames || 0)) rt.maxFrames = frames.length;
    // A bounded slice normally ends here. While a critical section is open the
    // boundary is DEFERRED: splitting a read-modify-write of `rt.state` across
    // a slice would let another process mutate the same root underneath it.
    if (steps >= budget && (hardLimit || (rt.criticalDepth || 0) === 0)) return finish(resultFor("yield", frames, {}));
    if (frames.length === 0) {
      if (pending.t === "throw") return die(pending.v);
      return finish(resultFor("done", frames, { value: pending.v }));
    }
    const g = frames[frames.length - 1];
    let res;
    try {
      // The logical stack must be current at every resume: a new raise reads it
      // to capture its trace, and `host/logical-stack` reads it to answer the
      // stack of the running BL code.
      liveFrames = frames;
      // A pending THROW is delivered at the frame's suspension point, so a
      // compiled `try` — a real JavaScript try/catch inside the generator —
      // catches it exactly where the language says it should.
      const deliveringThrow = pending.t === "throw";
      res = deliveringThrow ? g.throw(pending.v) : g.next(pending.v);
      // A handled error is no longer the active exception. A later raw host
      // failure must capture its own site, not reuse that earlier snapshot.
      if (deliveringThrow) capturedFrames = null;
    } catch (e) {
      // The frame did not catch it, so its generator is closed: capture the
      // logical stack the FIRST time a throw ESCAPES a generator, pop the
      // frame, and hand the SAME value to its caller, where an enclosing `try`
      // may yet catch it.
      if (pending.t === "throw" && e !== pending.v) capturedFrames = null;
      capture();
      pending = { t: "throw", v: e };
      frames.pop();
      rt.criticalDepth = cds.length > 0 ? cds.pop() : cd0;
      srcs.pop();
      steps++;
      continue;
    }
    pending = { t: "value", v: null };
    steps++;
    if (res.done) {
      frames.pop();
      rt.criticalDepth = cds.length > 0 ? cds.pop() : cd0;
      srcs.pop();
      pending = { t: "value", v: res.value };
      continue;
    }
    let step = res.value;
    while (true) {
      if (!isStep(step)) { pending = { t: "value", v: step }; break; }
      if (step.k === "park") return finish(resultFor("park", frames, {}));
      if (step.k === "host-wait") return finish(resultFor("host-wait", frames, { ms: step.ms, inputEnabled: step.inputEnabled }));
      if (step.k === "call" || step.k === "tail") {
        // A failure in resolution or in a native leaf is a THROW TO THE CALLER,
        // not an instant process death: the frame above this step is the one
        // that asked for the call, and its `try` may be waiting for it.
        const callerSrc = srcs[srcs.length - 1];
        // A generated runtime helper is infrastructure, not the user's raise
        // site. Preserve the caller's BL source through its tail calls; the
        // compiler marks those sites explicitly rather than teaching this
        // machine any module or path names.
        const callSrc = step.src && step.src.internal && callerSrc ? callerSrc : (step.src || null);
        // A native leaf (or resolution) can throw without pushing a callee.
        // Point the live frame at THIS call during invocation, then restore
        // the caller's entry site on successful non-tail completion.
        if (callSrc) srcs[srcs.length - 1] = callSrc;
        let factory = null;
        try { factory = resolveCallee(step.f, step.args); }
        catch (e) { capture(); pending = { t: "throw", v: e }; break; }
        if (factory) {
          let ng;
          try { ng = factory(rt, step.args); }
          catch (e) { capture(); pending = { t: "throw", v: e }; break; }
          if (step.k === "tail") {
            frames[frames.length - 1] = ng;
            cds[cds.length - 1] = rt.criticalDepth || 0;
            srcs[srcs.length - 1] = callSrc;
          } else {
            srcs[srcs.length - 1] = callerSrc;
            frames.push(ng);
            cds.push(rt.criticalDepth || 0);
            srcs.push(callSrc);
          }
          break;
        }
        let v;
        try { v = invokeNative(rt, step.f, step.args); }
        catch (e) { capture(); pending = { t: "throw", v: e }; break; }
        steps++;
        if (step.k === "tail") {
          frames.pop();
          rt.criticalDepth = cds.length > 0 ? cds.pop() : cd0;
          srcs.pop();
        } else {
          srcs[srcs.length - 1] = callerSrc;
        }
        if (frames.length === 0) { pending = { t: "value", v: isStep(v) ? null : v }; break; }
        if (isStep(v)) { step = v; continue; }
        pending = { t: "value", v }; break;
      }
      pending = { t: "throw", v: new Error("unknown control step " + step.k) }; break;
    }
  }
}

function mkResult(status, frames, extra) {
  return bmap([
    [kw("status"), kw(status)],
    [kw("frames"), frames],
    [kw("value"), extra.value === undefined ? null : extra.value],
    [kw("ms"), extra.ms === undefined ? null : extra.ms],
    [kw("input-enabled"), extra.inputEnabled === true],
    [kw("exception"), extra.exception === undefined ? null : extra.exception],
    [kw("message"), extra.message === undefined ? null : extra.message],
    // The uncaught value that ended the turn, as its class and its reason. nil
    // for every status a raise did not produce.
    [kw("kind"), extra.kind === undefined ? null : extra.kind],
    [kw("reason"), extra.reason === undefined ? null : extra.reason],
    // The logical source frames of an uncaught raise (innermost first), nil for
    // every status a raise did not produce. BL policy renders them; the host
    // only reports what it saw.
    [kw("frames"), extra.frames === undefined ? null : extra.frames],
  ]);
}
export function resultStatus(r) { return kwName(mapGet(r, kw("status"))); }
export function resultValue(r) { return mapGet(r, kw("value")); }
export function resultMs(r) { return mapGet(r, kw("ms")); }
export function resultInputEnabled(r) { return mapGet(r, kw("input-enabled")) === true; }
export function resultMessage(r) { return mapGet(r, kw("message")); }

// ── runtime + registry ───────────────────────────────────────────────────────

// The browser adapter may receive a message before the generated module has
// created its runtime. Keep it ordered; only the BL scheduler chooses its sink.
let activeRuntime = null;
const earlyInputs = [];

export function enqueueInput(topic, payload) {
  if (typeof topic !== "string" || !/^[a-z][a-z0-9-]{0,31}$/.test(topic) ||
      typeof payload !== "string" || payload.length > 4096)
    throw new Error("browser input requires an allowed topic and a string of at most 4096 characters");
  const queue = activeRuntime ? activeRuntime.inbox : earlyInputs;
  if (queue.length >= 1024) throw new Error("browser input queue is full");
  queue.push(vec([kw("browser"), kw(topic), payload]));
  if (activeRuntime && activeRuntime.inputWake) activeRuntime.inputWake();
}

// Typed data transport: delivers `[:browser :<topic> value]` where `value` is
// FINITE CLOSED DATA — keywords, bounded strings, safe integers, optionally
// booleans and nil, vectors, and maps with keyword keys. No function, host
// handle, cycle or shared node crosses. It cannot grant authority: the BL
// receiver still decides what the value means. Bounds are the caller's:
// `nodes` (total values), `depth`, `text` (max string length), `negative`
// (admit negative integers), `scalars` (admit booleans and nil).
export function enqueueData(topic, value, { nodes = 4096, depth: maxDepth = 16, text = 4096,
                                            negative = true, scalars = true, root = null } = {}) {
  if (typeof topic !== "string" || !/^[a-z][a-z0-9-]{0,31}$/.test(topic))
    throw new Error("typed input requires an allowed topic");
  let remaining = nodes;
  const seen = new WeakSet();
  function check(v, depth) {
    if (--remaining < 0 || depth > maxDepth) throw new Error("typed input exceeds transport bounds");
    if (isKw(v)) return;
    if (typeof v === "string" && v.length <= text) return;
    if (Number.isSafeInteger(v) && (negative || v >= 0)) return;
    // an exact integer beyond 2^53 (a `:exact` wire value), bounded in size
    if (typeof v === "bigint" && (negative || v >= 0n) && v.toString().length <= 101) return;
    if (scalars && (v === true || v === false || v === null)) return;
    if (v && typeof v === "object") {
      if (seen.has(v)) throw new Error("cyclic or reused typed input");
      seen.add(v);
      if (isVec(v)) {
        for (const item of vecItems(v)) check(item, depth + 1);
        return;
      }
      if (isBMap(v)) {
        for (const key of listToArray(mapKeys(v))) {
          if (!isKw(key)) throw new Error("typed map requires keyword keys");
          check(key, depth + 1);
          check(mapGet(v, key), depth + 1);
        }
        return;
      }
    }
    throw new Error("typed input requires closed data values");
  }
  if (root === "vector" && !isVec(value)) throw new Error("typed input requires a vector root");
  check(value, 0);
  const queue = activeRuntime ? activeRuntime.inbox : earlyInputs;
  if (queue.length >= 1024) throw new Error("browser input queue is full");
  queue.push(vec([kw("browser"), kw(topic), value]));
  if (activeRuntime && activeRuntime.inputWake) activeRuntime.inputWake();
}

// The editable quoted-view Worker's form: the tightest profile of the same
// transport (96 nodes, depth 8, short strings, no negatives or scalars).
export function enqueueQuotedForm(form) {
  try {
    enqueueData("preview", form, { nodes: 96, depth: 8, text: 96, negative: false,
                                   scalars: false, root: "vector" });
  } catch (error) {
    throw new Error(error.message.replace("typed input", "quoted form").replace("typed map", "quoted map"));
  }
}

// The structured output sink: `(host/emit :topic value)` hands a BL value to
// the embedding transport (a Worker, an HTTP bridge). One sink per process;
// the transport decides nothing about the value beyond encoding it, and a BL
// program that emits with no sink installed fails loudly instead of dropping.
let emitSink = null;
export function setEmitter(fn) {
  if (fn !== null && typeof fn !== "function") throw new Error("emitter must be a function or null");
  emitSink = fn;
}

export function waitForInput(rt, ms, inputEnabled = true) {
  // Early input is only actionable after BL has selected a living sink. When
  // no sink exists, a timed receive must sleep until its deadline, not spin on
  // an undrainable host queue and starve browser tasks.
  if (inputEnabled && rt.inbox.length > 0) return Promise.resolve();
  return new Promise(resolve => {
    let timer = null;
    const wake = () => {
      if (rt.inputWake === wake) rt.inputWake = null;
      if (timer !== null) clearTimeout(timer);
      resolve();
    };
    if (inputEnabled) rt.inputWake = wake;
    // Timer APIs truncate fractional milliseconds. Round UP so a timed BL
    // receive cannot wake before its monotonic deadline and immediately sleep
    // again for the missing fraction (the scheduler still owns the deadline).
    if (ms !== null) timer = setTimeout(wake, Math.ceil(Math.max(0, numberValue(ms))));
    // Recheck only when BL has enabled ingress: no event is lost between the
    // pump and waiter registration, while pre-registration input remains queued.
    if (inputEnabled && rt.inbox.length > 0) wake();
  });
}

export function newRuntime({input = true} = {}) {
  const runtimeId = (runtimeIdCounter += 1);
  const rt = {
    globals: new Map(),
    // The tables this runtime minted. A handle is valid only in the runtime
    // that made it, so this set is PER RUNTIME; the host owns no table identity
    // beyond it.
    tables: new Set(),
    // The runtime's own identity, ALLOCATED here (never a clock reading): two
    // runtimes in one process get disjoint ids even when created in the same
    // instant, so a pid/ref can never name a process in another runtime. It is
    // handed to the BL runtime as the one field of the initial retained state
    // it starts from; thin identity allocation only, no actor policy.
    runtimeId,
    state: bmap([[kw("runtime"), runtimeId]]),
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
    inbox: input ? earlyInputs.splice(0) : [],
    inputWake: null,
    out: (s) => { console.log(s); },
  };
  if (input) activeRuntime = rt;
  return rt;
}

export function def(rt, key, v) { rt.globals.set(key, v); return v; }
export function alias(rt, key, target) { return ref(rt, splitNs(target), splitName(target)); }
function splitNs(k) { return k.slice(0, k.lastIndexOf("/")); }
function splitName(k) { return k.slice(k.lastIndexOf("/") + 1); }
export function defAlias(rt, key, targetKey) {
  const v = rt.globals.get(targetKey);
  if (!rt.globals.has(targetKey)) throw new Error("alias target not defined: " + targetKey);
  rt.globals.set(key, v);
  return v;
}

/** Resolve a global, with the same fallback beam-lisp's `Env.fetch!` has:
 *  a name bound in the current namespace, else the same name in `core`. */
export function ref(rt, ns, name) {
  const key = ns + "/" + name;
  if (rt.globals.has(key)) return rt.globals.get(key);
  if (ns !== "core") {
    const fallback = "core/" + name;
    if (rt.globals.has(fallback)) return rt.globals.get(fallback);
  }
  throw new Error("unresolved global " + ns + "/" + name);
}

// ── BL function construction ─────────────────────────────────────────────────

// A callable uses the SAME generator machine for actor turns and checked host
// callbacks. Evidence belongs to the compiler, never to authored metadata.
const synchronousCallables = new WeakMap();
export function blFn(name, arities, variadic, rt = null, synchronous = false, entry = null) {
  const fn = function (...args) { return entry ? entry(fn, args) : invokeSynchronous(fn, args); };
  Object.defineProperties(fn, {
    name: {value: name}, __blfn: {value: true},
    arities: {value: arities}, variadic: {value: variadic || null},
  });
  if (rt && synchronous === true) synchronousCallables.set(fn, rt);
  return fn;
}
function callbackRuntime(fn) {
  fn = V.callableTarget(fn);
  if (isFn(fn)) return synchronousCallables.get(fn) || null;
  if (isTup(fn) && fn.items.length === 3 && fn.items[0] === kw("$blfn")) {
    let rt = null;
    const accept = f => {
      const owner = callbackRuntime(f);
      if (!owner || (rt && owner !== rt)) return false;
      rt = owner; return true;
    };
    for (const key of listToArray(mapKeys(fn.items[1])))
      if (!accept(mapGet(fn.items[1], key))) return null;
    if (isTup(fn.items[2]) && !accept(tupEl(fn.items[2], 1))) return null;
    return rt;
  }
  return null;
}
export function isSynchronousCallable(fn) { return callbackRuntime(fn) !== null; }
export function invokeSynchronous(fn, args, budget = 100000) {
  const rt = callbackRuntime(fn);
  if (!rt) throw new TypeError("JS interop: callback is not proven non-suspending; use an actor event entrypoint");
  return invokeImmediate(fn, args, rt, budget);
}
// Host result boundaries drive the same frame machine. Unlike the explicitly
// proven callback API, ordinary module entries may contain dynamic callees:
// actual suspension is refused, never relabelled as compiler evidence.
export function invokeImmediate(fn, args, rt, budget = 100000) {
  const factory = resolveCallee(fn, args);
  const depth = rt.criticalDepth || 0;
  try {
    const frames = [factory(rt, args)];
    const result = runTurn(rt, frames, budget, true, true);
    const status = result.status;
    if (status === "done") return result.value;
    if (status === "error") throw result.exception[0];
    const error = new Error("JS interop: synchronous callback exceeded its turn budget or attempted suspension");
    // Inject cancellation at the actual suspension point so ordinary finally
    // blocks can release resources. Cleanup gets a bounded reserve of its own;
    // a callback that catches cancellation cannot retain a continuation.
    frames.__pending = {t: "throw", v: error};
    const cleanup = runTurn(rt, frames, Math.max(100, Math.min(budget, 10000)), true, true);
    if (cleanup.status === "error") throw cleanup.exception[0];
    throw error;
  } finally { rt.criticalDepth = depth; }
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
  "set-from-list": setFromList,
  "set-put": setPut,
  "set-remove": setRemove,
  "set-has": setHas,
  "set-size": setSize,
  "set-to-list": setToList,
  bmap,
  "empty-map": emptyMap,
  "is-map": isBMap,
  "map-get": mapGet,
  "map-put": mapPut,
  "map-remove": mapRemove,
  "map-keys": mapKeys,
  "map-size": mapSize,
  // A table handle is a value predicate: it reads no runtime state and says
  // only "this is a table handle" — never whether it is alive or owned.
  "is-table": isTable,
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
  // the string's Unicode codepoints (a surrogate pair is ONE), as a BL list —
  // what `unicode:characters_to_list/1` answers on BEAM
  "str-codepoints": (s) => listFromArray(Array.from(s, (c) => c.codePointAt(0))),
  "str-cmp": strCmp,
  // A substring by UTF-16 index, bounds-checked: `subs` on this target.
  "str-slice": (s, from, to) => {
    if (typeof s !== "string" || !Number.isSafeInteger(from) || !Number.isSafeInteger(to) ||
        from < 0 || to < from || to > s.length)
      throw new Error("subs: index out of range");
    return s.slice(from, to);
  },
  truthy,
  // ── reading a raised value ─────────────────────────────────────────────────
  //
  // The THREE fields of a throw, and nothing else: the class, the reason and
  // the raw stacktrace. What a class MEANS — that `:error` normalizes into an
  // exception struct and `:throw` stays itself — is BL policy (runtime.bl
  // `exception-normalize`), not host policy. A raw JavaScript throw (a host
  // leaf's `raise`, an internal check) has no class, so it reads as
  // `:error` with its message as the reason.
  "ex-kind": exKind,
  "ex-reason": exReason,
  "ex-trace": exTrace,
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
  "wait-until": (rt, ms, inputEnabled = false) => new Step("host-wait", { ms: Math.max(0, numberValue(ms)), inputEnabled }),
  "wait-input": () => new Step("host-wait", { ms: null, inputEnabled: true }),
  "input-size": (rt) => rt.inbox.length,
  "take-input": (rt) => vecFromArray(rt.inbox.splice(0)),
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
  emit: (rt, topic, value) => {
    if (!isKw(topic)) throw new Error("host/emit: topic must be a keyword");
    if (emitSink === null) throw new Error("host/emit: no transport installed for :" + kwName(topic));
    emitSink(kwName(topic), value);
    return null;
  },
  raise: (rt, msg) => { throw new Error(toStr(msg)); },
  "record-error": (rt, msg) => { rt.errors = (rt.errors || 0) + 1; rt.lastError = toStr(msg); return rt.errors; },
  // ── mutable tables ─────────────────────────────────────────────────────────
  //
  // The low-level storage operations. The host validates the handle and the
  // bounds and nothing more; which process OWNS a table, who inherits it, what
  // access mode it has and when it dies are BL decisions taken ABOVE these
  // leaves (a BL table service), not here. `table-new` takes no owner, heir or
  // mode — there is no argument for one.
  "table-new": (rt) => tableNew(rt),
  "table-lookup": (rt, h, k) => tableLookup(rt, h, k),
  "table-insert": (rt, h, k, v) => tableInsert(rt, h, k, v),
  "table-delete": (rt, h, k) => tableDelete(rt, h, k),
  "table-size": (rt, h) => tableSize(rt, h),
  "table-destroy": (rt, h) => tableDestroy(rt, h),
  "table-snapshot": (rt, h) => tableSnapshot(rt, h),
  "max-frames": (rt) => rt.maxFrames || 0,
  // The logical source stack of the RUNNING BL code, innermost first: the same
  // bounded list a new raise captures. Read-only, no actor policy.
  "logical-stack": () => logicalStack(),
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
  "==": V.erlEq,
  "/=": (a, b) => !V.erlEq(a, b),
  "=:=": V.keyEq,
  "=/=": (a, b) => !V.keyEq(a, b),
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
  // There are no BEAM pid VALUES on this target (a BL pid is a BL vector; BL
  // asks `rt-pid?`), so this stays false rather than encoding one shape of
  // actor state here. Kept as a bif so a guard does not fail for the wrong
  // reason.
  "is_reference": () => false,
  "is_port": () => false,
  "is_atom": (x) => isKw(x) || x === null || x === true || x === false,
  "is_map": isBMap,
  "tuple_size": tupSize,
  "map_size": mapSize,
  "abs": (x) => x instanceof Flt ? flt(Math.abs(x.v)) : (typeof x === "bigint" ? (x < 0n ? -x : x) : Math.abs(x)),
  "length": (l) => listToArray(l).length,
  "self": () => null,
  // ── raising, and the two halves of an exception's shape ────────────────────
  //
  // `:erlang.raise/3` is what the compiler's catch fallthrough re-raises with,
  // and what `BeamLisp.ExInfo.raise_payload/1` is built on: class, reason and
  // the RAW stacktrace, passed through untouched. `:erlang.throw/1` and
  // `:erlang.exit/1` differ only in the class they carry. An UNCAUGHT raise of
  // either class ends the process's turn, and the class and reason ride back on
  // that turn's result — which is ALL the host does with them. `runtime.bl`
  // reads them back and owns every consequence: a process's exit reason, links,
  // monitors, exit signals, propagation and trap_exit. There is still no host
  // actor policy here, and no BEAM exit-signal semantics are claimed.
  "raise": (kind, reason, trace) => { throw new BLRaise(kind, reason, trace); },
  "throw": (reason) => { throw new BLRaise(kw("throw"), reason, null); },
  "exit": (reason) => { throw new BLRaise(kw("exit"), reason, null); },
  // `element/2` is emitted for a `__STACKTRACE__` read (raw trace → frame list);
  // `is_map_key/2` and `map_get/2` are the halves of the struct test the
  // compiler builds for a typed catch. All three are BEAM bifs, so they fail
  // for BEAM's reasons rather than quietly answering nil.
  "element": (i, t) => {
    if (!isTup(t)) throw new Error(":erlang.element/2 needs a tuple, got " + describe(t));
    if (!Number.isInteger(i) || i < 1 || i > t.items.length)
      throw new Error(":erlang.element/2 index " + i + " is outside a " + t.items.length + "-tuple");
    return t.items[i - 1];
  },
  "is_map_key": (k, m) => mapHas(m, k),
  "map_get": (k, m) => {
    if (!(m instanceof BMap)) throw new Error(":erlang.map_get/2 needs a map, got " + describe(m));
    if (!m.has(k)) throw new Error(":erlang.map_get/2: no key " + describe(k));
    return m.get(k);
  },
};

// ── the driver: hand turns to the host task queue between scheduler slices ───

export async function init(rt) {
  const initFn = rt.globals.get("js/__init");
  if (initFn === undefined) return;
  const frames = [resolveCallee(initFn, [])(rt, [])];
  for (;;) {
    const r = runTurn(rt, frames, rt.budget);
    const st = resultStatus(r);
    if (st === "done") return resultValue(r);
    if (st === "yield") { await yieldToHostTasks(); continue; }
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
      await waitForInput(rt, ms, resultInputEnabled(r));
      continue;
    }
    // A `park` at the scheduler root means the scheduler itself suspended with
    // nothing to resume it: a scheduler bug, not a user program's.
    rt.out("scheduler parked with no resumer");
    if (globalThis.process) globalThis.process.exitCode = 1;
    throw new Error("scheduler parked with no resumer");
  }
}
