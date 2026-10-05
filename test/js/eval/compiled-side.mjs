// test/js/eval/compiled-side.mjs — run the zero-argument case functions of the
// synthetic corpus namespaces that `bl js build` compiled from
// test/js/eval/*.bl (see test/bl/js_diff_test.bl), printing one
// `<namespace>#<i>\t<value>` line per case.
//
// The printing protocol is test/js/eval/js-side.mjs's: a language fn prints
// `#fn` — a real JS function (a compiled defn) OR a raw `{:$blfn …}` tuple,
// which is how the runtime represents a fn value it did not compile in place
// (a seed row, a runtime-built multi-fn). The `:__macro` sentinel a generated
// macro case returns prints `#macro`, and an escaping error prints
// `#error <message>` exactly as the BEAM side records it. The BEAM side prints
// the ORIGINAL corpus forms with the same labels; test/js/diff/compare.mjs
// canonicalizes map/set order and diffs the two files.
//
//   node test/js/eval/compiled-side.mjs <out-dir> <namespace>:<count> ...
//
// `<out-dir>` is a filesystem path or a file:// URL. Every case `d_f0 …
// d_f<count-1>` must exist and be callable: a missing or non-function case is a
// HARD failure (exit 2), so an empty or vacuous corpus can never look like a
// pass. The umbrella `eval.corpus.all` (which imports every corpus namespace
// AND ns/base.mjs) is loaded first when named, so the base namespaces' registry
// effects happen before any case runs.
import { pathToFileURL } from "node:url";
import path from "node:path";

const args = process.argv.slice(2);
if (args.length < 2) {
  console.error("usage: compiled-side.mjs <out-dir> <namespace>:<count> ...");
  process.exit(2);
}

// accept a path or a file:// URL, and always end with a slash so `new URL` of
// a relative module specifier resolves inside the out dir
const outArg = args[0];
const out = (outArg.startsWith("file:") ? outArg : pathToFileURL(path.resolve(outArg)).href)
  .replace(/\/?$/, "/");

const specs = args.slice(1).map((s) => {
  const i = s.lastIndexOf(":");
  const ns = i > 0 ? s.slice(0, i) : "";
  const count = Number(s.slice(i + 1));
  if (ns === "" || !Number.isInteger(count) || count <= 0) {
    console.error("bad case spec: " + s);
    process.exit(2);
  }
  return { ns, count };
});

const R = await import(new URL("rt.mjs", out).href);
const BLFN = R.kw("$blfn");
const MACRO = R.kw("__macro");

// a language fn is a real JS function OR the raw `{:$blfn …}` tuple compiled
// core uses for a multi-arity/variadic fn — never an arbitrary tuple (a
// `{:meta …}` wrapper, say), so match the actual `$blfn` tag by identity
const isLangFn = (v) =>
  typeof v === "function" ||
  (v instanceof R.Tup && v.items.length > 0 && v.items[0] instanceof R.Kw && v.items[0].fq === BLFN.fq);
const show = (v) => isLangFn(v) ? "#fn"
  : (v instanceof R.Kw && v.fq === MACRO.fq) ? "#macro"
  : R.printStr(v);

// load ns/base.mjs: it imports rt/core/sugar/the clojure prelude for
// their registry effects (seeds, `vector`, …) exactly as a page does. The
// build's entry imports it too, but the runner must load it first.
await import(new URL("ns/base.mjs", out).href);
const umbrella = specs.find((s) => s.ns === "eval.corpus.all");
if (umbrella) await import(new URL("ns/" + umbrella.ns + ".mjs", out).href);

let cases = 0;
const missing = [];
for (const { ns, count } of specs) {
  const M = await import(new URL("ns/" + ns + ".mjs", out).href);
  for (let i = 0; i < count; i++) {
    const f = M["d_f" + i];
    if (typeof f !== "function") {
      missing.push(ns + "#" + i + " (" + ("d_f" + i) + ")");
      continue;
    }
    let s;
    try { s = show(f()); }
    catch (e) { s = "#error " + e.message; }
    console.log(ns + "#" + i + "\t" + s);
    cases++;
  }
}

if (missing.length > 0) {
  console.error("compiled-side: " + missing.length + " missing/nonfunction case(s): " + missing.join(", "));
  process.exit(2);
}
if (cases <= 0) {
  console.error("compiled-side: no cases executed");
  process.exit(2);
}
console.error("compiled-side: " + cases + " case(s)");
