// priv/lib/js/boot.mjs — start Beam Lisp in a JS realm: load the language's
// own MACROS (and any support declaration the compiled base does not already
// provide) from priv/boot/core.bl and sugar.bl, through the self-hosted
// compiler compiled to JS (js.eval).
//
// The compiled base already provides the core FUNCTIONS (out/ns/core.mjs,
// runtime and clojure prelude): boot never reinstalls them. What a page still
// needs from source is everything that runs at COMPILE time — `when`, `->`,
// `cond`, `case`, `for`, `doseq` … — because the compiler's macro lookup reads
// a macro from the LIVE registry (`Env/peek`), which the compiled module's
// exports do not populate. So boot evaluates, in source order, every
// `defmacro`, and every `def`/`defn` whose name the compiled namespaces (or the
// registry) do not already bind. Forms that only make sense on the BEAM (the
// doc-copying `prim-docs-installed`) fail to evaluate and are reported, not
// fatal.
//
//   const { evalForm, evalString, readForms } = await boot(readFile)
//
// `readFile(relPath)` returns a source's text (fs in node, fetch in a page).
//
// The compiled namespaces live under ./ns/ (`ns-file`); the runtime (rt.mjs,
// abi.mjs, leaves.mjs …) and this file live at the out root.

import * as R from "./rt.mjs";
import { ENV } from "./env.mjs";
import { REST_FNS } from "./core-links.mjs";
import { mangle } from "./host-leaves.mjs";
// the compiled base, loaded first so a `provided` check sees its exports; the
// entry (js.eval) imports base.mjs, so the whole base is ready on first import
import * as E from "./ns/js.eval.mjs";
import * as Rd from "./ns/reader.mjs";
import * as CompiledCore from "./ns/core.mjs";
import * as CompiledSugar from "./ns/sugar.mjs";

const META = R.kw("meta"), LIST = R.kw("list"), SYMBOL = R.kw("symbol");
const unmeta = (n) => (n instanceof R.Tup && n.items[0] === META ? n.items[1] : n);
const symName = (x) => (x instanceof R.Tup && x.items[0] === SYMBOL ? x.items[1] : null);

/** Is `ns/name` already provided — by the compiled namespace's export or a
    live registry binding? A compiled `defn` is not interned as a var, so the
    module's `d_<mangle name>` is the answer for it; a name the page rebound
    (or a per-env value) wins through `Env/bound?`. */
const PROVIDED = { core: CompiledCore, sugar: CompiledSugar };
function provided(ns, name) {
  const m = PROVIDED[ns];
  if (m !== undefined && m["d_" + mangle(name)] !== undefined) return true;
  return ENV["bound?"](ns, name);
}

/** The reader's position-bearing forms of `src`, as a JS array. */
export function readForms(src, file) {
  const out = [];
  for (let p = Rd["d_read$Ustring"](src, file); p instanceof R.Cons; p = p.t) out.push(p.h);
  return out;
}

/** [head, name] of a top-level `(head name …)` form, or null. */
function headAndName(form) {
  const f = unmeta(form);
  if (!(f instanceof R.Tup && f.items[0] === LIST)) return null;
  const items = [];
  for (let q = f.items[1]; q instanceof R.Cons && items.length < 2; q = q.t) items.push(unmeta(q.h));
  const head = symName(items[0]), name = symName(items[1]);
  return head && name ? [head, name] : null;
}

function loadSource(ns, src, file, record) {
  ENV.in_ns(ns);
  const failed = [];
  let n = 0;
  for (const form of readForms(src, file)) {
    const hn = headAndName(form);
    if (!hn) continue;
    const [head, name] = hn;
    // a macro is never in the compiled exports the compiler's `macro-lookup`
    // reads, so it is always loaded; a def/defn is loaded only when the
    // compiled base (or a live binding) does not already provide it
    const wanted = head === "defmacro" ||
      ((head === "def" || head === "defn" || head === "defn-") && !provided(ns, name));
    if (!wanted) continue;
    try {
      const v = record ? record(ns, name, head, () => E.d_eval_form(form)) : E.d_eval_form(form);
      n++;
    } catch (e) { failed.push(name + ": " + e.message); }
  }
  return { ns, loaded: n, failed };
}

// ─── the boot cache: the same definitions, already compiled ────────────────────
//
// Compiling core's macros in the page is ~95% of boot, and its output is a
// pure function of core.bl + sugar.bl + the compiler. `bl js build` runs
// `capture` once (in node) and writes `boot-cache.mjs`: per definition, the
// emitted JS body. A page with the cache REPLAYS it — the same `run` the
// evaluator uses, so a cached definition and a compiled one are the same
// value — and only falls back to compiling when the cache is absent.

/** Run the boot, recording every definition's emitted JS. Returns the cache
    module's text. */
function bindPreload(ns, module, names) {
  PROVIDED[ns] = module;
  ENV.declare_ns(ns);
  for (const name of names) ENV.intern(ns, name, module["d_" + mangle(name)]);
}

export async function capture(readFile, preloads = []) {
  setup();
  const entries = [], bindings = [];
  let current = null;
  // the emitted modules bound BL_HOST's object at import, so record by
  // mutating THAT object's `run` (the evaluator calls H["run"] through it)
  const hostRun = globalThis.BL_HOST.run;
  globalThis.BL_HOST.run = (body) => { if (current) current.bodies.push(body); return hostRun(body); };
  // a definition is cached only when it evaluated: a failing one (a BEAM-only
  // form) is left out, as the compiling boot reports and skips it
  // a defn/def's body RETURNS its value and eval-form interns it; a defmacro's
  // body interns itself. The entry says which, so replay binds the same way.
  const record = (ns, name, head, thunk) => {
    current = { ns, name, bodies: [], intern: head !== "defmacro" };
    try { const v = thunk(); entries.push(current); return v; } finally { current = null; }
  };
  try {
    for (const [ns, file] of SOURCES) loadSource(ns, await readFile(file), file, record);
    for (const [ns, file, text] of preloads) {
      const module = await import("./ns/" + ns + ".mjs");
      const source = text ?? await readFile(file);
      const names = readForms(source, file).map(headAndName).filter(hn => hn &&
        ["def", "defn", "defn-"].includes(hn[0]) && Object.hasOwn(module, "d_" + mangle(hn[1]))).map(hn => hn[1]);
      bindPreload(ns, module, names);
      bindings.push([ns, names]);
      const report = loadSource(ns, source, file, record);
      if (report.failed.length) throw new Error("preload " + ns + ": " + report.failed.join("; "));
    }
  } finally { globalThis.BL_HOST.run = hostRun; }
  return "// GENERATED by `bl js build` (boot.mjs capture) — do not edit.\n" +
    "// core.bl/sugar.bl's definitions, compiled to JS by the self-hosted compiler.\n" +
    "export const PRELOADS = " + JSON.stringify(bindings) + ";\n" +
    "export const ENTRIES = " + JSON.stringify(entries.map((e) => [e.ns, e.name, e.bodies, e.intern])) + ";\n";
}

const SOURCES = [["core", "priv/boot/core.bl"], ["sugar", "priv/boot/sugar.bl"]];

/** Declare the core link table's variadic fns to the emitter (core-links.mjs
    REST_FNS) — before ANY compile, captured or live. */
function setup() { E["d_set_rest_fns$B"](R.listFromArray(REST_FNS.map((t) => R.vecFromArray(t)))); }

/** Load core.bl's and sugar.bl's definitions — from the boot cache when the
    build wrote one (replayed in source order), else by compiling them here.
    Returns the evaluator and what loaded. */
export async function boot(readFile) {
  const t0 = typeof performance !== "undefined" ? performance.now() : 0;
  setup();
  const report = [];
  const cache = await import("./boot-cache.mjs").catch(() => null);
  if (cache && cache.ENTRIES && cache.ENTRIES.length) {
    for (const [ns, names] of cache.PRELOADS || [])
      bindPreload(ns, await import("./ns/" + ns + ".mjs"), names);
    const byNs = new Map();
    for (const [ns, name, bodies, intern] of cache.ENTRIES) {
      ENV.in_ns(ns);
      const r = byNs.get(ns) || { ns, loaded: 0, failed: [], cached: true };
      try {
        // a defn/def's last body yields its value: bind it as eval-form does
        let v = null;
        for (const b of bodies) v = globalThis.BL_HOST.run(b);
        if (intern) ENV.intern(ns, name, v);
        r.loaded++;
      } catch (e) { r.failed.push(name + ": " + e.message); }
      byNs.set(ns, r);
    }
    report.push(...byNs.values());
  } else {
    for (const [ns, file] of SOURCES) report.push(loadSource(ns, await readFile(file), file));
  }
  ENV.in_ns("user");
  return {
    R, Env: ENV, report,
    ms: (typeof performance !== "undefined" ? performance.now() : 0) - t0,
    readForms,
    evalForm: (f) => E.d_eval_form(f),
    evalString: (s) => E.d_eval_string(s),
  };
}
