// test/js/perf/ratio.mjs HAND_OUT SELF_OUT [MAX_RATIO]
// Compiled core (--self-host) against hand-written core.mjs on the same
// benches, run interleaved in ONE process so machine load hits both alike.
// Prints `bench  hand  self  ratio`; exits 1 when any ratio > MAX_RATIO.
// PLAN-163 U3 gate: MAX_RATIO 1.5.
import fs from "node:fs";
const [hand, self, maxArg] = process.argv.slice(2);
const max = Number(maxArg ?? "1.5");
const load = async (out) => {
  const ns = fs.existsSync(out + "/ns/perf.mjs") ? out + "/ns" : out;
  return import(ns + "/perf.mjs");
};
const H = await load(hand), S = await load(self);
const names = Object.keys(H).filter((k) => k.startsWith("d_p_")).sort();
const med = (xs) => xs.slice().sort((a, b) => a - b)[xs.length >> 1];
let worst = 0, failed = [];
for (const k of names) {
  for (let i = 0; i < 3; i++) { H[k](); S[k](); }
  const th = [], ts = [];
  for (let i = 0; i < 9; i++) {
    let t = performance.now(); H[k](); th.push(performance.now() - t);
    t = performance.now(); S[k](); ts.push(performance.now() - t);
  }
  const r = med(ts) / med(th);
  worst = Math.max(worst, r);
  if (r > max) failed.push(k);
  console.log(k.slice(4).padEnd(12), med(th).toFixed(2).padStart(8), med(ts).toFixed(2).padStart(8), r.toFixed(2).padStart(6) + "x");
}
console.log("worst " + worst.toFixed(2) + "x (gate " + max + "x)" + (failed.length ? " FAIL: " + failed.join(" ") : " ok"));
process.exit(failed.length ? 1 : 0);
