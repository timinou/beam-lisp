// test/js/reader/js-side.mjs — print `read-all` of each file with the reader
// COMPILED TO JS (bl js build reader -p priv/boot), in beam-side.bl's shape.
//   node test/js/reader/js-side.mjs <out-dir> a.bl b.bl …
import { pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";
import { canon } from "./canon.mjs";
const out = path.resolve(process.argv[2]);
const Rd = await import(pathToFileURL(path.join(out, "reader.mjs")).href);
const R = await import(pathToFileURL(path.join(out, "rt.mjs")).href);
for (const p of process.argv.slice(3)) {
  let s;
  try { s = canon(R, Rd.d_read_all(fs.readFileSync(p, "utf8"))); } catch (e) { s = "#error " + e.message; }
  console.log(p + "\t" + s);
}
