// apps/bl-ed/test/bench.mjs — per-keystroke latency of the COMPILED editor
// core (state in → state out, no DOM), on a real document.
//   BLED_OUT=apps/bl-ed/web/out node apps/bl-ed/test/bench.mjs [file.bl.org]
// Prints p50/p95 in ms for each action, plus the JS selftest result. The
// browser frame adds render + DOM on top (measured separately in host.mjs).
import path from "node:path";
import fs from "node:fs";
import { pathToFileURL } from "node:url";

const out = path.resolve(process.env.BLED_OUT || "apps/bl-ed/web/out");
const M = await import(pathToFileURL(path.join(out, "ed.main.mjs")).href);
const R = await import(pathToFileURL(path.join(out, "rt.mjs")).href);
const S = await import(pathToFileURL(path.join(out, "ed.selftest.mjs")).href).catch(() => null);
const file = process.argv[2] || "docs/changelog/v2026.4.bl.org";
const src = fs.readFileSync(file, "utf8");
const K = (s) => R.kw(s);
const key = (ed, k) => M.d_handle(ed, R.hashMap(K("type"), K("key"), K("key"), k));

function measure(label, n, step, ed0) {
  let ed = ed0; const t = [];
  for (let i = 0; i < n; i++) { const a = performance.now(); ed = step(ed, i); t.push(performance.now() - a); }
  t.sort((a, b) => a - b);
  const q = (p) => t[Math.min(t.length - 1, Math.floor(p * t.length))].toFixed(2);
  console.log(`${label.padEnd(10)} p50 ${q(0.5)} ms  p95 ${q(0.95)} ms  (n=${n})`);
  return ed;
}

let ed = M.d_boot(src, file);
const lines = src.split("\n").length;
console.log(`${file}: ${lines} lines`);
const a = performance.now(); M.d_boot(src, file); console.log(`boot      ${(performance.now() - a).toFixed(1)} ms`);
for (let i = 0; i < 20; i++) ed = key(ed, "j");          // warm
ed = measure("j", 200, (e) => key(e, "j"), ed);
ed = measure("w", 200, (e) => key(e, "w"), ed);
ed = measure("]h", 60, (e) => key(e, "]") && key(key(e, "]"), "h"), ed);
ed = key(ed, "i");
ed = measure("type", 300, (e, i) => key(e, "abcdefghij"[i % 10]), ed);
ed = key(ed, "Escape");
measure("u", 100, (e) => key(e, "u"), ed);
if (S && S.d_run) {
  const r = S.d_run();
  console.log(`JS selftest: ${r.get(K("pass"))} pass, ${r.get(K("fail")).count ?? r.get(K("fail")).size ?? 0} fail`);
}
