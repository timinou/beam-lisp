// probe2.mjs — isolate the U3 hang: runaway eval, then cheap ops, then interrupt.
// Prints every frame + close events with elapsed time.
const port = process.argv[2] || 7841;
const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
const t0 = performance.now();
const el = () => Math.round(performance.now() - t0);
let seq = 0;
const send = (op, fields = {}) => { const id = ++seq; console.log(`${el()}ms → ${op} id=${id} ${fields.src ? JSON.stringify(fields.src).slice(0, 40) : ""}`); ws.send(JSON.stringify({ op, id, ...fields })); return id; };

ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  console.log(`${el()}ms ← ${m.kind} id=${m.id ?? "-"} ${m.text ? JSON.stringify(m.text).slice(0, 60) : ""} ${m.ms != null ? m.ms + "ms" : ""}`);
  if (m.kind === "hello") {
    send("eval", { src: "(loop [] (recur))" });          // runaway
    setTimeout(() => send("complete", { prefix: "ma" }), // is the socket still responsive?
    400);
    setTimeout(() => send("interrupt"), 800);            // does interrupt work?
    setTimeout(() => send("eval", { src: "(+ 40 2)" }), 1200); // did the session survive?
    setTimeout(() => { console.log(`${el()}ms done — closing`); ws.close(); process.exit(0); }, 5000);
  }
};
ws.onclose = (e) => { console.log(`${el()}ms [closed code=${e.code}]`); process.exit(1); };
ws.onerror = () => console.log(`${el()}ms [error]`);
setTimeout(() => { console.log(`${el()}ms global timeout`); process.exit(2); }, 30000);
