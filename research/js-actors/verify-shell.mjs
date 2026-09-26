// verify-shell.mjs — the generic multi-app shell, end to end, without a browser.
//
// Proves the page/server/worker shell is app-agnostic:
//   * GET /api/app names the app this process serves and its contract digest;
//   * GET /app.css serves apps/<app>.css as text/css with the same no-store /
//     nosniff headers as every other static file;
//   * GET /app.page.json carries the app's title/lede/hints;
//   * the page HTML links /app.css and no longer inlines the app rules;
//   * static files sit behind an allowlist: path traversal and bare source
//     paths are 404;
//   * an app without page.json still gets a working shell (name-only metadata,
//     empty stylesheet).
//
// Usage: node research/js-actors/verify-shell.mjs

import assert from 'node:assert/strict';
import { request } from 'node:http';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { startSplitServer } from './split-server.mjs';

const here = new URL('./', import.meta.url);
let passed = 0;
const ok = label => { passed++; console.log('PASS shell: ' + label); };

// The page and the Worker are loaded by a browser, never imported by the Node
// suites: a syntax error in them would pass every other check. Parse them.
{
  const { spawnSync } = await import('node:child_process');
  for (const f of ['showcase-page.mjs', 'split-worker.mjs', 'split-codec.mjs', 'split-session.mjs', 'host.mjs']) {
    const r = spawnSync(process.execPath, ['--check', new URL(f, import.meta.url).pathname], { encoding: 'utf8' });
    assert.equal(r.status, 0, `${f} does not parse: ${r.stderr}`);
  }
  ok('the page, Worker, codec, session and host modules parse');
}

const service = await startSplitServer({ port: 0 });
const base = `http://127.0.0.1:${service.port}`;
const get = async (path, headers) => {
  const r = await fetch(base + path, { headers });
  return { status: r.status, headers: r.headers, body: await r.text() };
};
// Raw HTTP so a `..` or `%2e%2e` reaches the server un-normalised.
const raw = path => new Promise((resolve, reject) => {
  const req = request({ host: '127.0.0.1', port: service.port, path, method: 'GET' }, res => {
    const chunks = [];
    res.on('data', c => chunks.push(c));
    res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
  });
  req.on('error', reject);
  req.end();
});

let failure = null;
try {
  const info = await get('/api/app');
  assert.equal(info.status, 200);
  const appInfo = JSON.parse(info.body);
  assert.equal(appInfo.app, 'showcase');
  assert.equal(appInfo.digest, service.codec.digest);
  ok('/api/app names the app and its contract digest');

  const css = await get('/app.css');
  assert.equal(css.status, 200);
  assert.equal(css.headers.get('content-type'), 'text/css; charset=utf-8');
  assert.equal(css.headers.get('cache-control'), 'no-store');
  assert.equal(css.headers.get('x-content-type-options'), 'nosniff');
  assert.ok(css.body.includes('#app .task'), '/app.css must carry the app rules');
  ok('/app.css serves the app stylesheet as text/css with no-store + nosniff');

  const meta = await get('/app.page.json');
  assert.equal(meta.status, 200);
  assert.equal(meta.headers.get('content-type'), 'application/json; charset=utf-8');
  const page = JSON.parse(meta.body);
  const onDisk = JSON.parse(readFileSync(new URL('apps/showcase.page.json', here), 'utf8'));
  assert.equal(page.title, onDisk.title);
  assert.equal(page.lede, onDisk.lede);
  assert.deepEqual(page.hints, onDisk.hints);
  ok('/app.page.json serves the app title, lede and hints');

  const html = await get('/');
  assert.equal(html.status, 200);
  assert.ok(html.body.includes('<link rel="stylesheet" href="/app.css">'), 'the page must link /app.css');
  assert.ok(!html.body.includes('#app .task'), 'the app rules must not be inlined in the page');
  ok('the page links /app.css and the app rules live only in the stylesheet');

  assert.equal((await raw('/apps/../compiler.bl')).status, 404);
  assert.equal((await raw('/apps/%2e%2e/compiler.bl')).status, 404);
  assert.equal((await get('/apps/showcase.css')).status, 404);
  ok('path traversal and unlisted app paths are 404');

  // A built app that ships no page.json: the shell must still answer. Only
  // runs when such a build exists (today only showcase is built).
  const built = readdirSync(new URL('out/', here))
    .filter(f => f.endsWith('-client.mjs')).map(f => f.slice(0, -'-client.mjs'.length));
  const bareApp = built.find(a => a !== 'showcase' &&
    existsSync(new URL(`out/${a}.contract.json`, here)) && !existsSync(new URL(`apps/${a}.page.json`, here)));
  if (bareApp) {
    const leaf = await startSplitServer({ port: 0, app: bareApp });
    try {
      const lmeta = await (await fetch(`http://127.0.0.1:${leaf.port}/app.page.json`)).json();
      assert.deepEqual(lmeta, { title: bareApp, lede: '', hints: [] });
      const lcss = await fetch(`http://127.0.0.1:${leaf.port}/app.css`);
      assert.equal(lcss.status, 200);
      assert.equal(lcss.headers.get('content-type'), 'text/css; charset=utf-8');
      assert.equal(await lcss.text(), '');
    } finally { await leaf.close(); }
    ok(`an app without page.json (${bareApp}) falls back to name-only metadata and an empty stylesheet`);
  } else {
    console.log('SKIP shell: no built app lacks apps/<app>.page.json — fallback not exercised');
  }
} catch (error) {
  failure = error;
} finally {
  await service.close();
}

if (failure) {
  console.error(`js-actors: SHELL FAIL — ${failure.message}`);
  process.exit(1);
}
console.log(`js-actors: SHELL PASS (${passed} checks)`);
