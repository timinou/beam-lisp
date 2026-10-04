// priv/lib/js/leaves.mjs — the host leaves: the BEAM primitives Beam Lisp's own
// source calls, implemented once for JavaScript (PLAN-163 U1).
//
// The compiler's own namespaces (reader, compiler, core, rt …) are Beam Lisp,
// but at the bottom they call BEAM primitives: `erlang/element`, `lists/split`,
// `string/to_integer`, `unicode/characters_to_list` … A namespace compiled to
// JS links each such call to `LEAVES["mod/fun/arity"]` here, at BUILD time
// (priv/lib/js/build.bl); a call with no entry is a build error that names it.
//
// Each leaf has the BEAM function's semantics on the JS value model (rt.mjs):
//
//   Erlang list    a BL list (Cons … EMPTY). A "charlist" is a list of
//                  codepoint integers, as on the BEAM.
//   Erlang tuple   Tup. `{:ok, v}` is `tup([kw("ok"), v])`.
//   atom           Kw (a BL keyword IS an atom on the BEAM).
//   binary         a JS string (only UTF-8 text binaries reach these leaves).
//   map            HMap.
//
// A leaf is small and obviously right, or it is not a leaf: logic belongs in
// Beam Lisp, compiled here from the same source the BEAM runs.

import * as R from "./rt.mjs";
import * as C from "./core.mjs";
const { EMPTY, Cons, Tup, Kw, HMap, Vec, BLError } = R;

const OK = R.kw("ok"), ERROR = R.kw("error");
const T = (...xs) => new Tup(xs);
const isList = (x) => x === EMPTY || x instanceof Cons;
const arr = (l) => { const a = []; for (let p = l; p instanceof Cons; p = p.t) a.push(p.h); return a; };
const list = (a) => R.listFromArray(a);
const atomName = (a) => (a instanceof Kw ? a.fq : String(a));
const badarg = (what, x) => { throw new BLError("errors were found at the given arguments: " + what + " " + R.printStr(x)); };

// ─── charlists ↔ strings ───────────────────────────────────────────────────

function cpsToString(cps) {
  // a "chardata" list: codepoints, nested lists, or binaries (strings)
  let s = "";
  const walk = (l) => {
    for (let p = l; p instanceof Cons; p = p.t) {
      const h = p.h;
      if (typeof h === "number") s += String.fromCodePoint(h);
      else if (typeof h === "string") s += h;
      else if (isList(h)) walk(h);
      else badarg("chardata", h);
    }
  };
  if (typeof cps === "string") return cps;
  walk(cps);
  return s;
}
function stringToCps(s) {
  const a = [];
  for (const ch of s) a.push(ch.codePointAt(0));
  return list(a);
}

// ─── string:to_integer / to_float on a charlist ────────────────────────────
// {Int, Rest} or {error, no_integer}: the LONGEST valid prefix is consumed,
// exactly as Erlang does (a leading sign is part of the number).

function toInteger(cs) {
  const a = arr(cs);
  let i = 0;
  if (a[i] === 43 || a[i] === 45) i++;
  const d0 = i;
  while (i < a.length && a[i] >= 48 && a[i] <= 57) i++;
  if (i === d0) return T(ERROR, R.kw("no_integer"));
  const text = String.fromCodePoint(...a.slice(0, i));
  const n = BigInt(text);
  return T(normInt(n), list(a.slice(i)));
}
function normInt(n) { return (n >= BigInt(Number.MIN_SAFE_INTEGER) && n <= BigInt(Number.MAX_SAFE_INTEGER)) ? Number(n) : n; }

function toFloat(cs) {
  // Erlang requires digits '.' digits, optional exponent; no float → no_float
  const a = arr(cs);
  const s = String.fromCodePoint(...a);
  const m = /^[+-]?\d+\.\d+(?:[eE][+-]?\d+)?/.exec(s);
  if (!m) return T(ERROR, R.kw("no_float"));
  const rest = [...s.slice(m[0].length)].map((c) => c.codePointAt(0));
  return T(R.flt(parseFloat(m[0])), list(rest));
}

// ─── the table ─────────────────────────────────────────────────────────────

export const LEAVES = {
  // erlang
  "erlang/element/2": (i, t) => (t instanceof Tup && i >= 1 && i <= t.items.length ? t.items[i - 1] : badarg("element", t)),
  "erlang/tuple_size/1": (t) => (t instanceof Tup ? t.items.length : badarg("tuple_size", t)),
  "erlang/is_tuple/1": (x) => x instanceof Tup,
  "erlang/is_list/1": (x) => isList(x),
  "erlang/is_atom/1": (x) => x instanceof Kw || x === true || x === false || x === null,
  "erlang/list_to_tuple/1": (l) => new Tup(arr(l)),
  "erlang/tuple_to_list/1": (t) => list(t.items),
  "erlang/hd/1": (l) => (l instanceof Cons ? l.h : badarg("hd", l)),
  "erlang/tl/1": (l) => (l instanceof Cons ? l.t : badarg("tl", l)),
  "erlang/binary_to_atom/1": (s) => R.kw(s),
  "erlang/atom_to_binary/1": (a) => (a === null ? "nil" : a === true ? "true" : a === false ? "false" : atomName(a)),
  "erlang/binary_to_list/1": (s) => {
    // BYTES of the UTF-8 binary, as on the BEAM
    const b = new TextEncoder().encode(s); return list(Array.from(b));
  },
  "erlang/byte_size/1": (s) => new TextEncoder().encode(s).length,
  "erlang/binary_part/3": (s, start, len) => new TextDecoder().decode(new TextEncoder().encode(s).subarray(start, start + len)),
  "erlang/map_get/2": (k, m) => { const v = m.get(k, MISSING); if (v === MISSING) badarg("map_get", k); return v; },
  "erlang/map_size/1": (m) => m.cnt,
  "erlang/trunc/1": (x) => (x instanceof R.Flt ? Math.trunc(x.v) : x),
  "erlang/length/1": (l) => arr(l).length,

  // lists
  "lists/reverse/1": (l) => list(arr(l).reverse()),
  // `b` is shared as the tail, as on the BEAM
  "lists/append/2": (a, b) => { const xs = arr(a); let r = b; for (let i = xs.length - 1; i >= 0; i--) r = new Cons(xs[i], r); return r; },
  "lists/last/1": (l) => { const a = arr(l); if (!a.length) badarg("last", l); return a[a.length - 1]; },
  "lists/member/2": (x, l) => arr(l).some((y) => R.keyEq(x, y)),
  // The SECOND half of a split is the original list's own tail, never a copy:
  // BEAM shares it, and the reader walks a cursor until it is `identical?` to
  // that tail (reader/advance-to) — a copy makes every token walk to the end
  // of the source, O(n²) over a file. Only the prefix is rebuilt.
  "lists/split/2": (n, l) => {
    const pre = []; let p = l;
    for (let i = 0; i < n; i++) { if (!(p instanceof Cons)) badarg("split", n); pre.push(p.h); p = p.t; }
    return T(list(pre), p);
  },
  "lists/splitwith/2": (f, l) => {
    const pre = []; let p = l;
    while (p instanceof Cons && R.truthy(C.invoke(f, p.h))) { pre.push(p.h); p = p.t; }
    return T(list(pre), p);
  },
  "lists/sublist/2": (l, n) => { const a = []; for (let p = l; p instanceof Cons && a.length < n; p = p.t) a.push(p.h); return list(a); },
  "lists/sublist/3": (l, start, n) => list(arr(l).slice(start - 1, start - 1 + n)),
  "lists/sort/1": (l) => list(arr(l).sort(R.compare)),
  "lists/nth/2": (n, l) => arr(l)[n - 1],

  // maps
  "maps/new/0": () => R.EMPTY_MAP,
  "maps/put/3": (k, v, m) => m.assoc(k, v),
  "maps/get/2": (k, m) => { const v = m.get(k, MISSING); if (v === MISSING) badarg("maps:get", k); return v; },
  "maps/get/3": (k, m, d) => m.get(k, d),
  "maps/is_key/2": (k, m) => m.has(k),
  "maps/from_list/1": (l) => { let m = R.EMPTY_MAP; for (const p of arr(l)) m = m.assoc(p.items[0], p.items[1]); return m; },
  "maps/to_list/1": (m) => list([...m.entries()].map(([k, v]) => T(k, v))),
  "maps/merge/2": (a, b) => { let m = a; for (const [k, v] of b.entries()) m = m.assoc(k, v); return m; },
  "maps/keys/1": (m) => list([...m.entries()].map(([k]) => k)),
  "maps/size/1": (m) => m.cnt,
  "maps/remove/2": (k, m) => m.dissoc(k),

  // string (Erlang's, over charlists)
  "string/to_integer/1": toInteger,
  "string/to_float/1": toFloat,
  "string/cspan/2": (cs, delims) => {
    // the length of the prefix of `cs` containing no char of `delims` — a
    // walk that stops at the first delimiter, not a copy of the whole list
    const d = new Set(arr(delims)); let i = 0;
    for (let p = cs; p instanceof Cons && !d.has(p.h); p = p.t) i++;
    return i;
  },

  // unicode
  "unicode/characters_to_list/1": (s) => (typeof s === "string" ? stringToCps(s) : stringToCps(cpsToString(s))),
  "unicode/characters_to_binary/1": (cs) => cpsToString(cs),

  // Beam Lisp host modules the reader reaches
  // the atom-table guard: JS has no atom table to exhaust, so accounting is a no-op
  "Elixir.BeamLisp.AtomGuard/account!/1": () => OK,
  "Elixir.BeamLisp.AtomGuard/reset/0": () => OK,
  "Elixir.BeamLisp.AtomGuard/check!/1": () => OK,
  "Elixir.BeamLisp.AtomGuard/to_atom/1": (s) => R.kw(s),
  "Elixir.BeamLisp.Decimal/parse/1": (s) => { const d = R.parseDec(s); return d === null ? ERROR : T(OK, d); },
  "Elixir.BeamLisp.Vector/to_list/1": (v) => list(v.toArray()),
  "Elixir.BeamLisp.Vector/new/1": (l) => R.vecFromArray(C.toArray(l)),
  "Elixir.BeamLisp.Set/to_list/1": (s) => list(s.elements().sort(R.compare)),
  // core/to-list: any BL collection (or nil) as a plain list
  "Elixir.BeamLisp.Ns.Core/to-list/1": (c) => (c === null || c === undefined ? EMPTY : isList(c) ? c : list(C.toArray(c))),
  // the data-reader registry (`#tag form`): tag name → {:symbol name}
  "Elixir.BeamLisp.Ns.Rt/data_reader/1": (tag) => (DATA_READERS.has(tag) ? T(OK, DATA_READERS.get(tag)) : ERROR),
};

/** `#tag` → reader symbol node, registered with `registerDataReader`. */
const DATA_READERS = new Map();
export function registerDataReader(tag, symName) { DATA_READERS.set(tag, T(R.kw("symbol"), symName)); }

const MISSING = { missing: true };

/** The declared leaf names, for the build's linker. */
export const NAMES = Object.keys(LEAVES);
