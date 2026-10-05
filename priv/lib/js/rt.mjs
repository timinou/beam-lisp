// priv/lib/js/rt.mjs — the value layer of the SYNC JS profile of Beam Lisp.
//
// The sync profile (priv/lib/js/emit.bl) compiles a BL function to a plain JS
// function and a call to a plain JS call. Its values live here:
//
//   nil            null
//   true/false     JS booleans
//   integer        JS Number in the safe range, BigInt beyond (one canonical
//                  form: a result that fits is normalized back to a Number)
//   float          Flt — a boxed double, so 1 and 1.0 stay distinct values
//                  (PLAN-157 D3: exact numerics, Elm-lean, NOT Elm-inexact)
//   string         JS string (UTF-16); text functions count CODEPOINTS
//   keyword        Kw, interned (identity = equality)
//   symbol         the BEAM's own reader node {:symbol, "name"} (a Tup)
//   list           Cons cells ending in EMPTY; `()` is EMPTY, distinct from nil
//   vector         Vec — persistent 32-way trie + tail (structural sharing)
//   map            HMap — persistent hash array mapped trie
//   set            HSet — an HMap of element → true
//   tuple          Tup (Erlang tuple; the compiler emits a few)
//   fn             a JS function; multi-arity/variadic via a dispatch wrapper
//
// Equality and hashing follow BL: lists and vectors are ONE sequential family
// under `=`, but map KEYS keep them apart (as BEAM's hash_key does). Every
// collection operation is O(log32 n) and shares structure, so an editor whose
// document is a vector of lines pays per edit for the lines it touches.

// ─── scalars ────────────────────────────────────────────────────────────────

import * as Z from "./lazy.mjs";

export class Kw {
  constructor(ns, name) { this.ns = ns; this.name = name; this.fq = ns ? ns + "/" + name : name; this.h = 0; }
  toString() { return ":" + this.fq; }
}
const KWS = new Map();
export function kw(fq) {
  let k = KWS.get(fq);
  if (k === undefined) {
    const i = fq.indexOf("/");
    k = (i > 0 && fq.length > 1) ? new Kw(fq.slice(0, i), fq.slice(i + 1)) : new Kw(null, fq);
    k.h = (strHash(fq) ^ 0x5bd1e995) | 0;
    KWS.set(fq, k);
  }
  return k;
}

export class Flt {
  constructor(v) { this.v = v; }
}

/** An exact decimal (`1.50M`): unscaled BigInt `u` and scale `s` >= 0, value
    u * 10^-s (PLAN-157 D3). As on the BEAM the scale is part of the value:
    (= 1.5M 1.50M) is false, and `1.50M` prints with its two places. */
export class Dec {
  constructor(u, s) { this.u = BigInt(u); this.s = s; }
  plain() {
    const neg = this.u < 0n, d = (neg ? -this.u : this.u).toString().padStart(this.s + 1, "0");
    const body = this.s === 0 ? d : d.slice(0, d.length - this.s) + "." + d.slice(d.length - this.s);
    return (neg ? "-" : "") + body;
  }
}
export function dec(u, s) { return new Dec(u, s); }
/** Decimal.parse: "[+-]digits[.digits][e[+-]digits]" -> Dec, or null. A
    negative scale from the exponent is folded into the unscaled value. */
export function parseDec(text) {
  const m = /^\s*([+-])?(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?\s*$/.exec(text);
  if (!m || (!m[2] && !m[3])) return null;
  const frac = m[3] || "", e = m[4] ? parseInt(m[4], 10) : 0;
  let u = BigInt((m[2] || "") + frac || "0");
  if (m[1] === "-") u = -u;
  const s = frac.length - e;
  return s >= 0 ? new Dec(u, s) : new Dec(u * 10n ** BigInt(-s), 0);
}
export function flt(v) { return new Flt(+v); }

export class Tup {
  constructor(items) { this.items = items; }
}
export function tup(items) { return new Tup(items); }

/** A symbol is what it is on the BEAM: the reader node `{:symbol, "name"}`,
    a Tup — so a symbol a macro builds and a quoted symbol are ONE kind of
    value (`(= 'a (symbol "a"))`, map keys, printing). `Sym` is that Tup's
    recognizer, not a separate class. */
const SYM_TAG = kw("symbol");
export function isSym(x) { return x instanceof Tup && x.items.length === 2 && x.items[0] === SYM_TAG && typeof x.items[1] === "string"; }
export const Sym = { [Symbol.hasInstance]: isSym };
export function sym(name) { return new Tup([SYM_TAG, name]); }
export function symName(x) { return x.items[1]; }


// ─── lists ──────────────────────────────────────────────────────────────────

/** A list cell. `n` is the length of a PROPER list (ending in ()), and -1 for a
    chain that ends in anything else — a lazy tail (`(cons 1 (map …))`, a
    chunked seq's next node). Kept per cell so `count`, `=` and the printer ask
    "is this a plain list?" in O(1) instead of walking to the end every time. */
export class Cons {
  constructor(h, t) {
    this.h = h; this.t = t;
    this.n = t instanceof Cons ? (t.n < 0 ? -1 : t.n + 1) : (t === EMPTY ? 1 : -1);
  }
}
export const EMPTY = Object.freeze(Object.create(null, { __empty: { value: true } }));

/** A lazy sequence is lazy.mjs's `LazySeq` (the BEAM's cell state machine).
    `realize` turns a finite seq whose cells may be lazy into plain Cons cells. */
export const Lazy = Z.LazySeq;
export function realize(x) {
  if (!(x instanceof Z.LazySeq) && !(x instanceof Cons && hasLazyTail(x))) return x;
  return Z.toList(x);
}
function hasLazyTail(c) { return c.n < 0; }
export function cons(h, t) { return new Cons(h, t === null ? EMPTY : t); }
export function list(...xs) { return listFromArray(xs); }
export function listFromArray(a, from = 0) {
  let l = EMPTY;
  for (let i = a.length - 1; i >= from; i--) l = new Cons(a[i], l);
  return l;
}

// ─── persistent vector (32-way trie + tail) ─────────────────────────────────

const BITS = 5, WIDTH = 32, MASK = 31;
const EMPTY_NODE = Object.freeze([]);

export class Vec {
  constructor(cnt, shift, root, tail, meta) {
    this.cnt = cnt; this.shift = shift; this.root = root; this.tail = tail; this.meta = meta || null; this._h = undefined; this._l = undefined;
  }
  tailOff() { return this.cnt < WIDTH ? 0 : ((this.cnt - 1) >>> BITS) << BITS; }
  /** The element list, built once: a vector is immutable, so every `seq` /
      `next` / fold of the same vector shares one spine (the BEAM pays this
      walk per call too, but over a flat tuple; here it was a fresh trie walk). */
  toList() {
    if (this._l !== undefined) return this._l;
    // built back to front, a leaf array at a time (no intermediate array)
    let l = EMPTY;
    for (let base = this.cnt === 0 ? -1 : ((this.cnt - 1) >>> BITS) << BITS; base >= 0; base -= WIDTH) {
      const a = this.arrayFor(base), n = Math.min(WIDTH, this.cnt - base);
      for (let j = n - 1; j >= 0; j--) l = new Cons(a[j], l);
    }
    return (this._l = l);
  }
  arrayFor(i) {
    if (i >= this.tailOff()) return this.tail;
    let node = this.root;
    for (let lvl = this.shift; lvl > 0; lvl -= BITS) node = node[(i >>> lvl) & MASK];
    return node;
  }
  nth(i, dflt) {
    if (i >= 0 && i < this.cnt && Number.isInteger(i)) return this.arrayFor(i)[i & MASK];
    return dflt;
  }
  conj(x) {
    if (this.cnt - this.tailOff() < WIDTH) {
      const t = this.tail.slice(); t.push(x);
      return new Vec(this.cnt + 1, this.shift, this.root, t, this.meta);
    }
    let newRoot, newShift = this.shift;
    const tailNode = this.tail;
    if ((this.cnt >>> BITS) > (1 << this.shift)) {
      newRoot = [this.root, newPath(this.shift, tailNode)];
      newShift += BITS;
    } else {
      newRoot = pushTail(this.cnt, this.shift, this.root, tailNode);
    }
    return new Vec(this.cnt + 1, newShift, newRoot, [x], this.meta);
  }
  assocN(i, x) {
    if (i >= 0 && i < this.cnt) {
      if (i >= this.tailOff()) {
        const t = this.tail.slice(); t[i & MASK] = x;
        return new Vec(this.cnt, this.shift, this.root, t, this.meta);
      }
      return new Vec(this.cnt, this.shift, doAssoc(this.shift, this.root, i, x), this.tail, this.meta);
    }
    if (i === this.cnt) return this.conj(x);
    throw new BLError("index " + i + " out of bounds for a vector of " + this.cnt);
  }
  pop() {
    if (this.cnt === 0) throw new BLError("can't pop an empty vector");
    if (this.cnt === 1) return EMPTY_VEC;
    if (this.cnt - this.tailOff() > 1) return new Vec(this.cnt - 1, this.shift, this.root, this.tail.slice(0, -1), this.meta);
    const newTail = this.arrayFor(this.cnt - 2);
    let newRoot = popTail(this.cnt, this.shift, this.root);
    let newShift = this.shift;
    if (newRoot === null) newRoot = EMPTY_NODE;
    if (this.shift > BITS && newRoot[1] === undefined) { newRoot = newRoot[0]; newShift -= BITS; }
    return new Vec(this.cnt - 1, newShift, newRoot, newTail, this.meta);
  }
  *[Symbol.iterator]() {
    for (let i = 0; i < this.cnt; i += WIDTH) {
      const a = this.arrayFor(i);
      const n = Math.min(WIDTH, this.cnt - i);
      for (let j = 0; j < n; j++) yield a[j];
    }
  }
  toArray() {
    const out = new Array(this.cnt);
    for (let i = 0; i < this.cnt; i += WIDTH) {
      const a = this.arrayFor(i), n = Math.min(WIDTH, this.cnt - i);
      for (let j = 0; j < n; j++) out[i + j] = a[j];
    }
    return out;
  }
}
function newPath(level, node) { return level === 0 ? node : [newPath(level - BITS, node)]; }
function pushTail(cnt, level, parent, tailNode) {
  const sub = ((cnt - 1) >>> level) & MASK;
  const ret = parent.slice();
  let ins;
  if (level === BITS) ins = tailNode;
  else {
    const child = parent[sub];
    ins = child !== undefined ? pushTail(cnt, level - BITS, child, tailNode) : newPath(level - BITS, tailNode);
  }
  ret[sub] = ins;
  return ret;
}
function doAssoc(level, node, i, x) {
  const ret = node.slice();
  if (level === 0) ret[i & MASK] = x;
  else { const sub = (i >>> level) & MASK; ret[sub] = doAssoc(level - BITS, node[sub], i, x); }
  return ret;
}
function popTail(cnt, level, node) {
  const sub = ((cnt - 2) >>> level) & MASK;
  if (level > BITS) {
    const child = popTail(cnt, level - BITS, node[sub]);
    if (child === null && sub === 0) return null;
    const ret = node.slice();
    if (child === null) ret.length = sub; else ret[sub] = child;
    return ret;
  }
  if (sub === 0) return null;
  const ret = node.slice(); ret.length = sub; return ret;
}
export const EMPTY_VEC = new Vec(0, BITS, EMPTY_NODE, [], null);
export function vec(...xs) { return vecFromArray(xs); }
export function vecFromArray(a) {
  if (a.length <= WIDTH) return new Vec(a.length, BITS, EMPTY_NODE, a.slice(), null);
  let v = EMPTY_VEC;
  for (const x of a) v = v.conj(x);
  return v;
}
/** subvec: a fresh vector of [from, to). O(k log n); views are not worth it here. */
export function subvec(v, from, to) {
  if (to === undefined) to = v.cnt;
  if (from < 0 || to > v.cnt || from > to) throw new BLError("subvec " + from + ".." + to + " out of bounds for " + v.cnt);
  const out = new Array(to - from);
  for (let i = from; i < to; i++) out[i - from] = v.nth(i);
  return vecFromArray(out);
}

// ─── persistent hash map (HAMT) ─────────────────────────────────────────────
//
// Bitmap-indexed nodes; a collision node holds entries whose hashes are equal
// in all 32 bits. Keys compare with `keyEq` (the hash_key relation: a list and
// a vector are different keys).

const NOT_FOUND = { nf: true };

class BNode {   // bitmap-indexed: arr = [k0, v0, k1, v1, ...]; a key slot of NODE_MARK holds a sub-node in v
  constructor(bitmap, arr) { this.bitmap = bitmap; this.arr = arr; }
}
class CNode {   // collision: all keys share `hash`
  constructor(hash, arr) { this.hash = hash; this.arr = arr; }
}
const NODE_MARK = { node: true };
function popcount(x) { x -= (x >>> 1) & 0x55555555; x = (x & 0x33333333) + ((x >>> 2) & 0x33333333); return (((x + (x >>> 4)) & 0x0f0f0f0f) * 0x01010101) >>> 24; }
function bitpos(hash, shift) { return 1 << ((hash >>> shift) & 31); }
function bidx(bitmap, bit) { return popcount(bitmap & (bit - 1)); }

function nodeGet(node, shift, hash, key) {
  for (;;) {
    if (node instanceof CNode) {
      const a = node.arr;
      for (let i = 0; i < a.length; i += 2) if (keyEq(a[i], key)) return a[i + 1];
      return NOT_FOUND;
    }
    const bit = bitpos(hash, shift);
    if ((node.bitmap & bit) === 0) return NOT_FOUND;
    const i = 2 * bidx(node.bitmap, bit);
    const k = node.arr[i];
    if (k === NODE_MARK) { node = node.arr[i + 1]; shift += 5; continue; }
    return keyEq(k, key) ? node.arr[i + 1] : NOT_FOUND;
  }
}
// returns [newNode, added?]
function nodeAssoc(node, shift, hash, key, val) {
  if (node instanceof CNode) {
    if (hash === node.hash) {
      const a = node.arr;
      for (let i = 0; i < a.length; i += 2) {
        if (keyEq(a[i], key)) {
          if (a[i + 1] === val) return [node, false];
          const b = a.slice(); b[i + 1] = val; return [new CNode(hash, b), false];
        }
      }
      return [new CNode(hash, a.concat([key, val])), true];
    }
    // nest the collision node under a bitmap node
    const wrap = new BNode(bitpos(node.hash, shift), [NODE_MARK, node]);
    return nodeAssoc(wrap, shift, hash, key, val);
  }
  const bit = bitpos(hash, shift);
  const i = 2 * bidx(node.bitmap, bit);
  if ((node.bitmap & bit) === 0) {
    const a = node.arr.slice(); a.splice(i, 0, key, val);
    return [new BNode(node.bitmap | bit, a), true];
  }
  const k = node.arr[i], v = node.arr[i + 1];
  if (k === NODE_MARK) {
    const [n2, added] = nodeAssoc(v, shift + 5, hash, key, val);
    if (n2 === v) return [node, false];
    const a = node.arr.slice(); a[i + 1] = n2; return [new BNode(node.bitmap, a), added];
  }
  if (keyEq(k, key)) {
    if (v === val) return [node, false];
    const a = node.arr.slice(); a[i + 1] = val; return [new BNode(node.bitmap, a), false];
  }
  // two different keys in one slot: push both one level down
  const sub = mergeTwo(shift + 5, k, v, hashOf(k), key, val, hash);
  const a = node.arr.slice(); a[i] = NODE_MARK; a[i + 1] = sub;
  return [new BNode(node.bitmap, a), true];
}
function mergeTwo(shift, k1, v1, h1, k2, v2, h2) {
  if (h1 === h2) return new CNode(h1, [k1, v1, k2, v2]);
  if (shift > 30) return new CNode(h1, [k1, v1, k2, v2]); // unreachable with 32-bit hashes; defensive
  const b1 = bitpos(h1, shift), b2 = bitpos(h2, shift);
  if (b1 === b2) return new BNode(b1, [NODE_MARK, mergeTwo(shift + 5, k1, v1, h1, k2, v2, h2)]);
  // array order is popcount order = UNSIGNED bit order; `1 << 31` is negative
  // in JS, so compare the slot numbers, never the signed bit values
  const s1 = (h1 >>> shift) & 31, s2 = (h2 >>> shift) & 31;
  return s1 < s2 ? new BNode(b1 | b2, [k1, v1, k2, v2]) : new BNode(b1 | b2, [k2, v2, k1, v1]);
}
// returns newNode | null (emptied) | node (unchanged)
function nodeDissoc(node, shift, hash, key) {
  if (node instanceof CNode) {
    const a = node.arr;
    for (let i = 0; i < a.length; i += 2) {
      if (keyEq(a[i], key)) {
        if (a.length === 2) return null;
        const b = a.slice(); b.splice(i, 2); return new CNode(node.hash, b);
      }
    }
    return node;
  }
  const bit = bitpos(hash, shift);
  if ((node.bitmap & bit) === 0) return node;
  const i = 2 * bidx(node.bitmap, bit);
  const k = node.arr[i], v = node.arr[i + 1];
  if (k === NODE_MARK) {
    const n2 = nodeDissoc(v, shift + 5, hash, key);
    if (n2 === v) return node;
    if (n2 !== null) { const a = node.arr.slice(); a[i + 1] = n2; return new BNode(node.bitmap, a); }
    if (node.bitmap === bit) return null;
    const a = node.arr.slice(); a.splice(i, 2); return new BNode(node.bitmap ^ bit, a);
  }
  if (!keyEq(k, key)) return node;
  if (node.bitmap === bit) return null;
  const a = node.arr.slice(); a.splice(i, 2); return new BNode(node.bitmap ^ bit, a);
}
function* nodeEntries(node) {
  const a = node.arr;
  for (let i = 0; i < a.length; i += 2) {
    if (a[i] === NODE_MARK) yield* nodeEntries(a[i + 1]);
    else yield [a[i], a[i + 1]];
  }
}
const EMPTY_BNODE = new BNode(0, []);

export class HMap {
  constructor(cnt, root, meta) { this.cnt = cnt; this.root = root; this.meta = meta || null; this._h = undefined; }
  get(k, dflt) { const v = nodeGet(this.root, 0, hashOf(k), k); return v === NOT_FOUND ? dflt : v; }
  has(k) { return nodeGet(this.root, 0, hashOf(k), k) !== NOT_FOUND; }
  assoc(k, v) {
    const [r, added] = nodeAssoc(this.root, 0, hashOf(k), k, v);
    return r === this.root ? this : new HMap(added ? this.cnt + 1 : this.cnt, r, this.meta);
  }
  dissoc(k) {
    const r = nodeDissoc(this.root, 0, hashOf(k), k);
    if (r === this.root) return this;
    return new HMap(this.cnt - 1, r === null ? EMPTY_BNODE : r, this.meta);
  }
  *[Symbol.iterator]() { yield* nodeEntries(this.root); }
  /** entries in a DETERMINISTIC order (see `sortedEntries`); printing, keys,
      vals and seq use it so output never depends on hash layout */
  entries() { return sortedEntries([...nodeEntries(this.root)]); }
}
export const EMPTY_MAP = new HMap(0, EMPTY_BNODE, null);
export function hashMap(...kvs) {
  let m = EMPTY_MAP;
  for (let i = 0; i < kvs.length; i += 2) m = m.assoc(kvs[i], kvs[i + 1]);
  return m;
}

export class HSet {
  constructor(m, meta) { this.m = m; this.meta = meta || null; this._h = undefined; }
  get cnt() { return this.m.cnt; }
  has(x) { return this.m.has(x); }
  conj(x) { const m = this.m.assoc(x, true); return m === this.m ? this : new HSet(m, this.meta); }
  disj(x) { const m = this.m.dissoc(x); return m === this.m ? this : new HSet(m, this.meta); }
  *[Symbol.iterator]() { for (const [k] of this.m) yield k; }
  elements() { return this.m.entries().map(e => e[0]); }
}
export const EMPTY_SET = new HSet(EMPTY_MAP, null);
export function hashSet(...xs) { let s = EMPTY_SET; for (const x of xs) s = s.conj(x); return s; }

// Map/set enumeration order: BL's total `compare` where it is defined, kind
// order otherwise. Deterministic across runs and hosts; it is NOT the BEAM
// atom-table order (FUP-141 records that small-map order on BEAM depends on
// the atom table and cannot be reproduced anywhere else).
function sortedEntries(es) { return es.sort((a, b) => compare(a[0], b[0])); }

// ─── hashing + equality ─────────────────────────────────────────────────────

export function strHash(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return h | 0;
}
function mix(h, x) { h = Math.imul(h ^ x, 0x9e3779b1); return (h ^ (h >>> 15)) | 0; }
function numHash(n) {
  if (Number.isInteger(n)) return (n | 0) ^ ((n / 4294967296) | 0);
  return strHash(String(n));
}

/** The hash_key hash: consistent with `keyEq`. */
export function hashOf(x) {
  if (x === null || x === undefined) return 0;
  switch (typeof x) {
    case "number": return numHash(x);
    case "bigint": return strHash(x.toString());
    case "string": return strHash(x);
    case "boolean": return x ? 1231 : 1237;
    case "function": return fnId(x);
  }
  if (x instanceof Kw) return x.h;
  if (x instanceof Flt) return mix(0x3f800000, numHash(x.v));
  if (x._h !== undefined && x._h !== null) return x._h;
  let h;
  if (x instanceof Vec) { h = 0x7e57; for (const e of x) h = mix(h, hashOf(e)); x._h = h; return h; }
  if (x instanceof HMap) { h = 0x4d41; for (const [k, v] of x) h = (h + (mix(hashOf(k), hashOf(v)))) | 0; x._h = h; return h; }
  if (x instanceof HSet) { h = 0x5345; for (const e of x) h = (h + hashOf(e)) | 0; x._h = h; return h; }
  if (x === EMPTY) return 0x4c00;
  if (x instanceof Cons) { h = 0x4c49; for (let p = x; p instanceof Cons; p = p.t) h = mix(h, hashOf(p.h)); return h; }
  if (x instanceof Dec) return mix(strHash(x.u.toString()), x.s ^ 0x4dec);
  if (x instanceof Tup) { h = 0x5455; for (const e of x.items) h = mix(h, hashOf(e)); return h; }
  return fnId(x);
}
const IDS = new WeakMap(); let nextId = 1;
function fnId(x) { let i = IDS.get(x); if (i === undefined) { i = nextId++; IDS.set(x, i); } return i; }

/** hash_key equality: structural, but a list and a vector differ. */
export function keyEq(a, b) {
  if (a === b) return true;
  if (a === null || b === null || a === undefined || b === undefined) return false;
  const ta = typeof a;
  if (ta !== "object" || typeof b !== "object") {
    if ((ta === "number" || ta === "bigint") && (typeof b === "number" || typeof b === "bigint")) return a == b; // eslint-disable-line eqeqeq
    return false;
  }
  if (a instanceof Flt) return b instanceof Flt && (a.v === b.v || (a.v !== a.v && b.v !== b.v));
  if (a instanceof Vec) return b instanceof Vec && seqEqv(a, b, keyEq);
  if (a instanceof Cons || a === EMPTY) return (b instanceof Cons || b === EMPTY) && seqEqv(a, b, keyEq);
  if (a instanceof HMap) return b instanceof HMap && mapEqv(a, b, keyEq);
  if (a instanceof HSet) return b instanceof HSet && a.cnt === b.cnt && [...a].every(e => b.has(e));
  if (a instanceof Tup) return b instanceof Tup && a.items.length === b.items.length && a.items.every((e, i) => keyEq(e, b.items[i]));
  if (a instanceof Dec) return b instanceof Dec && a.u === b.u && a.s === b.s;
  return false;
}
/** Erlang TERM order (`erlang/<`, `=<`, `lists:sort`) on the JS value model:
    number < atom < fun < tuple < map < list < binary. Atoms (nil, booleans,
    keywords) order by name; tuples by size then element-wise; lists
    element-wise, shorter first; binaries by codepoint (= UTF-8 byte order).
    A BEAM vector/set/decimal is a struct, i.e. a map. Numbers compare by
    value (1 and 1.0 are neither less than the other). */
export function termCompare(a, b) {
  const ra = termRank(a), rb = termRank(b);
  if (ra !== rb) return ra < rb ? -1 : 1;
  switch (ra) {
    case 0: { const x = numOf(a), y = numOf(b); return x < y ? -1 : x > y ? 1 : 0; }
    case 1: { const x = atomName(a), y = atomName(b); return x < y ? -1 : x > y ? 1 : 0; }
    case 2: return 0;
    case 3: {
      if (a.items.length !== b.items.length) return a.items.length < b.items.length ? -1 : 1;
      for (let i = 0; i < a.items.length; i++) { const c = termCompare(a.items[i], b.items[i]); if (c) return c; }
      return 0;
    }
    case 4: return compare(a, b);
    case 5: {
      let p = a, q = b;
      for (;;) {
        const ea = p === EMPTY, eb = q === EMPTY;
        if (ea || eb) return ea && eb ? 0 : ea ? -1 : 1;
        const c = termCompare(p.h, q.h); if (c) return c;
        p = p.t; q = q.t;
      }
    }
    case 6: { const ia = a[Symbol.iterator](), ib = b[Symbol.iterator]();
      for (;;) { const x = ia.next(), y = ib.next(); if (x.done || y.done) return x.done && y.done ? 0 : x.done ? -1 : 1;
        const ca = x.value.codePointAt(0), cb = y.value.codePointAt(0); if (ca !== cb) return ca < cb ? -1 : 1; } }
  }
  return 0;
}
function termRank(x) {
  if (typeof x === "number" || typeof x === "bigint" || x instanceof Flt) return 0;
  if (x === null || x === undefined || x === true || x === false || x instanceof Kw) return 1;
  if (typeof x === "function") return 2;
  if (x instanceof Tup) return 3;
  if (x instanceof HMap || x instanceof Vec || x instanceof HSet || x instanceof Dec) return 4;
  if (x === EMPTY || x instanceof Cons) return 5;
  if (typeof x === "string") return 6;
  return 4;
}
function atomName(x) { return x === null || x === undefined ? "nil" : x === true ? "true" : x === false ? "false" : x.fq; }

/** BL `=`, measured against BEAM (2026-10-03): lists and vectors are one
    sequential family, and numbers compare NUMERICALLY across int/float —
    (= 1 1.0), (= [1] [1.0]) are true. Map/set KEYS do not: (get {1 :a} 1.0)
    is nil, (contains? #{1} 1.0) is false — that is `keyEq`. */
export function eqv(a, b) {
  if (a === b) return true;
  if (a instanceof Lazy) a = realize(a);
  if (b instanceof Lazy) b = realize(b);
  if (a === null || b === null || a === undefined || b === undefined) return false;
  // decimals (BEAM, measured): two decimals compare by unscaled+scale
  // ((= 1.5M 1.50M) false); a decimal and an int/float by value
  // ((= 1.5M 1.5) true, (= 2M 2) true)
  if (a instanceof Dec || b instanceof Dec) {
    if (a instanceof Dec && b instanceof Dec) return a.u === b.u && a.s === b.s;
    const d = a instanceof Dec ? a : b, o = a instanceof Dec ? b : a;
    if (!isNumV(o)) return false;
    if (o instanceof Flt) return Number(d.plain()) === o.v;
    return decCmp(d, o) === 0;
  }
  if (isNumV(a)) return isNumV(b) && Number(numOf(a)) === Number(numOf(b)) && (typeof a !== "bigint" || typeof b !== "bigint" || a === b);
  const ta = typeof a;
  if (ta !== "object" || typeof b !== "object") return false;
  if (isSeqColl(a)) return isSeqColl(b) && seqEqv(a, b, eqv);
  if (a instanceof HMap) return b instanceof HMap && mapEqv(a, b, eqv);
  if (a instanceof HSet) return b instanceof HSet && a.cnt === b.cnt && [...a].every(e => b.has(e));
  if (a instanceof Tup) return b instanceof Tup && a.items.length === b.items.length && a.items.every((e, i) => eqv(e, b.items[i]));
  if (a instanceof Dec) return b instanceof Dec && a.u === b.u && a.s === b.s;
  return false;
}
function isSeqColl(x) { return x instanceof Vec || x instanceof Cons || x === EMPTY; }
function isNumV(x) { return typeof x === "number" || typeof x === "bigint" || x instanceof Flt; }
function seqEqv(a, b, eq) {
  const ia = iter(a), ib = iter(b);
  for (;;) {
    const x = ia.next(), y = ib.next();
    if (x.done || y.done) return x.done === y.done;
    if (!eq(x.value, y.value)) return false;
  }
}
function mapEqv(a, b, eq) {
  if (a.cnt !== b.cnt) return false;
  for (const [k, v] of a) { const w = b.get(k, NOT_FOUND); if (w === NOT_FOUND || !eq(v, w)) return false; }
  return true;
}
function* iter(x) {
  if (x instanceof Vec) { yield* x; return; }
  for (let p = x; p instanceof Cons; p = p.t) yield p.h;
}

// ─── ordering (BL `compare`) ────────────────────────────────────────────────
//
// numbers < (nil false true) < keywords < symbols < strings < sequential
// < maps < sets < everything else. Strings order by CODEPOINT (= UTF-8 byte
// order, as BEAM binaries do), sequentials element-wise then by length.

function rank(x) {
  if (typeof x === "number" || typeof x === "bigint" || x instanceof Flt || x instanceof Dec) return 0;
  if (x === null || x === undefined || x === false || x === true) return 1;
  if (x instanceof Kw) return 2;
  if (x instanceof Sym) return 3;
  if (typeof x === "string") return 4;
  if (isSeqColl(x)) return 5;
  if (x instanceof HMap) return 6;
  if (x instanceof HSet) return 7;
  if (x instanceof Tup) return 8;
  return 9;
}
export function compare(a, b) {
  const ra = rank(a), rb = rank(b);
  if (ra !== rb) return ra < rb ? -1 : 1;
  switch (ra) {
    case 0: {
      if (a instanceof Dec || b instanceof Dec) {
        if (a instanceof Flt || b instanceof Flt) { const x = a instanceof Dec ? Number(a.plain()) : a.v, y = b instanceof Dec ? Number(b.plain()) : b.v; return x < y ? -1 : x > y ? 1 : 0; }
        return decCmp(a, b);
      }
      const x = numOf(a), y = numOf(b); return x < y ? -1 : x > y ? 1 : 0;
    }
    case 1: { const o = v => v === null || v === undefined ? 0 : v === false ? 1 : 2; return o(a) - o(b); }
    case 2: return strCmp(a.fq, b.fq);
    case 3: return strCmp(a.name, b.name);
    case 4: return strCmp(a, b);
    case 5: {
      const ia = iter(a), ib = iter(b);
      for (;;) {
        const x = ia.next(), y = ib.next();
        if (x.done || y.done) return x.done && y.done ? 0 : x.done ? -1 : 1;
        const c = compare(x.value, y.value); if (c !== 0) return c;
      }
    }
    case 6: case 7: { const ca = a.cnt, cb = b.cnt; if (ca !== cb) return ca < cb ? -1 : 1; return compare(printStr(a), printStr(b)); }
    case 8: { const n = Math.min(a.items.length, b.items.length); for (let i = 0; i < n; i++) { const c = compare(a.items[i], b.items[i]); if (c) return c; } return a.items.length - b.items.length; }
    default: return 0;
  }
}
function numOf(x) { return x instanceof Flt ? x.v : x; }
export function strCmp(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n;) {
    const ca = a.codePointAt(i), cb = b.codePointAt(i);
    if (ca !== cb) return ca < cb ? -1 : 1;
    i += ca > 0xffff ? 2 : 1;
  }
  return a.length === b.length ? 0 : a.length < b.length ? -1 : 1;
}

// ─── errors ─────────────────────────────────────────────────────────────────

/** A BL raise: `(throw (ex-info msg data))` or a runtime error. */
export class BLError extends Error {
  constructor(message, data, cause) { super(message); this.data = data === undefined ? null : data; this.blCause = cause || null; }
}

// ─── exact arithmetic ───────────────────────────────────────────────────────

const MAX = 9007199254740991, MIN = -9007199254740991;
function norm(b) { return (b >= -9007199254740991n && b <= 9007199254740991n) ? Number(b) : b; }
function isIntV(x) { return typeof x === "number" || typeof x === "bigint"; }
function needNum(op, a, b) {
  if (!(isIntV(a) || a instanceof Flt) || !(isIntV(b) || b instanceof Flt))
    throw new BLError(op + " needs numbers, got " + printStr(a) + " and " + printStr(b));
}
// ─── exact decimals (measured against BEAM, 2026-10-04) ───────────────────────
// (+ 1.5M 1) 2.5M; (* 1.5M 2) 3.0M; (* 1.5M 1.5M) 2.25M; (/ 1M 4) 0.25M;
// (/ 6M 3) 2M; (/ 1.20M 3) 0.40M; (/ 1M 3) raises (non-terminating);
// a float operand raises; (- 1.5M) -1.5M. + and - align to the larger
// scale, * adds scales, / keeps the dividend's scale when exact, else the
// smallest scale that terminates.
const isDec = (x) => x instanceof Dec;
function toDec(x, op) {
  if (x instanceof Dec) return x;
  if (typeof x === "number" || typeof x === "bigint") return new Dec(BigInt(x), 0);
  if (x instanceof Flt) throw new BLError("a float cannot enter decimal arithmetic: " + printStr(x) + " (use decimal/from-float to approximate on purpose)");
  throw new BLError(op + " needs numbers, got " + printStr(x));
}
const P10 = (n) => 10n ** BigInt(n);
function decArith(op, a, b) {
  const x = toDec(a, op), y = toDec(b, op);
  if (op === "*") return new Dec(x.u * y.u, x.s + y.s);
  if (op === "/") {
    if (y.u === 0n) throw new BLError("divide by zero");
    // value = (x.u / 10^x.s) / (y.u / 10^y.s): try scales from the dividend's up
    for (let s = x.s; s <= x.s + 64; s++) {
      const num = x.u * P10(s - x.s + y.s), den = y.u;
      if (num % den === 0n) return new Dec(num / den, s);
    }
    throw new BLError("non-terminating decimal expansion; no exact representable decimal result");
  }
  const s = Math.max(x.s, y.s), xu = x.u * P10(s - x.s), yu = y.u * P10(s - y.s);
  return new Dec(op === "+" ? xu + yu : xu - yu, s);
}
function decCmp(a, b) {
  const x = toDec(a, "compare"), y = toDec(b, "compare"), s = Math.max(x.s, y.s);
  const xu = x.u * P10(s - x.s), yu = y.u * P10(s - y.s);
  return xu < yu ? -1 : xu > yu ? 1 : 0;
}

export function add(a, b) {
  if (typeof a === "number" && typeof b === "number") { const r = a + b; if (r <= MAX && r >= MIN) return r; return norm(BigInt(a) + BigInt(b)); }
  if (isDec(a) || isDec(b)) return decArith("+", a, b);
  needNum("+", a, b);
  if (a instanceof Flt || b instanceof Flt) return new Flt(numOf(a) + Number(numOf(b)));
  return norm(BigInt(a) + BigInt(b));
}
export function sub(a, b) {
  if (typeof a === "number" && typeof b === "number") { const r = a - b; if (r <= MAX && r >= MIN) return r; return norm(BigInt(a) - BigInt(b)); }
  if (isDec(a) || isDec(b)) return decArith("-", a, b);
  needNum("-", a, b);
  if (a instanceof Flt || b instanceof Flt) return new Flt(Number(numOf(a)) - Number(numOf(b)));
  return norm(BigInt(a) - BigInt(b));
}
export function mul(a, b) {
  if (typeof a === "number" && typeof b === "number") { const r = a * b; if (r <= MAX && r >= MIN) return r === 0 ? 0 : r; return norm(BigInt(a) * BigInt(b)); }
  if (isDec(a) || isDec(b)) return decArith("*", a, b);
  needNum("*", a, b);
  if (a instanceof Flt || b instanceof Flt) return new Flt(Number(numOf(a)) * Number(numOf(b)));
  return norm(BigInt(a) * BigInt(b));
}
/** BEAM `/` answers a float, always. */
export function div(a, b) {
  if (isDec(a) || isDec(b)) return decArith("/", a, b);
  needNum("/", a, b);
  const y = Number(numOf(b));
  if (y === 0) throw new BLError("divide by zero");
  return new Flt(Number(numOf(a)) / y);
}
function intArgs(op, a, b) {
  if (!isIntV(a) || !isIntV(b)) throw new BLError(op + " needs integers, got " + printStr(a) + " and " + printStr(b));
  if (b === 0 || b === 0n) throw new BLError(op + " by zero");
}
export function quot(a, b) { intArgs("quot", a, b); if (typeof a === "number" && typeof b === "number") return Math.trunc(a / b) || 0; return norm(BigInt(a) / BigInt(b)); }
export function rem(a, b) { intArgs("rem", a, b); if (typeof a === "number" && typeof b === "number") return (a % b) || 0; return norm(BigInt(a) % BigInt(b)); }
export function mod(a, b) {
  intArgs("mod", a, b);
  if (typeof a === "number" && typeof b === "number") { const m = a % b; return (m !== 0 && (m < 0) !== (b < 0) ? m + b : m) || 0; }
  const x = BigInt(a), y = BigInt(b), m = x % y; return norm(m !== 0n && (m < 0n) !== (y < 0n) ? m + y : m);
}
export function lt(a, b) { if (typeof a === "number" && typeof b === "number") return a < b; if (isDec(a) || isDec(b)) return decCmp(a, b) < 0; needNum("<", a, b); return numOf(a) < numOf(b); }
export function gt(a, b) { if (typeof a === "number" && typeof b === "number") return a > b; if (isDec(a) || isDec(b)) return decCmp(a, b) > 0; needNum(">", a, b); return numOf(a) > numOf(b); }
export function le(a, b) { if (typeof a === "number" && typeof b === "number") return a <= b; if (isDec(a) || isDec(b)) return decCmp(a, b) <= 0; needNum("<=", a, b); return numOf(a) <= numOf(b); }
export function ge(a, b) { if (typeof a === "number" && typeof b === "number") return a >= b; if (isDec(a) || isDec(b)) return decCmp(a, b) >= 0; needNum(">=", a, b); return numOf(a) >= numOf(b); }
/** `==`: numeric equality across int/float (BEAM `==`). */
export function numEq(a, b) { needNum("==", a, b); return Number(numOf(a)) === Number(numOf(b)) || a == b; } // eslint-disable-line eqeqeq
export function isInt(x) { return typeof x === "number" || typeof x === "bigint"; }
export function isFloat(x) { return x instanceof Flt; }
export function isNumber(x) { return isInt(x) || x instanceof Flt; }
export function toNumber(x) { return x instanceof Flt ? x.v : Number(x); }

// ─── strings by codepoint ───────────────────────────────────────────────────

/** Codepoint count (BL text length on the wire and in this profile). */
export function cpCount(s) { let n = 0; for (let i = 0; i < s.length; i++) { const c = s.charCodeAt(i); if (c < 0xd800 || c > 0xdbff) n++; } return n; }
/** UTF-16 index of codepoint index `cp` (clamped to s.length). */
export function cpToUnit(s, cp) {
  let u = 0;
  for (let k = 0; k < cp && u < s.length; k++) { const c = s.charCodeAt(u); u += (c >= 0xd800 && c <= 0xdbff) ? 2 : 1; }
  return u;
}
export function unitToCp(s, u) { let n = 0; for (let i = 0; i < u && i < s.length; i++) { const c = s.charCodeAt(i); if (c < 0xd800 || c > 0xdbff) n++; } return n; }
/** (subs s start end) by codepoints, BL semantics: out of range raises. */
export function subs(s, start, end) {
  const n = cpCount(s);
  if (end === undefined) end = n;
  if (start < 0 || end > n || start > end) throw new BLError("subs " + start + ".." + end + " out of range for a string of " + n);
  if (s.length === n) return s.slice(start, end);
  const a = cpToUnit(s, start);
  return s.slice(a, cpToUnit(s, end));
}

// ─── printing ───────────────────────────────────────────────────────────────

function escStr(s) {
  return '"' + s.replace(/[\\"\n\t\r]/g, c => c === "\n" ? "\\n" : c === "\t" ? "\\t" : c === "\r" ? "\\r" : "\\" + c) + '"';
}
/** `pr-str` — the readable printer. */
export function printStr(x) {
  if (x === null || x === undefined) return "nil";
  // a lazy or partly-lazy seq prints BOUNDED, as rt.bl's print-seq: at most 20
  // elements, then ` …` — an infinite seq must never hang the printer
  if (x instanceof Lazy || (x instanceof Cons && hasLazyTail(x))) {
    const r = Z.sample(x, 20);
    const a = []; for (let p = r.items[0]; p instanceof Cons; p = p.t) a.push(printStr(p.h));
    return "(" + a.join(" ") + (r.items[1] ? " …" : "") + ")";
  }
  switch (typeof x) {
    case "string": return escStr(x);
    case "number": case "bigint": return String(x);
    case "boolean": return x ? "true" : "false";
    case "function": return "#<fn " + (x.blName || x.name || "anonymous") + ">";
  }
  if (x instanceof Flt) { const s = String(x.v); return /[.eEn]|Infinity/.test(s) ? s : s + ".0"; }
  if (x instanceof Dec) return x.plain() + "M";
  if (x instanceof Kw) return ":" + x.fq;
  if (isSym(x)) return x.items[1];
  if (x instanceof Vec) return "[" + x.toArray().map(printStr).join(" ") + "]";
  if (x === EMPTY) return "()";
  if (x instanceof Cons) { const a = []; for (let p = x; p instanceof Cons; p = p.t) a.push(printStr(p.h)); return "(" + a.join(" ") + ")"; }
  if (x instanceof HMap) return "{" + x.entries().map(([k, v]) => printStr(k) + " " + printStr(v)).join(", ") + "}";
  if (x instanceof HSet) return "#{" + x.elements().sort(compare).map(printStr).join(" ") + "}";
  if (x instanceof Tup) return "{" + x.items.map(printStr).join(", ") + "}";
  if (x instanceof BLError) return "#error {:message " + escStr(x.message) + "}";
  if (x instanceof Atom) return "#<atom " + printStr(x.v) + ">";
  if (x !== null && typeof x === "object" && x.blStruct && x.blStruct.fq === "Elixir.Regex") return "~r/" + x.source + "/";
  if (x instanceof Z.Delay) return "#<delay " + (x.seq.s[0] === 2 ? printStr(x.seq.s[1]) : ":pending") + ">";
  return "#<host " + Object.prototype.toString.call(x) + ">";
}
/** `str` of one value: strings bare, nil empty, keywords with their colon. */
export function strOf(x) {
  if (typeof x === "string") return x;
  if (x === null || x === undefined) return "";
  if (x instanceof Dec) return x.plain();
  if (x instanceof Kw) return x.fq;
  return printStr(x);
}

// ─── atoms (the one mutable reference type) ─────────────────────────────────

export class Atom {
  constructor(v) { this.v = v; this.watches = null; }
}

// ─── truthiness ─────────────────────────────────────────────────────────────

export function truthy(x) { return x !== null && x !== undefined && x !== false; }

/** Erlang `==`: exact structure, except that numbers compare by VALUE across
    integer and float (1 == 1.0, {1} == {1.0}). A vector is a struct (a map) and
    never equals a list. Map KEYS still match exactly (=:=), as on the BEAM. */
export function erlEq(a, b) {
  if (a === b) return true;
  // the common case in rt.bl's loops: a scalar against a keyword/nil/number
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) {
    if (typeof a === "number" && typeof b === "number") return a === b;
    if (!isNumber(a) || !isNumber(b)) return false;
  }
  if (isNumber(a) && isNumber(b)) return (typeof a === "bigint" || typeof b === "bigint") && !(a instanceof Flt) && !(b instanceof Flt) ? BigInt(a) === BigInt(b) : Number(numv(a)) === Number(numv(b));
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return false;
  if (a instanceof Tup) return b instanceof Tup && a.items.length === b.items.length && a.items.every((x, i) => erlEq(x, b.items[i]));
  if (a instanceof Cons || a === EMPTY) {
    let p = a, q = b;
    for (;;) {
      if (p === EMPTY || q === EMPTY) return p === q;
      // one side ran out of cells: equal only if both tails are the same
      // non-cell term (an improper tail: a lazy node, a cursor)
      if (!(p instanceof Cons) || !(q instanceof Cons)) return !(p instanceof Cons) && !(q instanceof Cons) && erlEq(p, q);
      if (!erlEq(p.h, q.h)) return false;
      p = p.t; q = q.t;
    }
  }
  if (a instanceof Vec) return b instanceof Vec && a.cnt === b.cnt && a.toArray().every((x, i) => erlEq(x, b.nth(i)));
  if (a instanceof HMap) { if (!(b instanceof HMap) || a.cnt !== b.cnt) return false; for (const [k, v] of a.entries()) { const w = b.get(k, NO_KEY); if (w === NO_KEY || !erlEq(v, w)) return false; } return true; }
  return keyEq(a, b);
}
const NO_KEY = {};
const numv = (x) => (x instanceof Flt ? x.v : x);

// ─── BIF intrinsics (js.emit inlines `erlang/hd` & co to these, PLAN-163 U3) ─
// Each is EXACTLY its leaf (leaves.mjs / host-leaves.mjs), badarg included:
// the emitter calls a module function instead of a leaf-table property call.
const bad = (what, x) => { const e = new BLError("errors were found at the given arguments: " + what + " " + printStr(x)); e.blType = kw("Elixir.ArgumentError"); throw e; };
export function hd(l) { return l instanceof Cons ? l.h : bad("hd", l); }
export function tl(l) { return l instanceof Cons ? l.t : bad("tl", l); }
export function element(i, t) { return t instanceof Tup && i >= 1 && i <= t.items.length ? t.items[i - 1] : bad("element", t); }
export function tupleSize(t) { return t instanceof Tup ? t.items.length : bad("tuple_size", t); }
export const isList = (x) => x === EMPTY || x instanceof Cons;
/** rt.bl's raw constructors (rt.raw): `[x | xs]` with ANY tail (a lazy node
    stays the tail, unforced), and fixed tuples. */
export const consRaw = (x, xs) => new Cons(x, xs);
export const tuple2 = (a, b) => new Tup([a, b]);
export const tuple3 = (a, b, c) => new Tup([a, b, c]);
export const emptyList = () => EMPTY;
/** Self-host calling convention (PLAN-163 U3): a JS function is called
    directly; ANY other callee goes to compiled rt's own `invoke(f, args)` —
    the BEAM's Rt.invoke, with the arguments as one list — so keywords, maps,
    $blfn multi-fns and vectors are called by the language's rule, never by
    core.mjs. */
export function call(f, invoke, ...args) { return typeof f === "function" ? f(...args) : invoke(f, listFromArray(args)); }
// fixed-arity forms js.emit picks for 0–3 arguments: no rest array, no spread
export function call0(f, invoke) { return typeof f === "function" ? f() : invoke(f, EMPTY); }
export function call1(f, invoke, a) { return typeof f === "function" ? f(a) : invoke(f, new Cons(a, EMPTY)); }
export function call2(f, invoke, a, b) { return typeof f === "function" ? f(a, b) : invoke(f, new Cons(a, new Cons(b, EMPTY))); }
export function call3(f, invoke, a, b, c) { return typeof f === "function" ? f(a, b, c) : invoke(f, new Cons(a, new Cons(b, new Cons(c, EMPTY)))); }
// Intrinsic forms of the hottest pure leaves (js.emit inlines the call; the
// leaf in host-leaves.mjs / leaves.mjs answers identically): a small-integer
// fast path, else exactly the leaf's own general path.
export function ltI(a, b) { return typeof a === "number" && typeof b === "number" ? a < b : termCompare(a, b) < 0; }
export function gtI(a, b) { return typeof a === "number" && typeof b === "number" ? a > b : termCompare(a, b) > 0; }
export function leI(a, b) { return typeof a === "number" && typeof b === "number" ? a <= b : termCompare(a, b) <= 0; }
export function geI(a, b) { return typeof a === "number" && typeof b === "number" ? a >= b : termCompare(a, b) >= 0; }
export function addI(a, b) { if (typeof a === "number" && typeof b === "number") { const r = a + b; if (r <= MAX && r >= MIN) return r; } return add(a, b); }
export function subI(a, b) { if (typeof a === "number" && typeof b === "number") { const r = a - b; if (r <= MAX && r >= MIN) return r; } return sub(a, b); }
/** `lists:reverse/1` without the array round trip (an improper tail is
    ignored, as the leaf does). */
export function reverseI(l) {
  let r = EMPTY;
  for (let p = l; p instanceof Cons; p = p.t) r = new Cons(p.h, r);
  return r;
}
/** `erlang:list_to_tuple/1`. */
export function listToTupleI(l) {
  const a = [];
  for (let p = l; p instanceof Cons; p = p.t) a.push(p.h);
  return new Tup(a);
}
/** `erlang:is_function(F, N)`, as host-leaves answers it (a JS fn of length 0
    is a rest/variadic fn and accepts any arity). */
export function isFnN(x, n) { return typeof x === "function" && (x.length === n || x.length === 0); }
export function callList(f, args, invoke) {
  if (typeof f === "function") { const a = []; for (let p = args; p instanceof Cons; p = p.t) a.push(p.h); return f(...a); }
  return invoke(f, args);
}
/** `erlang:apply(F, Args)`: a JS function spread over a proper list. A non-
    function falls back to the leaf (which also calls keywords/maps). */
export function applyList(f, args) {
  if (typeof f === "function") {
    if (args === EMPTY) return f();
    if (args instanceof Cons && args.n >= 0) {
      if (args.n === 1) return f(args.h);
      if (args.n === 2) return f(args.h, args.t.h);
      const a = new Array(args.n); let i = 0; for (let p = args; p instanceof Cons; p = p.t) a[i++] = p.h; return f(...a);
    }
  }
  return APPLY2(f, args);
}
let APPLY2 = () => { throw new BLError("erlang:apply/2 leaf not bound"); };
export function bindApply2(g) { APPLY2 = g; }
/** The struct protocol (host-leaves.mjs owns it; bound here so js.emit can
    inline `erlang/is_map`, `is_map_key`, `map_get`, `maps:get/3`): a plain
    HMap is answered inline, any other value by the bound protocol. */
let SP = null;
export function bindStructProtocol(p) { SP = p; }
export function isMapI(x) { return x instanceof HMap || (x !== null && typeof x === "object" && x.blStruct instanceof Kw); }
export function hasKeyI(k, m) {
  // a plain map holding no `:__struct__` entry answers inline; the struct
  // protocol owns every other case (a struct class, the `:__struct__` key)
  if (m instanceof HMap && !(k instanceof Kw && k.fq === "__struct__")) return m.has(k);
  return SP.hasKey(k, m);
}
export function mapGetI(k, m) { if (m instanceof HMap) { const v = m.get(k, NO_KEY); if (v !== NO_KEY) return v; } return SP.mapGet(k, m, NO_KEY) === NO_KEY ? bad("map_get " + printStr(k), m) : SP.mapGet(k, m, null); }
export function mapsGet3I(k, m, d) { return m instanceof HMap ? m.get(k, d) : SP.mapGet(k, m, d); }
/** `(list* a b rest)`: the heads consed onto `rest` (shared, unforced). */
export function listStar(heads, rest) { let r = rest; for (let i = heads.length - 1; i >= 0; i--) r = new Cons(heads[i], r); return r; }
export const isAtom = (x) => x instanceof Kw || x === true || x === false || x === null;
export const isBool = (x) => x === true || x === false;
/** `erlang:length/1`: a PROPER list's length (a Cons carries it), badarg on
    anything else — an improper (lazy-tailed) chain included, as on the BEAM. */
export function length(l) {
  if (l === EMPTY) return 0;
  if (l instanceof Cons && l.n >= 0) return l.n;
  return bad("length", l);
}
