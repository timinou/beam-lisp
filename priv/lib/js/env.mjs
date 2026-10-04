// priv/lib/js/env.mjs — the namespace/var registry for Beam Lisp compiled to
// JS: the JS twin of priv/host/env.bl (BeamLisp.Env), as LEAVES.
//
// The self-hosted compiler asks the registry the same questions on both
// targets: what does `name` resolve to in `ns`, is it linked (a defn with a
// known arity table), is it a macro, what does an alias point to. On the BEAM
// the answers live in ETS rows keyed by tuples; here they live in one Map
// keyed by the SAME tuple shapes, printed to a string:
//
//   {ns, name}            the var's value
//   {:link, ns, name}     {module, %{arity => fname}, {min, fname} | nil}
//   {:alias, ns, a}       the namespace alias `a` stands for in ns
//   {:refer, ns, name}    the namespace `name` was referred from
//   {:import, ns, short}  an imported host class
//   {:meta, ns, name}     the var's metadata map
//   {:ns, ns}             the namespace exists
//
// One registry per page (a Worker owns its own). There is no env CHAIN here:
// the browser compiler runs one environment.
//
// `fetch!`/`lookup` resolve with BeamLisp.Env's candidate order: the name in
// `ns`, then where it was referred from, then `core`, then `sugar`; a
// qualified `a/b` goes through the alias table.

import * as R from "./rt.mjs";
const { Tup, Kw, BLError } = R;

const OK = R.kw("ok"), ERROR = R.kw("error");
const T = (...xs) => new Tup(xs);
const ROWS = new Map();
let CURRENT_NS = "user";
let EPOCH = 0;

/** A registry key: the printed tuple (keys are small strings/keywords). */
const key = (k) => (k instanceof Tup ? k.items.map(keyPart).join("\u0001") : keyPart(k));
const keyPart = (x) => (x instanceof Kw ? ":" + x.fq : typeof x === "string" ? "s" + x : R.printStr(x));

export function putKey(k, v) { ROWS.set(key(k), v); EPOCH++; return OK; }
export function deleteKey(k) { ROWS.delete(key(k)); EPOCH++; return OK; }
export function lookup(k) { const kk = key(k); return ROWS.has(kk) ? T(OK, ROWS.get(kk)) : ERROR; }
const get = (k) => ROWS.get(key(k));
const has = (k) => ROWS.has(key(k));

const kw = (s) => R.kw(s);
function candidates(ns, name) {
  const i = name.indexOf("/");
  if (i > 0 && i < name.length - 1) {
    const p0 = name.slice(0, i), rest = name.slice(i + 1);
    const at = get(T(kw("alias"), ns, p0));
    return [[at === undefined ? p0 : at, rest]];
  }
  const plain = i === 0 ? name : name;
  const out = [[ns, plain]];
  const src = get(T(kw("refer"), ns, plain));
  if (src !== undefined) out.push([src, plain]);
  out.push(["core", plain], ["sugar", plain]);
  return out;
}
function resolve(ns, name, rowOf) {
  for (const [n, s] of candidates(ns, name)) {
    const kk = rowOf(n, s);
    if (ROWS.has(kk)) return [n, ROWS.get(kk)];
  }
  return null;
}
const varRow = (n, s) => key(T(n, s));
const linkRow = (n, s) => key(T(kw("link"), n, s));

export const ENV = {
  current_ns: () => CURRENT_NS,
  in_ns: (ns) => { CURRENT_NS = ns; putKey(T(kw("ns"), ns), true); return OK; },
  declare_ns: (ns) => putKey(T(kw("ns"), ns), true),
  "ns_exists?": (ns) => has(T(kw("ns"), ns)),
  "loaded_ns?": (ns) => has(T(kw("ns"), ns)),
  intern: (ns, name, v) => { putKey(T(ns, name), v); return v; },
  lookup,
  put_key: putKey,
  delete_key: deleteKey,
  fetch: (ns, name) => { const r = resolve(ns, name, varRow); return r ? T(OK, r[1]) : ERROR; },
  "fetch!": (ns, name) => {
    const r = resolve(ns, name, varRow);
    if (!r) throw new BLError("undefined var: " + ns + "/" + name);
    return r[1];
  },
  peek: (ns, name) => { const r = resolve(ns, name, varRow); return r ? T(OK, r[1]) : ERROR; },
  "bound?": (ns, name) => resolve(ns, name, varRow) !== null,
  link: (ns, name) => { const r = resolve(ns, name, linkRow); return r ? T(OK, r[1]) : ERROR; },
  link_owner: (ns, name) => { const r = resolve(ns, name, linkRow); return r ? T(OK, r[0], r[1]) : ERROR; },
  put_link: (ns, name, info) => putKey(T(kw("link"), ns, name), info),
  add_alias: (ns, a, target) => putKey(T(kw("alias"), ns, a), target),
  alias_target: (ns, a) => { const v = get(T(kw("alias"), ns, a)); return v === undefined ? null : v; },
  add_refer: (ns, name, src) => putKey(T(kw("refer"), ns, name), src),
  refer_source: (ns, name) => { const v = get(T(kw("refer"), ns, name)); return v === undefined ? null : v; },
  add_import: (ns, short, q) => putKey(T(kw("import"), ns, short), q),
  import_target: (ns, short) => { const v = get(T(kw("import"), ns, short)); return v === undefined ? null : v; },
  meta: (ns, name) => { const v = get(T(kw("meta"), ns, name)); return v === undefined ? null : v; },
  put_meta: (ns, name, m) => {
    const prev = get(T(kw("meta"), ns, name));
    let merged = prev || R.EMPTY_MAP;
    for (const [k, v] of m.entries()) merged = merged.assoc(k, v);
    return putKey(T(kw("meta"), ns, name), merged);
  },
  // a JS page has no capability table: every op is allowed, `caps` is :all
  caps: () => kw("all"),
  "caps_allowed?": () => true,
  op_of: () => null,
  "local_var?": (ns, name) => has(T(ns, name)),
  doc_string: (ns, name) => { const m = ENV.meta(ns, name); return m ? m.get(kw("doc"), null) : null; },
};

/** The current registry epoch (bumped by every write), for callers that cache. */
export function epoch() { return EPOCH; }
/** Forget everything (tests; a fresh Worker starts empty anyway). */
export function reset() { ROWS.clear(); CURRENT_NS = "user"; EPOCH++; }
