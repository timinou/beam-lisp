// Run beside the playground: node research/workspace-spike/browser_smoke.mjs URL
// Browser screenshots are separate evidence; this pins the shared HTTP/API seam.
import assert from 'node:assert/strict';
const base = process.argv[2] || 'http://127.0.0.1:7871';
async function session() {
  const response = await fetch(`${base}/play`);
  assert.equal(response.status, 200);
  const page = await response.text();
  const token = JSON.parse(page.match(/window\.playInit\(([^)]+)\)/)[1]);
  const cookie = response.headers.get('set-cookie').split(';')[0];
  const state = () => fetch(`${base}/play/state`, {headers: {cookie}}).then(r => r.json());
  const command = (cmd, args = {}, extra = {}) => fetch(`${base}/play/command`, {
    method: 'POST', headers: {'content-type': 'application/json', 'x-bl-token': token, cookie, ...extra},
    body: JSON.stringify({cmd, args})
  });
  return {state, command};
}
const a = await session(), b = await session();
assert.equal((await fetch(`${base}/play/command`, {method:'POST',headers:{'content-type':'application/json'},body:'{"cmd":"eval","args":{"source":"42"}}'})).status, 403);
assert.equal((await a.command('eval', {source:'42'}, {origin:'http://untrusted.example'})).status, 403);
assert.equal((await a.command('unknown-command')).status, 200);
assert.equal((await (await a.command('unknown-command')).json()).ok, false);
const calc = await (await a.command('eval', {source:'(+ 20 22)'})).json();
assert.equal(calc.result, '42');
const beforeB = await b.state();
const files = (await a.state()).files;
assert.ok(files.includes('src/app/invoices.bl'));
const opened = await (await a.command('open-file', {path:'src/app/invoices.bl'})).json();
assert.equal(opened.ok, true);
const afterB = await b.state();
assert.equal(afterB.view.active_buffer, beforeB.view.active_buffer);
const inspected = await (await a.command('inspect', {kind:'buffer', id:opened.data.id})).json();
assert.equal(inspected.ok, true);
assert.equal((await (await a.command('eval', {source:'(= :buffer (:kind buffer))'})).json()).result, 'true');
assert.equal((await (await a.command('open-file', {path:'.env'})).json()).ok, false);
assert.equal((await (await a.command('open-file', {path:'../escape.bl'})).json()).ok, false);
const css = await fetch(`${base}/play/ui.css`).then(r=>r.text());
assert.ok(css.includes('--syntax-keyword:'));
assert.ok(css.includes('.theme-snow'));
assert.equal((await fetch(`${base}/repl`)).status, 200);
assert.equal((await fetch(`${base}/repl/editor.bundle.js`)).status, 200);
console.log('PASS: token/origin gates, shared API REPL, stable buffers, per-browser selection, path rejection, Carbon/Snow assets, daemon REPL routes');
