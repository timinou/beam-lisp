// test/js/diff/compare.mjs — compare BEAM and JS printings of the corpus.
//   node test/js/diff/compare.mjs <beam.out> <js.out>
// Each file holds `<case>\t<pr-str>` lines. Map/set entry order is
// canonicalized first (BEAM's small-map order follows the atom table;
// FUP-141). Prints SAME/DIFF per case and a summary; exit 0 iff all agree.
import { canon } from "./canon.mjs";
import fs from "node:fs";

const read = (f) => Object.fromEntries(fs.readFileSync(f, "utf8").trim().split("\n")
  .map((l) => { const i = l.indexOf("\t"); return [l.slice(0, i), l.slice(i + 1)]; }));
const b = read(process.argv[2]), j = read(process.argv[3]);
let bad = 0;
for (const k of Object.keys(b)) {
  const bc = canon(b[k]), jc = canon(j[k] ?? "#missing");
  if (bc === jc) { console.log("SAME  " + k); continue; }
  bad++;
  const bs = bc.split(" "), js = jc.split(" ");
  let i = 0; while (i < bs.length && bs[i] === js[i]) i++;
  console.log("DIFF  " + k + " at token " + i + ":\n  beam: …" + bs.slice(Math.max(0, i - 3), i + 6).join(" ")
    + "\n  js:   …" + js.slice(Math.max(0, i - 3), i + 6).join(" "));
}
console.log(bad === 0 ? "diff: all " + Object.keys(b).length + " cases identical" : "diff: " + bad + " case(s) differ");
process.exit(bad === 0 ? 0 : 1);
