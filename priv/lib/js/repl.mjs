// priv/lib/js/repl.mjs — Beam Lisp evaluation for a page, as one host fn.
//
// A page that embeds an editor (bl-ed) or a notebook gets real Beam Lisp —
// the self-hosted reader, compiler and macros (js.eval + boot.mjs) — through
// `evalWith(src, ns, bindings)`: `bindings` (name → value) are interned into
// namespace `ns` first, so code can call `(ed/goto 5)` against the live app.
//
//   import { start } from "./repl.mjs";
//   const repl = await start(readFile);       // loads core's macros once
//   repl.evalWith("(ed/goto 5)", "ed", api)    // → {:text "nil"} | {:err "…"}
//
// The result is a BL map so BL callers read it with keywords.

import * as R from "./rt.mjs";
import * as L from "./leaves.mjs";

const TEXT = R.kw("text"), ERR = R.kw("err");

export async function start(readFile) {
  globalThis.BL_HOST = Object.assign(globalThis.BL_HOST || {}, { run: L.run });
  const B = await import("./boot.mjs");
  const vm = await B.boot(readFile);
  const evalWith = (src, ns, bindings) => {
    try {
      if (bindings) {
        vm.Env.declare_ns(ns);
        for (const [k, v] of (bindings instanceof R.HMap ? bindings.entries() : Object.entries(bindings))) vm.Env.intern(ns, k, v);
      }
      vm.Env.in_ns("user");
      const v = vm.evalString(src);
      return R.hashMap(TEXT, R.printStr(v));
    } catch (e) {
      return R.hashMap(ERR, e && e.message ? e.message : String(e));
    }
  };
  /** Evaluate document cells in order, in a fresh namespace per call (a
      cell sees the defs of the cells above it, as bl.doc's runner does):
      {:results {id "printed value"}} or {:err "…"}. A cell's result is its
      last form's value, printed with pr-str; an error is ";; error: …". */
  let runN = 0;
  const RESULTS = R.kw("results");
  const evalCells = (cells) => {
    const ns = "doc.page" + (++runN);
    vm.Env.in_ns(ns);
    let out = R.EMPTY_MAP;
    for (const c of (cells instanceof R.Vec ? cells.toArray() : cells)) {
      const id = c instanceof R.HMap ? c.get(R.kw("id"), null) : c.id;
      const code = c instanceof R.HMap ? c.get(R.kw("code"), null) : c.code;
      let s;
      try { vm.Env.in_ns(ns); s = R.printStr(vm.evalString(code)); } catch (e) { s = ";; error: " + (e && e.message ? e.message : String(e)); }
      out = out.assoc(id, s);
    }
    vm.Env.in_ns("user");
    return R.hashMap(RESULTS, out);
  };
  return { ...vm, evalWith, evalCells };
}
