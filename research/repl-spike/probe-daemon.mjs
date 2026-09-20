// probe.mjs — scripted WebSocket client for the repl spike (PLAN-135 Phase 0).
// Drives eval / state persistence / completion / doc / interrupt / balanced
// against a running serve.bl and prints measured latencies.
//   node research/repl-spike/probe-daemon.mjs [port] [token]
const port = process.argv[2] || 7860;
const token = process.argv[3] || "";
const ws = new WebSocket(`ws://127.0.0.1:${port}/repl/ws?token=${token}`);
ws.onclose = (e) => console.log(`[ws closed code=${e.code} reason=${e.reason}]`);
ws.onerror = (e) => console.log(`[ws error]`);
let seq = 0; const pending = new Map();
const t = () => performance.now();

function rpc(op, fields = {}) {
  const id = ++seq;
  return new Promise((resolve) => {
    pending.set(id, { resolve, t0: t(), out: [] });
    ws.send(JSON.stringify({ op, id, ...fields }));
  });
}

ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.kind === "hello") { pending.get("hello")?.(m); return; }
  if (m.kind === "out") { pending.get(m.id)?.out.push(m.text); return; }
  const p = pending.get(m.id);
  if (!p) return;
  // terminal frames resolve; streaming frames accumulate
  if (["value", "error", "completions", "doc", "balanced", "bench", "busy", "not-busy", "interrupt-sent"].includes(m.kind)) {
    pending.delete(m.id);
    p.resolve({ ...m, rtt: Math.round(t() - p.t0), stdout: p.out.join("") });
  } else if (m.kind === "interrupt-sent") {
    // interrupt resolves when the eval's error frame arrives; note it for now
    p.interruptSent = true;
  }
};

const hello = await new Promise((res) => { pending.set("hello", res); ws.onopen = () => {}; });
console.log(`session ${hello.session} ns ${hello.ns}`);
const line = (name, ok, detail) => console.log(`${ok ? "✓" : "✗"} ${name}${detail ? " — " + detail : ""}`);

// U1: eval + session state persistence across ops
let r = await rpc("eval", { src: "(+ 1 2)" });
line("U1 eval", r.kind === "value" && r.text === "3", `${r.text} · eval ${r.ms}ms · rtt ${r.rtt}ms`);
r = await rpc("eval", { src: "(def spike-x 41)" });
const defMs = r.ms;
r = await rpc("eval", { src: "(inc spike-x)" });
line("U1 state persists", r.kind === "value" && r.text === "42", `${r.text} · rtt ${r.rtt}ms`);
r = await rpc("eval", { src: "*1" });
line("U1 *1 interned", r.kind === "value" && r.text === "42", `${r.text}`);
r = await rpc("eval", { src: "(println \"hello from eval\") (flush) :done" });
line("U1 stdout streaming", r.stdout.includes("hello from eval"), JSON.stringify(r.stdout.trim()));
r = await rpc("eval", { src: "(in-ns (quote spike.other)) (def y 1) (in-ns (quote user))" });
line("U1 ns switch survives", true, `ns now ${r.ns}`);

// U2: completion timings
for (const prefix of ["m", "str", "datom"]) {
  const c = await rpc("complete", { prefix });
  line(`U2 complete "${prefix}"`, c.items.length > 0,
    `${c.items.length}/${c.total} shown · scanned ${c.scanned} · server ${c.ms}ms · rtt ${c.rtt}ms`);
}
const b = await rpc("bench");
line("U2 bench", true, `corpus ${b.corpus} · index build ${b["index-build-ms"]}ms · direct 5q×10 ${b["direct-5q-x10-ms"]}ms · indexed 5q×100 ${b["indexed-5q-x100-ms"]}ms`);

// doc
r = await rpc("complete", { prefix: "map" });
console.log("  map-ish candidates:", r.items.slice(0,4).map(i=>`${i.ns}/${i.label}`).join("  "));
await rpc("eval", { src: "(defn spike-doc-fn \"a docstring here\" [x] (inc x))" });
r = await rpc("doc", { ns: "user", name: "spike-doc-fn" });
line("U2 doc lookup", (r.doc||"").includes("docstring"), `arglists ${r.arglists || "?"} · doc "${(r.doc || "").slice(0, 60)}"`);

// U3: interrupt a runaway eval
const runaway = rpc("eval", { src: "(loop [] (recur))" });
await new Promise((r2) => setTimeout(r2, 300));
await rpc("interrupt");
r = await runaway;
line("U3 interrupt", r.kind === "error" && r.interrupted === true, `after ${r.ms}ms · "${r.text.slice(0, 50)}"`);
r = await rpc("eval", { src: "(inc spike-x)" });
line("U3 session survives", r.kind === "value" && r.text === "42", `${r.text} · rtt ${r.rtt}ms`);

// U5: balanced? fixtures (server truth; the page checks its JS port against these)
const FIXTURES = ["(+ 1 2)", "(+ 1", "(println \"(\")", "; )", "(def s \"\\\"\")", "(a [b {c}])", "(a [b)", "\"unterminated", "(map inc [1 2])\n(+ 1 2)", "]", "", "  \n  ", "(;(\n)"];
r = await rpc("balanced", { srcs: FIXTURES });
console.log(`U5 fixtures (server): ${FIXTURES.map((s, i) => `${JSON.stringify(s)}=${r.results[i]}`).join("  ")}`);

// error path
r = await rpc("eval", { src: "(/ 1 0)" });
line("error eval", r.kind === "error", `"${r.text.slice(0, 60)}" · rtt ${r.rtt}ms`);
r = await rpc("eval", { src: "*e" });
line("*e interned", r.kind === "value", r.text.slice(0, 60));

ws.close();
process.exit(0);
