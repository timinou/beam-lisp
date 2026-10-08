// test/js/eval/js-side.mjs — evaluate each top-level form of the corpus with
// Beam Lisp COMPILED TO JS (bl js build js.eval), in beam-side.bl's shape.
// core.bl's and sugar.bl's macros are loaded first from their own source, as
// a page does (priv/lib/js/boot.mjs).
//   node test/js/eval/js-side.mjs <out-dir> <corpus.bl> <repo-root>
import { pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";
const [out, corpus, root] = process.argv.slice(2).map((p) => path.resolve(p));
const load = (m) => import(pathToFileURL(path.join(out, m)).href);
const L = await load("leaves.mjs");
globalThis.BL_HOST = { run: L.run };
const B = await load("boot.mjs");
const { evalForm, readForms, R, Env } = await B.boot((f) => fs.readFileSync(path.join(root, f), "utf8"));
Env.in_ns("eval-user");
let i = 0;
for (const f of readForms(fs.readFileSync(corpus, "utf8"), "corpus")) {
  let s;
  try {
    const v = evalForm(f);
    s = typeof v === "function" ? "#fn" : v instanceof R.Tup && v.items[0] === R.kw("$macro") ? "#macro" : R.printStr(v);
  } catch (e) { s = "#error " + e.message; }
  console.log(i++ + "\t" + s);
}
