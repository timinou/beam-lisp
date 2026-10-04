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
import { ENV } from "./env.mjs";
import { LAZY_LEAVES } from "./lazy.mjs";
import { HOST_LEAVES, bindTable } from "./host-leaves.mjs";
import { LINKS, OPS } from "./core-links.mjs";
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
  // On the BEAM a vector/set/map value is a struct: `map_get(:meta, v)` reads
  // its metadata field. The JS collections carry the same field as `.meta`.
  "erlang/map_get/2": (k, m) => {
    if (k === R.kw("meta") && (m instanceof Vec || m instanceof R.HSet || m instanceof R.Cons)) return m.meta ?? null;
    const v = m.get(k, MISSING); if (v === MISSING) badarg("map_get", k); return v;
  },
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
  "lists/sort/1": (l) => list(arr(l).sort(R.termCompare)),
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
  "Elixir.BeamLisp.Decimal/unscaled/1": (d) => (d.u >= BigInt(Number.MIN_SAFE_INTEGER) && d.u <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(d.u) : d.u),
  "Elixir.BeamLisp.Decimal/scale/1": (d) => d.s,
  "Elixir.BeamLisp.Decimal/parse/1": (s) => { const d = R.parseDec(s); return d === null ? ERROR : T(OK, d); },
  "Elixir.BeamLisp.Vector/to_list/1": (v) => list(v.toArray()),
  "Elixir.BeamLisp.Vector/new/1": (l) => R.vecFromArray(C.toArray(l)),
  "Elixir.BeamLisp.Set/to_list/1": (s) => list(s.elements().sort(R.compare)),
  // core/to-list: any BL collection (or nil) as a plain list
  "Elixir.BeamLisp.Ns.Core/to-list/1": (c) => (c === null || c === undefined ? EMPTY : isList(c) ? c : list(C.toArray(c))),
  // the data-reader registry (`#tag form`): tag name → {:symbol name}
  "Elixir.BeamLisp.Ns.Rt/data_reader/1": (tag) => (DATA_READERS.has(tag) ? T(OK, DATA_READERS.get(tag)) : ERROR),
};

// ─── the compiler's leaves (priv/boot/compiler.bl, anf.bl, diag.bl) ───────────

/** BeamLisp.Ns.<Camelized> for a namespace — Emit.module_for's rule (each
    dot-segment camelized: `reader-node` → `Reader-node`, `a.b_c` → `A.BC`). */
export function moduleFor(ns) {
  const camel = (seg) => seg.split("_").map((p) => (p ? p[0].toUpperCase() + p.slice(1) : "")).join("");
  return R.kw("Elixir.BeamLisp.Ns." + ns.split(".").map(camel).join("."));
}
// the eager collection ops the compiler runs over finite data (CompilerData)
const eagerList = (x) => (x === null || x === undefined ? [] : C.toArray(x));
const PDICT = new Map();
const nextGensym = (() => { let n = 0; return () => ++n; })();
const UNDEFINED = R.kw("undefined");
const pkey = (k) => R.printStr(k);
Object.assign(LEAVES, {
  "Elixir.BeamLisp.CompilerData/eager_map/2": (f, c) => list(eagerList(c).map((x) => C.invoke(f, x))),
  "Elixir.BeamLisp.CompilerData/eager_map/3": (f, a, b) => { const xs = eagerList(a), ys = eagerList(b), n = Math.min(xs.length, ys.length); const o = []; for (let i = 0; i < n; i++) o.push(C.invoke(f, xs[i], ys[i])); return list(o); },
  "Elixir.BeamLisp.CompilerData/eager_filter/2": (f, c) => list(eagerList(c).filter((x) => R.truthy(C.invoke(f, x)))),
  "Elixir.BeamLisp.CompilerData/eager_concat/1": (cs) => list(eagerList(cs).flatMap(eagerList)),
  "Elixir.BeamLisp.CompilerData/eager_mapcat/2": (f, c) => list(eagerList(c).flatMap((x) => eagerList(C.invoke(f, x)))),
  "Elixir.BeamLisp.CompilerData/eager_map_indexed/2": (f, c) => list(eagerList(c).map((x, i) => C.invoke(f, i, x))),
  "Elixir.BeamLisp.CompilerData/eager_distinct/1": (c) => { const out = []; let seen = R.EMPTY_SET; for (const x of eagerList(c)) if (!seen.has(x)) { seen = seen.conj(x); out.push(x); } return list(out); },

  // the process dictionary: one JS realm is one "process"
  // erlang:get/put answer the atom `undefined` for a missing key, not nil
  "erlang/get/1": (k) => (PDICT.has(pkey(k)) ? PDICT.get(pkey(k)) : UNDEFINED),
  "erlang/put/2": (k, v) => { const old = PDICT.has(pkey(k)) ? PDICT.get(pkey(k)) : UNDEFINED; PDICT.set(pkey(k), v); return old; },
  "Elixir.Process/get/2": (k, d) => (PDICT.has(pkey(k)) ? PDICT.get(pkey(k)) : d),
  "Elixir.Process/put/2": (k, v) => { const old = PDICT.has(pkey(k)) ? PDICT.get(pkey(k)) : null; PDICT.set(pkey(k), v); return old; },
  "Elixir.System/unique_integer/1": (() => { let n = 0; return () => ++n; })(),

  // regex (the compiler compiles one pattern: the gensym name shape)
  "Elixir.Regex/compile!/1": (src) => new RegExp(src),
  "Elixir.Regex/run/2": (re, s) => { const m = re.exec(s); return m ? list([...m].map((g) => (g === undefined ? "" : g))) : null; },

  "erlang/function_exported/3": () => false,
  "erlang/is_float/1": (x) => x instanceof R.Flt,
  // `float_to_binary(f, [:short])`: the shortest round-tripping digits, always
  // with a `.` (0.1, 100.0, 1.0e21) — JS's shortest digits, Erlang's spelling
  "erlang/float_to_binary/2": (f) => {
    const v = f instanceof R.Flt ? f.v : f;
    let s = String(v);
    if (/e/.test(s)) { let [m, e] = s.split("e"); if (!m.includes(".")) m += ".0"; return m + "e" + (e.startsWith("+") ? e.slice(1) : e); }
    return s.includes(".") || !Number.isFinite(v) ? s : s + ".0";
  },
  "Elixir.Integer/to_string/2": (n, base) => n.toString(base).toUpperCase(),
  "erlang/is_number/1": (x) => R.isNumber(x),
  "erlang/is_bitstring/1": (x) => typeof x === "string",
  "lists/sort/2": (f, l) => list(arr(l).sort((a, b) => (R.truthy(C.invoke(f, a, b)) ? -1 : 1))),
  "maps/filter/2": (f, m) => { let o = R.EMPTY_MAP; for (const [k, v] of m.entries()) if (R.truthy(C.invoke(f, k, v))) o = o.assoc(k, v); return o; },
  "maps/without/2": (ks, m) => { let o = m; for (const k of arr(ks)) o = o.dissoc(k); return o; },

  "Elixir.BeamLisp.Link/module_for/1": moduleFor,
  // a JS compile never loads beams: there is nothing for settle to rebuild
  "Elixir.BeamLisp.Link/settle/0": () => OK,
  "Elixir.BeamLisp.Tiers/boot_namespaces/0": () => list(["anf", "compiler", "core", "diag", "lower", "optimize", "reader", "reader-node", "rt", "sugar"]),
  "Elixir.BeamLisp.Record/record_module?/1": () => false,
  "Elixir.BeamLisp.Record/deftype_module?/1": () => false,
  // metadata on values (core's meta/with-meta/vary-meta are these on BEAM)
  "Elixir.BeamLisp.FormMeta/meta/1": C.meta,
  "Elixir.BeamLisp.FormMeta/with_meta/2": C.with_meta,
  "Elixir.BeamLisp.FormMeta/vary_meta/2": C.vary_meta,

  // defserver codegen tables (priv/host/server.bl, verbatim)
  "Elixir.BeamLisp.Server/callback/1": (n) => ({ "init": T(R.kw("init"), 1, R.kw("vector")), "handle-call": T(R.kw("handle_call"), 3, R.kw("pattern")), "handle-cast": T(R.kw("handle_cast"), 2, R.kw("pattern")), "handle-info": T(R.kw("handle_info"), 2, R.kw("pattern")), "handle-continue": T(R.kw("handle_continue"), 2, R.kw("vector")), "terminate": T(R.kw("terminate"), 2, R.kw("vector")) }[n] ?? null),
  "Elixir.BeamLisp.Server/callback_order/0": () => list(["init", "handle_call", "handle_cast", "handle_info", "handle_continue", "terminate", "code_change"].map(R.kw)),

  // the loader, in a page: every namespace the page has is already loaded
  // (built in), so probes answer from the registry and loads are no-ops
  "Elixir.BeamLisp.Loader/ensure_loaded/1": () => OK,
  // the readiness guard the compiler puts before a direct call into another
  // namespace (when that namespace was already loaded at compile time)
  "Elixir.BeamLisp.Loader/ensure_ready/1": () => OK,
  "Elixir.BeamLisp.Loader/load_provider/1": () => OK,
  "Elixir.BeamLisp.Loader/maybe_load_macro/2": () => null,
  "Elixir.BeamLisp.Loader/resolvable?/1": (ns) => ENV["ns_exists?"](ns),
  "Elixir.BeamLisp.Loader/source_decl/2": () => null,

  // core/rt functions the compiler reaches by MODULE name (not linked as core
  // globals): their BL definitions, on the JS value model
  "Elixir.BeamLisp.Ns.Core/tuple__bl_v/1": (xs) => new Tup(arr(xs)),
  "Elixir.BeamLisp.Ns.Core/run!/2": (f, coll) => { for (const x of C.toArray(coll)) C.invoke(f, x); return null; },
  "Elixir.BeamLisp.Ns.Rt/call_shape_error/2": (v, arity) => "cannot call " + R.printStr(v) + " with " + arity + " argument" + (arity === 1 ? "" : "s") + " — it is not a function",
  "Elixir.BeamLisp.Server/module_for/2": (ns, name) => {
    const camel = (seg) => seg.split(/[-_]/).map((p) => (p ? p[0].toUpperCase() + p.slice(1) : "")).join("");
    return R.kw("Elixir.BeamLisp.Server." + (ns + "." + name).split(".").map(camel).join("."));
  },
  "Elixir.BeamLisp.Server/return_constructors/0": () => R.EMPTY_MAP,
  // `~@`: a vector or list spreads, nil is empty, a map yields its entries
  // as {k, v} tuples (rt/k-splice) — the tail is shared
  "Elixir.BeamLisp.Ns.Rt/splice/2": (spliced, tail) => {
    const xs = spliced === null || spliced === undefined ? [] : spliced instanceof HMap ? spliced.entries().map(([k, v]) => T(k, v)) : C.toArray(spliced);
    let r = tail === null || tail === undefined ? EMPTY : tail;
    for (let i = xs.length - 1; i >= 0; i--) r = new Cons(xs[i], r);
    return r;
  },
  // a fresh symbol DATUM in the `base__N__auto` shape (rt/print-gensym)
  "Elixir.BeamLisp.Ns.Rt/gensym/0": () => T(R.kw("symbol"), "G__" + nextGensym() + "__auto"),
  "Elixir.BeamLisp.Ns.Rt/gensym/1": (p) => T(R.kw("symbol"), (p instanceof Kw ? p.fq : String(p)) + "__" + nextGensym() + "__auto"),
  "Elixir.BeamLisp.Env/op_of/2": (mod, fun) => null,
  "Elixir.BeamLisp.Env/caps_allowed?/2": (mod, op) => true,

  // errors
  "Elixir.BeamLisp.CompileError/exception/1": (opts) => { const e = new BLError(kwGet(opts, "message") ?? "compile error"); e.blData = opts; return e; },
  "Elixir.RuntimeError/exception/1": (msg) => new BLError(typeof msg === "string" ? msg : R.printStr(msg)),
});
/** `[{:message m} …]` keyword-list option lookup. */
function kwGet(opts, k) {
  if (opts instanceof HMap) return opts.get(R.kw(k), null);
  for (const p of arr(opts)) if (p instanceof Tup && p.items[0] === R.kw(k)) return p.items[1];
  return null;
}

// ─── js/run: evaluate emitted JS in this realm (priv/lib/js/eval.bl) ─────────
//
// The text is a function body from js.emit with run-time linking: `G(ns,
// name)` reads the live registry (then core), `X("mod/fun/arity")` a core
// op or a leaf. `R`/`C` are the runtime and core modules.
const MACRO = R.kw("$macro");
// namespaces whose functions ARE core.mjs functions on this target (the BEAM
// implements them in BL over Erlang; the meaning is the same)
const NATIVE_NS = new Set(["clojure.string", "clojure.core"]);
const STRING_REVERSE = (s) => [...s].reverse().join("");
function G(ns, name) {
  const slash = name.indexOf("/");
  if (slash > 0) {
    const q = name.slice(0, slash), n = name.slice(slash + 1);
    const target = ENV.alias_target(ns, q) ?? q;
    if (NATIVE_NS.has(target)) {
      if (target === "clojure.string" && n === "reverse") return STRING_REVERSE;
      if (Object.prototype.hasOwnProperty.call(C.CORE, n)) return C.CORE[n];
    }
  }
  const r = ENV.fetch(ns, name);
  if (r instanceof Tup) {
    const v = r.items[1];
    // a macro value is {:$macro fn}; called as a fn it is its fn
    return v instanceof Tup && v.items[0] === MACRO ? v.items[1] : v;
  }
  if (Object.prototype.hasOwnProperty.call(C.CORE, name)) return C.CORE[name];
  throw new BLError("undefined var: " + ns + "/" + name);
}
// a linked core op (`Elixir.BeamLisp.Ns.Rt/first/1`) is its CORE function
function X(lk) {
  if (Object.prototype.hasOwnProperty.call(LEAVES, lk)) return LEAVES[lk];
  // `clojure.string/upper-case/1` and friends: a native namespace's fn
  const parts = lk.split("/");
  if (parts.length === 3 && NATIVE_NS.has(parts[0])) return G("user", parts[0] + "/" + parts[1]);
  const k = OPS[lk];
  if (k !== undefined && Object.prototype.hasOwnProperty.call(C.CORE, k)) return C.CORE[k];
  throw new BLError("no JS implementation for " + lk);
}
// seed the registry with BEAM's core links, so the compiler in JS links
// core calls exactly as the BEAM compiler does
for (const [name, info] of LINKS) ENV.put_link("core", name, info);
ENV.declare_ns("core");
/** Run one emitted function body. A page installs it as its `js/run` host
    fn: `globalThis.BL_HOST = { run }` before importing js.eval's build. */
export function run(body) { return new Function("R", "C", "G", "X", body)(R, C, G, X); }

// BeamLisp.LazySeq / SeqCursor / Deferred / LazyMemo.seen — lazy.mjs
Object.assign(LEAVES, LAZY_LEAVES);
// what compiled core.bl/rt.bl reach (host-leaves.mjs). Leaves ALREADY above
// keep their entry: they were measured first for the compiler's own sources.
for (const [k, f] of Object.entries(HOST_LEAVES)) if (!Object.prototype.hasOwnProperty.call(LEAVES, k)) LEAVES[k] = f;
bindTable(LEAVES);

// BeamLisp.Env — the namespace/var registry (env.mjs), every function at
// the arity the BL sources call it with
for (const [name, fn] of Object.entries(ENV)) LEAVES["Elixir.BeamLisp.Env/" + name + "/" + fn.length] = fn;

/** `#tag` → reader symbol node, registered with `registerDataReader`. */
const DATA_READERS = new Map();
export function registerDataReader(tag, symName) { DATA_READERS.set(tag, T(R.kw("symbol"), symName)); }

const MISSING = { missing: true };

/** The declared leaf names, for the build's linker. */
export const NAMES = Object.keys(LEAVES);
