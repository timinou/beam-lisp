// priv/lib/js/host-leaves.mjs — the leaves core.bl and rt.bl reach when they
// are COMPILED to JS (PLAN-163 U2): Erlang BIFs and Elixir/BeamLisp host
// module functions, each with the BEAM's answer on the JS value model.
//
// Every answer here was measured on the BEAM first (2026-10-04,
// ~/tmp/bljs/sh/leafprobe.bl) — `(String/split "a,b,,c" ",")` is
// ("a" "b" "" "c"), `(erlang/max 1 2.0)` is 2.0, `(erlang/bnot 5)` -6 — and
// test/js/eval/leaves.bl pins them as a differential.
//
// THE TAG PROTOCOL (PLAN-163 U2 contract C1). rt.bl classifies a host value
// the BEAM way: a struct is a map whose `:__struct__` names its module, and the
// ONE kind table (rt.bl literal-struct-kind) maps that module to a kind. JS
// answers the same question about its own classes through the same leaves:
// `erlang/is_map` is true for every struct-backed class, and `:__struct__`
// reads the class's module atom. Field layouts are NOT imitated: a field read
// on a struct-backed value is the owning host module's business (contract C2).

import * as R from "./rt.mjs";
import * as Z from "./lazy.mjs";
// `invoke`/`toArray` are the CALLING CONVENTION (a keyword or map called as a
// fn), which the emitter itself uses; they live in core.mjs until U3 moves
// them into rt.mjs with the rest of the convention.
import * as C from "./core.mjs";
const { EMPTY, Cons, Tup, Kw, HMap, HSet, Vec, Flt, Dec, BLError } = R;

const kw = (s) => R.kw(s);
const T = (...xs) => new Tup(xs);
const L = (a) => R.listFromArray(a);
const arr = (l) => { const a = []; for (let p = l; p instanceof Cons; p = p.t) a.push(p.h); return a; };
const isList = (x) => x === EMPTY || x instanceof Cons;
const bool = (x) => x === true || x === false;

/** An Erlang-shaped raise: an `ArgumentError` / `badarg` the BEAM would give. */
function badarg(what) { const e = new BLError("errors were found at the given arguments: " + what); e.blType = kw("Elixir.ArgumentError"); throw e; }

// ─── the tag protocol ────────────────────────────────────────────────────────

const STRUCT = kw("__struct__");
/** The module atom a struct-backed JS value answers for `:__struct__`, or
    undefined for a value that is not a struct (a plain map, a scalar …).
    ONE property read: every struct-backed class carries `blStruct` on its
    PROTOTYPE (set once below, or by the class itself: Regex, Sorted …), so
    the hottest leaf of compiled core (rt.bl's classifier asks it per value)
    is not an instanceof chain. */
export function structTag(x) {
  if (x === null || typeof x !== "object") return undefined;
  const t = x.blStruct;
  return t instanceof Kw ? t : undefined;
}
for (const [cls, mod] of [[Vec, "Vector"], [HSet, "Set"], [Z.LazySeq, "LazySeq"], [Dec, "Decimal"],
                          [R.Atom, "Atom"], [Z.Delay, "Delay"], [Z.SeqCursor, "SeqCursor"]]) {
  Object.defineProperty(cls.prototype, "blStruct", { value: kw("Elixir.BeamLisp." + mod), writable: false });
}
/** `is_map` on the BEAM is true for every struct: a struct IS a map. */
export const isMap = (x) => x instanceof HMap || (x !== null && typeof x === "object" && x.blStruct instanceof Kw);

const MISSING = {};
function mapGet(k, m, dflt) {
  // a plain map is checked FIRST: a struct rt.bl builds BY HAND
  // (`(maps/put :__struct__ :"Elixir.BeamLisp.Reduced" (maps/new))`) is an
  // HMap carrying the key itself, exactly the BEAM's representation
  if (m instanceof HMap) return m.get(k, dflt);
  if (k === STRUCT) { const t = structTag(m); if (t !== undefined) return t; }
  if (k === kw("meta") && m instanceof Cons) return m.meta ?? null;
  if (structTag(m) !== undefined) {
    // a struct-backed value's own fields (contract C2 moves rt.bl off these)
    if (m.blFields && Object.prototype.hasOwnProperty.call(m.blFields, k.fq)) return m.blFields[k.fq];
    // the metadata field a vector/set/lazy seq carries (`:meta` on the BEAM)
    if (k === kw("meta") || k === kw("metadata")) return m.meta ?? null;
    return dflt;
  }
  return badarg("not a map: " + R.printStr(m));
}

// ─── Erlang term arithmetic and comparison (`erlang/+` as a VALUE, not an op) ─

const num = (x) => (x instanceof Flt ? x.v : x);
export const ERLANG = {
  "erlang/+/2": (a, b) => R.add(a, b),
  "erlang/-/2": (a, b) => R.sub(a, b),
  "erlang/*/2": (a, b) => R.mul(a, b),
  "erlang/div/2": (a, b) => R.quot(a, b),
  "erlang/rem/2": (a, b) => R.rem(a, b),
  "erlang/abs/1": (a) => (a instanceof Flt ? R.flt(Math.abs(a.v)) : typeof a === "bigint" ? (a < 0n ? -a : a) : Math.abs(a)),
  "erlang/bnot/1": (a) => (typeof a === "bigint" ? ~a : ~a),
  "erlang/==/2": (a, b) => erlEq(a, b),
  "erlang//=/2": (a, b) => !erlEq(a, b),
  "erlang/=/=/2": (a, b) => !R.keyEq(a, b),
  "erlang/=:=/2": (a, b) => R.keyEq(a, b),
  "erlang/</2": (a, b) => R.termCompare(a, b) < 0,
  "erlang/>/2": (a, b) => R.termCompare(a, b) > 0,
  "erlang/=</2": (a, b) => R.termCompare(a, b) <= 0,
  "erlang/>=/2": (a, b) => R.termCompare(a, b) >= 0,
  "erlang/=/2": (a, b) => { if (!R.keyEq(a, b)) { const e = new BLError("no match of right hand side value " + R.printStr(b)); e.blType = kw("Elixir.MatchError"); throw e; } return b; },
  "erlang/and/2": (a, b) => { if (!bool(a) || !bool(b)) badarg("and"); return a && b; },
  "erlang/max/2": (a, b) => (R.termCompare(a, b) < 0 ? b : a),
  "erlang/++/2": (a, b) => { const xs = arr(a); let r = b; for (let i = xs.length - 1; i >= 0; i--) r = new Cons(xs[i], r); return r; },

  "erlang/is_map/1": isMap,
  "erlang/is_map_key/2": (k, m) => (k === STRUCT ? structTag(m) !== undefined || (m instanceof HMap && m.has(k)) : m instanceof HMap ? m.has(k) : mapGet(k, m, MISSING) !== MISSING),
  "erlang/is_binary/1": (x) => typeof x === "string",
  "erlang/is_boolean/1": bool,
  "erlang/is_integer/1": (x) => R.isInt(x),
  "erlang/is_function/1": (x) => typeof x === "function",
  // arity: a compiled JS fn's `length` is its fixed arity; a multi-arity
  // dispatcher (`...args`) answers 0 there, so it also accepts any arity
  "erlang/is_function/2": (x, n) => typeof x === "function" && (x.length === n || x.length === 0),
  "erlang/is_pid/1": () => false,
  "erlang/is_port/1": () => false,
  "erlang/is_reference/1": (x) => x !== null && typeof x === "object" && x.blRef === true,

  "erlang/make_tuple/2": (n, x) => new Tup(new Array(n).fill(x)),
  "erlang/setelement/3": (i, t, v) => { if (!(t instanceof Tup) || i < 1 || i > t.items.length) badarg("setelement"); const a = t.items.slice(); a[i - 1] = v; return new Tup(a); },
  "erlang/integer_to_binary/1": (n) => String(n),
  "erlang/iolist_to_binary/1": (x) => iolist(x),
  "erlang/atom_to_binary/2": (a) => (a === null ? "nil" : a === true ? "true" : a === false ? "false" : a.fq),
  "erlang/binary_to_atom/2": (s) => (s === "nil" ? null : s === "true" ? true : s === "false" ? false : kw(s)),

  // a call through a VALUE (`apply f args`): a JS fn spreads the list; a
  // keyword/map/set/vector called as a fn is core's `invoke`
  "erlang/apply/2": (f, args) => (typeof f === "function" ? f(...arr(args)) : C.invoke(f, ...arr(args))),
  "erlang/apply/3": (m, f, args) => applyMFA(m, f, arr(args)),
  // `fun M:F/A` as a value: resolved against the leaf table and the self-host
  // module table at CALL time (rt's seed captures its own exports this way)
  // The target is resolved on the FIRST call and kept (a seeded core fn — `+`,
  // `map` — is a make_fun capture, called in every loop); not at creation,
  // because rt's seed captures core functions before core has loaded.
  "erlang/make_fun/3": (m, f, a) => {
    const k = (m instanceof Kw ? m.fq : String(m)) + "/" + (f instanceof Kw ? f.fq : String(f)) + "/" + a;
    let target = null;
    const g = (...xs) => (target ??= resolveKey(k))(...xs);
    Object.defineProperty(g, "length", { value: a });
    return g;
  },
  "erlang/error/1": (reason) => { throw reason instanceof Error ? reason : Object.assign(new BLError(R.printStr(reason)), { data: reason }); },
  "erlang/raise/3": (_kind, reason, _stack) => { throw reason; },
};
const erlEq = (a, b) => R.erlEq(a, b);

/** iodata → string: binaries, codepoint ints, nested lists. */
function iolist(x) {
  if (typeof x === "string") return x;
  let s = "";
  const walk = (l) => {
    for (let p = l; p instanceof Cons; p = p.t) {
      const h = p.h;
      if (typeof h === "number") s += String.fromCodePoint(h);
      else if (typeof h === "string") s += h;
      else if (isList(h)) walk(h);
      else badarg("iolist " + R.printStr(h));
    }
  };
  walk(x);
  return s;
}

// `erlang/apply :lists :reverse …` — a call to a host module by atom. Resolved
// against the leaf table at CALL time (the table is complete by then).
let TABLE = null;
export function bindTable(t) { TABLE = t; }
function applyMFA(m, f, args) {
  return applyKey((m instanceof Kw ? m.fq : String(m)) + "/" + (f instanceof Kw ? f.fq : String(f)) + "/" + args.length, args);
}
/** `mod/fun/arity` → a leaf, or a function of a namespace compiled into this
    build (registered by module name: `Elixir.BeamLisp.Ns.Rt/first/1`). */
const MODULES = new Map();
export function registerModule(modName, exports) { MODULES.set(modName, exports); }
function applyKey(k, args) { return resolveKey(k)(...args); }
/** The function `mod/fun/arity` names: a leaf, else a compiled namespace's
    export (a `f__bl_v` name is the variadic clause, `.v`). */
function resolveKey(k) {
  const fn = TABLE && TABLE[k];
  if (fn !== undefined) return fn;
  const i = k.lastIndexOf("/"), j = k.lastIndexOf("/", i - 1);
  const mod = k.slice(0, j), fun = k.slice(j + 1, i);
  const ex = MODULES.get(mod);
  if (ex) {
    const v = fun.endsWith("__bl_v");
    const g = ex["d_" + mangle(v ? fun.slice(0, -6) : fun)];
    if (typeof g === "function") return v && typeof g.v === "function" ? g.v : g;
  }
  throw new BLError("no JS implementation for " + k);
}
/** js.emit's `mangle` (priv/lib/js/emit.bl), for looking a BEAM function
    name up in a compiled module's exports. Injective, as there: letters and
    digits pass, `-`→`_`, `_`→`$U`, punctuation by name, a leading digit gains
    `$N`, a reserved word `$R`. emit.bl is the authority; test/js/rt.test.mjs
    pins this copy against names it emitted. */
const RESERVED = new Set("break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof new return super switch this throw try typeof var void while with yield let static enum await implements package protected interface private public null true false arguments eval".split(" "));
const PUNCT = { 45: "_", 95: "$U", 63: "$Q", 33: "$B", 42: "$S", 62: "$G", 60: "$L", 61: "$E", 43: "$P", 47: "$D", 46: "$O", 39: "$T" };
export function mangle(name) {
  let out = "";
  for (const ch of name) {
    const c = ch.codePointAt(0);
    out += (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) ? ch : PUNCT[c] ?? "$" + c + "$";
  }
  if (out.length && out.charCodeAt(0) >= 48 && out.charCodeAt(0) <= 57) out = "$N" + out;
  return RESERVED.has(out) ? out + "$R" : out;
}

// ─── lists / maps ────────────────────────────────────────────────────────────

const call = (f, ...a) => (typeof f === "function" ? f(...a) : C.invoke(f, ...a));
export const LISTS = {
  "lists/map/2": (f, l) => L(arr(l).map((x) => call(f, x))),
  "lists/filter/2": (f, l) => L(arr(l).filter((x) => call(f, x) === true)),
  "lists/flatmap/2": (f, l) => L(arr(l).flatMap((x) => arr(call(f, x)))),
  "lists/foreach/2": (f, l) => { for (const x of arr(l)) call(f, x); return kw("ok"); },
  "lists/foldl/3": (f, acc, l) => { let a = acc; for (const x of arr(l)) a = call(f, x, a); return a; },
  "lists/foldr/3": (f, acc, l) => { const xs = arr(l); let a = acc; for (let i = xs.length - 1; i >= 0; i--) a = call(f, xs[i], a); return a; },
  "lists/any/2": (f, l) => arr(l).some((x) => call(f, x) === true),
  "lists/duplicate/2": (n, x) => L(new Array(n).fill(x)),
  "lists/nthtail/2": (n, l) => { let p = l; for (let i = 0; i < n; i++) { if (!(p instanceof Cons)) badarg("nthtail"); p = p.t; } return p; },
  "lists/join/2": (sep, l) => { const xs = arr(l), o = []; xs.forEach((x, i) => { if (i) o.push(sep); o.push(x); }); return L(o); },
  "lists/droplast/1": (l) => { const xs = arr(l); if (!xs.length) badarg("droplast"); return L(xs.slice(0, -1)); },
  "maps/map/2": (f, m) => { let o = R.EMPTY_MAP; for (const [k, v] of m.entries()) o = o.assoc(k, call(f, k, v)); return o; },
  // an iterator is the remaining entry list; `next` answers {k, v, it'} | :none
  "maps/iterator/1": (m) => T(kw("bl_map_iter"), L(m.entries().map(([k, v]) => T(k, v)))),
  "maps/next/1": (it) => { const l = it.items[1]; if (!(l instanceof Cons)) return kw("none"); return T(l.h.items[0], l.h.items[1], T(kw("bl_map_iter"), l.t)); },
  "Elixir.Map/delete/2": (m, k) => m.dissoc(k),
  "Elixir.Enum/join/2": (l, sep) => arr(l).map((x) => R.strOf(x)).join(sep),
  "Elixir.Enum/to_list/1": (x) => (isList(x) ? x : L(C.toArray(x))),
  "binary/split/2": (s, sep) => { const i = s.indexOf(sep); return i < 0 ? L([s]) : L([s.slice(0, i), s.slice(i + sep.length)]); },
  "maps/get/3": (k, m, d) => mapGet(k, m, d),
  "maps/get/2": (k, m) => { const v = mapGet(k, m, MISSING); if (v === MISSING) { const e = new BLError("key " + R.printStr(k) + " not found"); e.blType = kw("Elixir.KeyError"); throw e; } return v; },
  "erlang/map_get/2": (k, m) => { const v = mapGet(k, m, MISSING); if (v === MISSING) badarg("map_get " + R.printStr(k)); return v; },
};

// ─── Elixir String (graphemes, as the BEAM) ─────────────────────────────────

const SEG = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
const graphemes = (s) => (SEG ? [...SEG.segment(s)].map((g) => g.segment) : [...s]);
// Elixir's `String.trim` family strips Unicode whitespace
const WS = "[\\s\\u0085\\u180e]";
export const STRING = {
  "Elixir.String/split/1": (s) => L(s.split(new RegExp(WS + "+")).filter((x) => x !== "")),
  "Elixir.String/split/2": (s, sep) => L(sep === "" ? graphemes(s) : s.split(sep)),
  "Elixir.String/split/3": (s, sep, opts) => {
    let parts = arr(opts).find((o) => o instanceof Tup && o.items[0] === kw("parts"));
    const trim = arr(opts).some((o) => o instanceof Tup && o.items[0] === kw("trim") && o.items[1] === true);
    let xs;
    if (parts) { const n = parts.items[1]; xs = []; let rest = s; while (xs.length < n - 1) { const i = rest.indexOf(sep); if (i < 0) break; xs.push(rest.slice(0, i)); rest = rest.slice(i + sep.length); } xs.push(rest); }
    else xs = s.split(sep);
    return L(trim ? xs.filter((x) => x !== "") : xs);
  },
  "Elixir.String/graphemes/1": (s) => L(graphemes(s)),
  "Elixir.String/length/1": (s) => graphemes(s).length,
  "Elixir.String/slice/3": (s, start, len) => graphemes(s).slice(start, start + len).join(""),
  "Elixir.String/replace/3": (s, a, b) => s.split(a).join(b),
  "Elixir.String/trim/1": (s) => s.replace(new RegExp("^" + WS + "+|" + WS + "+$", "g"), ""),
  "Elixir.String/trim_leading/1": (s) => s.replace(new RegExp("^" + WS + "+"), ""),
  "Elixir.String/trim_trailing/1": (s) => s.replace(new RegExp(WS + "+$"), ""),
  "Elixir.String/contains?/2": (s, x) => s.includes(x),
  "Elixir.String/starts_with?/2": (s, x) => s.startsWith(x),
  "Elixir.String/ends_with?/2": (s, x) => s.endsWith(x),
  "Elixir.String/upcase/1": (s) => s.toUpperCase(),
  "Elixir.String/downcase/1": (s) => s.toLowerCase(),
  "Elixir.String/to_atom/1": (s) => kw(s),
};

// ─── Regex: Elixir's %Regex{} (PCRE) as a JS RegExp ──────────────────────────
// The source text is kept (`~r/…/` prints it); matching uses a `u`-flag RegExp.
// PCRE and JS agree on the patterns Clojure code writes (classes, groups,
// anchors, quantifiers); PCRE-only syntax (possessive `++`, `(?<name>…)` is
// shared) raises at compile, named. Answers measured on the BEAM: `run`
// drops TRAILING unmatched groups ((a)(x)?b on "zab" → ("ab" "a")), a
// replacement's `\1` is group 1, `{:global false}` replaces once.
export class Regex {
  constructor(source) {
    this.source = source; this.blStruct = kw("Elixir.Regex");
    try { this.re = new RegExp(source, "u"); }
    catch (e) { const err = new BLError("regex " + JSON.stringify(source) + " is not supported on the JS target: " + e.message); err.blType = kw("Elixir.Regex.CompileError"); throw err; }
  }
  global() { return new RegExp(this.re.source, "gu"); }
}
const trimGroups = (m) => { const a = [...m].map((x) => (x === undefined ? "" : x)); let n = m.length; while (n > 1 && m[n - 1] === undefined) n--; return L(a.slice(0, n)); };
const jsTemplate = (t) => t.replace(/\$/g, "$$$$").replace(/\\(\d)/g, "$$$1");
const reOpts = (o) => new Map(arr(o).map((t) => [t.items[0].fq, t.items[1]]));
export const REGEX = {
  "Elixir.Regex/compile!/1": (s) => new Regex(s),
  "Elixir.Regex/regex?/1": (x) => x instanceof Regex,
  "Elixir.Regex/source/1": (r) => r.source,
  "Elixir.Regex/run/2": (r, s) => { const m = r.re.exec(s); return m ? trimGroups(m) : null; },
  "Elixir.Regex/scan/2": (r, s) => L([...s.matchAll(r.global())].map(trimGroups)),
  "Elixir.Regex/replace/3": (r, s, rep) => repl(r, s, rep, true),
  "Elixir.Regex/replace/4": (r, s, rep, o) => repl(r, s, rep, reOpts(o).get("global") !== false),
  "Elixir.String/replace/4": (s, pat, rep, o) => {
    const g = reOpts(o).get("global") !== false;
    if (pat instanceof Regex) return repl(pat, s, rep, g);
    return g ? s.split(pat).join(rep) : s.replace(pat, () => rep);
  },
  "Elixir.String/reverse/1": (s) => graphemes(s).reverse().join(""),
  "Elixir.String/to_charlist/1": (s) => L([...s].map((c) => c.codePointAt(0))),
  "Elixir.List/to_string/1": (l) => iolist(l),
  "erlang/list_to_binary/1": (l) => iolist(l),
  // clojure.core-ext's `macroexpand-1` reaches the compiler by module: a page
  // that carries it (`--with compiler`, as js.eval) links the real one first;
  // otherwise this names the gap instead of failing the whole build
  "Elixir.BeamLisp.Ns.Compiler/macroexpand_1/2": (f, ns) => {
    const g = TABLE && TABLE.__compiler_macroexpand_1;
    if (!g) throw new BLError("macroexpand-1 needs the compiler in this JS build (bl js build … --with compiler)");
    return g(f, ns);
  },
};
function repl(r, s, rep, global) {
  const re = global ? r.global() : r.re;
  if (typeof rep === "function") return s.replace(re, (...m) => R.strOf(call(rep, m[0])));
  return s.replace(re, jsTemplate(rep));
}
// `String.split(s, %Regex{})`: split on a pattern
const splitPlain = STRING["Elixir.String/split/2"];
STRING["Elixir.String/split/2"] = (s, sep) => (sep instanceof Regex ? L(s.split(sep.global())) : splitPlain(s, sep));

// ─── BEAM-only (contract C3): linked, and a named refusal when called ───────

const beamOnly = (k) => () => { throw new BLError(k + " runs on the BEAM only (not part of the JS target)"); };
export const BEAM_ONLY = Object.fromEntries([
  "erlang/monitor/2", "erlang/exit/2", "io/format/2",
  "Elixir.Code/ensure_loaded?/1", "crypto/hash/2", "Elixir.Base/encode16/1",
  "Elixir.BeamLisp.Trace/trace/3", "Elixir.BeamLisp.Trace/trace/4", "Elixir.BeamLisp.Trace/untrace/2",
  "Elixir.BeamLisp.Refs/spawn_exec/1", "Elixir.BeamLisp.Refs/spawn_exec/2",
].map((k) => [k, beamOnly(k)]));

export const HOST_LEAVES = { ...ERLANG, ...LISTS, ...STRING, ...REGEX, ...BEAM_ONLY };
// (COLLECTIONS, NUMBERS, REFS_ERRORS are merged in below, where they are defined)

// ─── collections: Vector / Set / Sorted / Transient ──────────────────────────
// rt.bl reaches these by module name; on JS each is the rt.mjs persistent
// structure's own operation. Answers measured on the BEAM (leafprobe2.bl).

/** A sorted collection: entries kept in the LANGUAGE's `compare` order (the
    BEAM projects that order into :gb_trees keys, host/sorted.bl encode_key;
    here the comparator is `compare` itself). Persistent by copy — the sorted
    family is small-and-ordered by use, never a hot mutable index on a page. */
export class Sorted {
  constructor(kind, es, meta) { this.kind = kind; this.es = es; this.meta = meta ?? null; this.blStruct = kw(kind === "map" ? "Elixir.BeamLisp.Sorted.SortedMap" : "Elixir.BeamLisp.Sorted.SortedSet"); }
  find(k) { let lo = 0, hi = this.es.length; while (lo < hi) { const mid = (lo + hi) >> 1; const c = R.compare(this.es[mid][0], k); if (c === 0) return mid; if (c < 0) lo = mid + 1; else hi = mid; } return -(lo + 1); }
  put(k, v) { const i = this.find(k); const es = this.es.slice(); if (i >= 0) es[i] = [k, v]; else es.splice(-(i + 1), 0, [k, v]); return new Sorted(this.kind, es, this.meta); }
  del(k) { const i = this.find(k); if (i < 0) return this; const es = this.es.slice(); es.splice(i, 1); return new Sorted(this.kind, es, this.meta); }
}
const SM = (es) => { let s = new Sorted("map", []); for (const e of es) s = s.put(e[0], e[1]); return s; };
const SS = (xs) => { let s = new Sorted("set", []); for (const x of xs) s = s.put(x, x); return s; };
const pairOf = (t) => (t instanceof Tup ? [t.items[0], t.items[1]] : t instanceof Vec ? [t.nth(0), t.nth(1)] : badarg("sorted entry " + R.printStr(t)));

class Transient { constructor(v) { this.v = v; this.blStruct = kw("Elixir.BeamLisp.Transient"); } }

export const COLLECTIONS = {
  "Elixir.BeamLisp.Vector/conj/2": (v, x) => v.conj(x),
  "Elixir.BeamLisp.Vector/assoc/3": (v, i, x) => v.assocN(i, x),
  "Elixir.BeamLisp.Vector/count/1": (v) => v.cnt,
  "Elixir.BeamLisp.Vector/first/1": (v) => (v.cnt === 0 ? null : v.nth(0)),
  "Elixir.BeamLisp.Vector/nth/2": (v, i) => v.nth(i, null),
  "Elixir.BeamLisp.Set/new/1": (l) => { let s = R.EMPTY_SET; for (const x of C.toArray(l)) s = s.conj(x); return s; },
  "Elixir.BeamLisp.Set/add/2": (s, x) => s.conj(x),
  "Elixir.BeamLisp.Set/del/2": (s, x) => s.disj(x),
  "Elixir.BeamLisp.Set/member?/2": (s, x) => s.has(x),
  "Elixir.BeamLisp.Set/count/1": (s) => s.cnt,

  "Elixir.BeamLisp.Sorted/map_new/0": () => new Sorted("map", []),
  "Elixir.BeamLisp.Sorted/map_new/1": (l) => SM(C.toArray(l).map(pairOf)),
  "Elixir.BeamLisp.Sorted/map_put/3": (m, k, v) => m.put(k, v),
  "Elixir.BeamLisp.Sorted/map_get/3": (m, k, d) => { const i = m.find(k); return i >= 0 ? m.es[i][1] : d; },
  "Elixir.BeamLisp.Sorted/map_has_key?/2": (m, k) => m.find(k) >= 0,
  "Elixir.BeamLisp.Sorted/map_delete/2": (m, k) => m.del(k),
  "Elixir.BeamLisp.Sorted/map_count/1": (m) => m.es.length,
  "Elixir.BeamLisp.Sorted/map_to_list/1": (m) => L(m.es.map(([k, v]) => T(k, v))),
  "Elixir.BeamLisp.Sorted/set_new/0": () => new Sorted("set", []),
  "Elixir.BeamLisp.Sorted/set_new/1": (l) => SS(C.toArray(l)),
  "Elixir.BeamLisp.Sorted/set_add/2": (s, x) => s.put(x, x),
  "Elixir.BeamLisp.Sorted/set_del/2": (s, x) => s.del(x),
  "Elixir.BeamLisp.Sorted/set_member?/2": (s, x) => s.find(x) >= 0,
  "Elixir.BeamLisp.Sorted/set_count/1": (s) => s.es.length,
  "Elixir.BeamLisp.Sorted/set_to_list/1": (s) => L(s.es.map(([k]) => k)),
  "Elixir.BeamLisp.Sorted/last_entry/1": (m) => (m.es.length ? (m.kind === "map" ? T(...m.es[m.es.length - 1]) : m.es[m.es.length - 1][0]) : null),
  "Elixir.BeamLisp.Sorted/last_key/1": (m) => (m.es.length ? m.es[m.es.length - 1][0] : null),
  // `{:bound v}` | :unbounded on each side; entries in order, as tuples (map) or keys (set)
  "Elixir.BeamLisp.Sorted/subseq_entries/3": (c, lo, hi) => rangeEntries(c, lo, hi, false),
  "Elixir.BeamLisp.Sorted/rsubseq_entries/3": (c, lo, hi) => rangeEntries(c, lo, hi, true),

  "Elixir.BeamLisp.Transient/transient/1": (x) => new Transient(x),
  // `hash-map`'s link row ({0 :hash_map_empty} (2 :hash_map)): rest is a LIST
  "Elixir.BeamLisp.Transient/hash_map_empty/0": () => R.EMPTY_MAP,
  "Elixir.BeamLisp.Transient/hash_map/3": (k, v, rest) => {
    const xs = arr(rest); if (xs.length % 2) badarg("hash-map requires an even number of forms, got " + (xs.length + 2));
    let m = R.EMPTY_MAP.assoc(k, v); for (let i = 0; i < xs.length; i += 2) m = m.assoc(xs[i], xs[i + 1]); return m;
  },
  "Elixir.BeamLisp.Transient/persistent!/1": (t) => t.v,
  "Elixir.BeamLisp.Transient/get/3": (t, k, d) => C.get(t.v, k, d),
};
function rangeEntries(c, lo, hi, rev) {
  const inLo = (k) => !(lo instanceof Tup) || R.compare(k, lo.items[1]) >= 0;
  const inHi = (k) => !(hi instanceof Tup) || R.compare(k, hi.items[1]) <= 0;
  const es = c.es.filter(([k]) => inLo(k) && inHi(k)).map(([k, v]) => T(k, v));
  return L(rev ? es.reverse() : es);
}

// ─── numbers: BeamLisp.Num (the language's arithmetic), Decimal, Float ──────

export const NUMBERS = {
  "Elixir.BeamLisp.Num/add/2": R.add, "Elixir.BeamLisp.Num/sub/2": R.sub,
  "Elixir.BeamLisp.Num/mul/2": R.mul, "Elixir.BeamLisp.Num/div/2": R.div,
  "Elixir.BeamLisp.Num/neg/1": (a) => R.sub(0, a),
  "Elixir.BeamLisp.Num/lt/2": R.lt, "Elixir.BeamLisp.Num/gt/2": R.gt,
  "Elixir.BeamLisp.Num/le/2": R.le, "Elixir.BeamLisp.Num/ge/2": R.ge,
  "Elixir.BeamLisp.Num/num_eq/2": R.numEq,
  "Elixir.BeamLisp.Decimal/signum/1": (d) => (d.u > 0n ? 1 : d.u < 0n ? -1 : 0),
  "Elixir.BeamLisp.Decimal/to_literal/1": (d) => d.plain() + "M",
  "Elixir.BeamLisp.Decimal/to_plain_string/1": (d) => d.plain(),
  // the exact {numerator, denominator} of a float (IEEE-754 is dyadic)
  "Elixir.Float/ratio/1": (f) => {
    let v = f instanceof Flt ? f.v : f; if (v === 0) return T(0, 1);
    let den = 1n; while (!Number.isInteger(v)) { v *= 2; den *= 2n; }
    let numr = BigInt(v); const g = (a, b) => (b === 0n ? (a < 0n ? -a : a) : g(b, a % b)); const d = g(numr, den);
    const n = (x) => (x >= BigInt(Number.MIN_SAFE_INTEGER) && x <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(x) : x);
    return T(n(numr / d), n(den / d));
  },
};

// ─── refs and errors: Refs / ExInfo / Exception / Record / Multi ────────────

class Volatile { constructor(v) { this.v = v; this.blStruct = kw("Elixir.BeamLisp.Volatile"); } }
function refsDeref(a) {
  if (a instanceof HMap && a.get(STRUCT, null) === kw("Elixir.BeamLisp.Reduced")) return a.get(kw("value"), null);
  if (a instanceof Volatile) return a.v;
  return C.deref(a);
}
const exMessage = (e) => (e instanceof Error ? e.message : R.printStr(e));
export const REFS_ERRORS = {
  "Elixir.BeamLisp.Refs/atom/1": (v) => C.atom(v),
  // Refs.deref reads EVERY derefable (refs.bl deref/1): atoms and volatiles
  // (`.v`), delays (forced), and the `Reduced` sentinel — a map rt.bl builds
  // by hand, `{:__struct__ Reduced, :value v}` — whose payload is `:value`
  "Elixir.BeamLisp.Refs/deref/1": (a) => refsDeref(a),
  "Elixir.BeamLisp.Refs/deref/3": (a) => refsDeref(a),
  "Elixir.BeamLisp.Refs/swap!/2": (a, f) => C.swap_BANG(a, f),
  // BEAM ABI: the extra args arrive as ONE list (Refs.swap!(a, f, args))
  "Elixir.BeamLisp.Refs/swap!/3": (a, f, rest) => C.swap_BANG(a, f, ...arr(rest)),
  "Elixir.BeamLisp.Refs/reset!/2": (a, v) => C.reset_BANG(a, v),
  "Elixir.BeamLisp.Refs/vswap!/2": (v, f) => { v.v = call(f, v.v); return v.v; },
  "Elixir.BeamLisp.Refs/vswap!/3": (v, f, rest) => { v.v = call(f, v.v, ...arr(rest)); return v.v; },
  "Elixir.BeamLisp.Refs/volatile?/1": (x) => x instanceof Volatile,
  "Elixir.BeamLisp.Refs/volatile/1": (v) => new Volatile(v),
  "Elixir.BeamLisp.Refs/vreset!/2": (v, x) => { v.v = x; return x; },
  "Elixir.BeamLisp.ExInfo/ex_info/2": (m, d) => C.ex_info(m, d),
  "Elixir.BeamLisp.ExInfo/ex_message/1": (e) => exMessage(e),
  "Elixir.BeamLisp.ExInfo/ex_data/1": (e) => (e instanceof Error ? e.data ?? null : null),
  "Elixir.BeamLisp.ExInfo/ex_original/1": (e) => (e instanceof Error && e.blOriginal !== undefined ? e.blOriginal : e),
  // `(throw x)`: an Error is thrown as is; any other payload becomes an
  // ex-info whose message is its printed form and whose data is the payload
  // when it is a map (BEAM: (throw {:k 1}) → ["{:k 1}" {:k 1}]; "str" → ["\"str\"" nil])
  "Elixir.BeamLisp.ExInfo/raise_payload/1": (x) => { if (x instanceof Error) throw x; const e = new BLError(R.printStr(x), x instanceof HMap ? x : null); e.blOriginal = x; throw e; },
  "Elixir.Exception/normalize/3": (_kind, v) => C.exception_normalize(_kind, v, null),
  "Elixir.ArgumentError/exception/1": (msg) => { const e = new BLError(typeof msg === "string" ? msg : R.printStr(msg)); e.blType = kw("Elixir.ArgumentError"); return e; },
  "Elixir.FunctionClauseError/exception/1": (opts) => {
    const o = new Map(arr(opts).map((t) => [t.items[0].fq, t.items[1]]));
    const mod = o.get("module"), m = mod instanceof Kw ? (mod.fq.startsWith("Elixir.") ? mod.fq.slice(7) : ":" + mod.fq) : String(mod);
    const e = new BLError("no function clause matching in " + m + "." + atomText(o.get("function")) + "/" + o.get("arity"));
    e.blType = kw("Elixir.FunctionClauseError"); return e;
  },
  "Elixir.BeamLisp.Record/record?/1": () => false,
  "Elixir.BeamLisp.Record/info/1": () => null,
  "Elixir.BeamLisp.Record/fields_of/1": () => EMPTY,
  "Elixir.BeamLisp.Multi/type_of/1": (x) => C.type(x),
  "Elixir.BeamLisp.Env/match/1": () => EMPTY,
  // `read-string`: the compiler namespace's reader-to-data, when this page
  // carries the compiler (a js.eval build registers `compiler/read_data`);
  // a page without one cannot read source
  "Elixir.BeamLisp.Compiler/read_data/1": (src) => {
    const f = TABLE && TABLE["Elixir.BeamLisp.Ns.Compiler/read_data/1"];
    if (!f) throw new BLError("read-string needs the compiler in this JS build (bl js build js.eval …)");
    return f(src);
  },
  "Elixir.Kernel/inspect/1": (x) => inspect(x),
  "Elixir.Kernel/inspect/2": (x) => inspect(x),
};
const atomText = (a) => (a instanceof Kw ? a.fq : String(a));

/** Elixir `inspect` of the terms the runtime's error messages carry (BEAM,
    measured): "s" → "\"s\"", :k → ":k", nil → "nil", (1 :a) → "[1, :a]",
    {1, "x"} → "{1, \"x\"}", {:a 1} → "%{a: 1}", :"Elixir.Foo" → "Foo". */
export function inspect(x) {
  if (x === null || x === undefined) return "nil";
  if (x === true || x === false) return String(x);
  if (typeof x === "string") return JSON.stringify(x);
  if (typeof x === "number" || typeof x === "bigint") return String(x);
  if (x instanceof Flt) return R.printStr(x);
  if (x instanceof Kw) return x.fq.startsWith("Elixir.") ? x.fq.slice(7) : ":" + x.fq;
  if (x === EMPTY || x instanceof Cons) return "[" + arr(x).map(inspect).join(", ") + "]";
  if (x instanceof Tup) return "{" + x.items.map(inspect).join(", ") + "}";
  if (x instanceof HMap) return "%{" + x.entries().map(([k, v]) => (k instanceof Kw ? k.fq + ": " : inspect(k) + " => ") + inspect(v)).join(", ") + "}";
  return R.printStr(x);
}

Object.assign(HOST_LEAVES, COLLECTIONS, NUMBERS, REFS_ERRORS);
