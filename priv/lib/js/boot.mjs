// priv/lib/js/boot.mjs — start Beam Lisp in a JS realm: load the language's
// own macros (and the helper defns they call) from priv/boot/core.bl and
// sugar.bl, through the self-hosted compiler compiled to JS (js.eval).
//
// core.mjs already provides the core FUNCTIONS natively; what a page still
// needs from core.bl is everything that runs at COMPILE time — `when`, `->`,
// `cond`, `case`, `for`, `doseq` … — and the plain defns those macros call.
// So boot evaluates, in source order, every `defmacro`, every `def`, and every
// `defn` whose name core.mjs does NOT already define. Forms that only make
// sense on the BEAM (the doc-copying `prim-docs-installed`) fail to evaluate
// and are reported, not fatal.
//
//   const { evalForm, evalString, readForms } = await boot(readFile)
//
// `readFile(relPath)` returns a source's text (fs in node, fetch in a page).

import * as R from "./rt.mjs";
import * as C from "./core.mjs";
import { ENV } from "./env.mjs";
import * as E from "./js.eval.mjs";
import * as Rd from "./reader.mjs";
import { REST_FNS } from "./core-links.mjs";

const META = R.kw("meta"), LIST = R.kw("list"), SYMBOL = R.kw("symbol");
const unmeta = (n) => (n instanceof R.Tup && n.items[0] === META ? n.items[1] : n);
const symName = (x) => (x instanceof R.Tup && x.items[0] === SYMBOL ? x.items[1] : null);

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

function loadSource(ns, src, file) {
  ENV.in_ns(ns);
  const failed = [];
  let n = 0;
  for (const form of readForms(src, file)) {
    const hn = headAndName(form);
    if (!hn) continue;
    const [head, name] = hn;
    const wanted = head === "defmacro" || head === "def" ||
      ((head === "defn" || head === "defn-") && C.CORE[name] === undefined);
    if (!wanted) continue;
    try { E.d_eval_form(form); n++; } catch (e) { failed.push(name + ": " + e.message); }
  }
  return { ns, loaded: n, failed };
}

/** Load core.bl and sugar.bl; returns the evaluator and what loaded. */
export async function boot(readFile) {
  const t0 = typeof performance !== "undefined" ? performance.now() : 0;
  E["d_set_rest_fns$B"](R.listFromArray(REST_FNS.map((t) => R.vecFromArray(t))));
  const report = [];
  for (const [ns, file] of [["core", "priv/boot/core.bl"], ["sugar", "priv/boot/sugar.bl"]]) {
    report.push(loadSource(ns, await readFile(file), file));
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
