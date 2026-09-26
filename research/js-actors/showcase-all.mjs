// showcase-all.mjs — every split app at once, with a gallery to start from.
//
//   node research/js-actors/showcase-all.mjs [--base 8801]
//
// Starts one split-server.mjs process per app (one BL authority each; a
// process holds one runtime) on consecutive ports, and serves a small gallery
// page on the base port that links to each app with what it shows. The apps
// are the ones built under out/ (run the build first). Ctrl-C stops them all.
//
// Transport only: the gallery is a static page; each app is its own server
// with its own contract, exactly as when started alone.

import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';

const APPS = [
  { app: 'showcase', name: 'Launch checklist', track: 'Placement · function values',
    what: 'One file, split: the compiler decides what runs in your browser. Sort and refine chips are composed function values.' },
  { app: 'outline', name: 'Product plan', track: 'Recursive data',
    what: 'A plan of any depth: a recursive wire type, a recursive view, roll-up progress and search — recursion the build proved finite.' },
  { app: 'groceries', name: 'Groceries', track: 'Instant · offline',
    what: 'Edits show at once, the server confirms or slides them back; go offline, keep shopping, and the queue goes out in order.' },
  { app: 'team', name: 'Team board', track: 'Identity · history',
    what: 'Sign in as Ana, Ben, Chloé or Dev: permissions in BL, presence, an activity feed, shared undo, a history scrubber — and a restart loses nothing.' },
  { app: 'triage', name: 'Bug inbox', track: 'Keyboard · drag · inline edit',
    what: 'j/k/x/e/p and ? — a keymap the view declares as data; drag rows to reorder for everyone; rename inline.' },
  { app: 'ledger', name: 'Household ledger', track: 'Exact numbers',
    what: 'Money exact to the cent beyond 2^53, formatted and broken down in your browser with the same answers as the BEAM.' },
];

const argv = process.argv.slice(2);
const base = Number(argv[argv.indexOf('--base') + 1] || 8801);
if (!Number.isInteger(base) || base < 1024 || base > 65000 || base === 8765) {
  console.error('usage: showcase-all.mjs [--base 1024..65000, not 8765]');
  process.exit(2);
}
const here = new URL('./', import.meta.url);
const ready = APPS.filter(a => existsSync(new URL(`out/${a.app}.contract.json`, here)));
const children = [];
ready.forEach((a, i) => {
  a.port = base + 1 + i;
  const child = spawn(process.execPath, [new URL('split-server.mjs', here).pathname, '--port', String(a.port), '--app', a.app],
                      { stdio: ['ignore', 'inherit', 'inherit'] });
  children.push(child);
});

const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const page = () => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>BL split apps</title>
<style>
  :root { color-scheme: dark; --bg:#0f1115; --panel:#171a21; --line:#2a2f3a; --text:#e7e9ee; --muted:#8b93a3; --accent:#7aa2ff; }
  body { margin:0; background: radial-gradient(1200px 600px at 10% -10%, #1b2233 0%, var(--bg) 55%); color: var(--text);
         font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; min-height: 100vh; }
  main { max-width: 1080px; margin: 0 auto; padding: 48px 28px; }
  h1 { font-size: 28px; margin: 0 0 6px; } p.lede { color: var(--muted); margin: 0 0 28px; max-width: 760px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 16px; }
  a.card { display: block; background: var(--panel); border: 1px solid var(--line); border-radius: 14px; padding: 18px 18px 16px;
           color: inherit; text-decoration: none; transition: border-color .15s, transform .15s; }
  a.card:hover { border-color: var(--accent); transform: translateY(-2px); }
  .track { font: 11px ui-monospace, monospace; color: var(--accent); text-transform: uppercase; letter-spacing: .08em; }
  h2 { font-size: 18px; margin: 6px 0 6px; } .what { color: var(--muted); font-size: 14px; margin: 0; }
  .port { font: 12px ui-monospace, monospace; color: var(--muted); margin-top: 10px; }
</style></head><body><main>
<h1>One BL file per app → client · server · contract</h1>
<p class="lede">Each app is an ordinary BL program. The compiler decides which functions run in your browser and proves it safe; the server stays the authority. Open two windows of the same app to see changes arrive from the other.</p>
<div class="grid">
${ready.map(a => `<a class="card" href="http://127.0.0.1:${a.port}/"><div class="track">${esc(a.track)}</div><h2>${esc(a.name)}</h2><p class="what">${esc(a.what)}</p><div class="port">${a.app === 'showcase' ? 'showcase.bl' : `apps/${esc(a.app)}.bl`} · :${a.port}</div></a>`).join('\n')}
</div></main></body></html>`;

const gallery = createServer((req, res) => {
  if (req.url !== '/' && req.url !== '/index.html') { res.writeHead(404); res.end(); return; }
  const body = page();
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store',
    'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'" });
  res.end(body);
});
gallery.listen(base, '127.0.0.1', () => {
  console.error(`SHOWCASE http://127.0.0.1:${base}/  (${ready.map(a => `${a.app}:${a.port}`).join(' ')})`);
});
const stop = () => { for (const c of children) c.kill('SIGTERM'); gallery.close(); process.exit(0); };
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
