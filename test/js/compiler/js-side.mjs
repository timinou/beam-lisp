// test/js/compiler/js-side.mjs — compile each top-level form of a file to
// bl-ANF with the compiler COMPILED TO JS, in beam-side.bl's shape.
//   node test/js/compiler/js-side.mjs <out-dir> <forms.bl>
import { pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";
import { canon } from "../reader/canon.mjs";
const out = path.resolve(process.argv[2]);
const load = (m) => import(pathToFileURL(path.join(out, m)).href);
const Cm = await load("ns/compiler.mjs"), Rd = await load("ns/reader.mjs"), R = await load("rt.mjs");
const forms = Rd["d_read$Uall"](fs.readFileSync(process.argv[3], "utf8"));
let i = 0;
for (let p = forms; p instanceof R.Cons; p = p.t, i++) {
  Cm["d_reset$Ufresh$B"]();
  let s;
  try { s = canon(R, Cm.d_compile(p.h, Cm.d_new_env("user"))); } catch (e) { s = "#error " + e.message; }
  console.log(i + "\t" + s);
}
