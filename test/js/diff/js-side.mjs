// test/js/diff/js-side.mjs — print every corpus case from the JS build, in
// the same `<case>\t<pr-str>` shape beam-side.bl prints.
//   node test/js/diff/js-side.mjs <out-dir-of-the-js-build>
import { pathToFileURL } from "node:url";
import path from "node:path";

const out = path.resolve(process.argv[2]);
import fs from "node:fs";
// a --self-host build puts compiled namespaces under ns/ (core and rt are
// namespaces there too); a regular build writes them at the top level
const nsDir = fs.existsSync(path.join(out, "ns", "diff.corpus.mjs")) ? path.join(out, "ns") : out;
const C = await import(pathToFileURL(path.join(nsDir, "diff.corpus.mjs")).href);
const R = await import(pathToFileURL(path.join(out, "rt.mjs")).href);
const cases = ["numbers", "equality", "collections", "seqs", "strings", "functions", "destructuring", "control"];
for (const c of cases) {
  let s;
  try { s = R.printStr(C["d_case_" + c]()); } catch (e) { s = "#error " + e.message; }
  console.log(c + "\t" + s);
}
