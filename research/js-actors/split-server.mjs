// split-server.mjs — loopback HTTP + SSE transport for a compiled split app.
//
// TRANSPORT, NOT POLICY. The authority is the compiled BL server half
// (`out/<app>-server.mjs`, built from split-server.bl + the app's server
// closure). This file:
//
//   1. loads the generated contract and the server bundle, and waits for the
//      bundle's own `:ready` (its digest must equal the contract's);
//   2. serves the showcase page, the CLIENT bundle and the generated
//      contract/placement files from a fixed allowlist — the server bundle
//      and the app source are never served;
//   3. accepts `POST /api/intent` as strict JSON, decodes it by contract, and
//      hands it to the BL authority, one proposal at a time;
//   4. answers with the BL `:result` for that request, and fans every BL
//      `:snapshot` out to every open `GET /api/events` stream, so a second tab
//      sees the change without polling.
//
// It decides nothing: no op, check, guard or state lives here. A timed-out or
// mismatched authority fails the service closed.
//
// NOT AUTHENTICATION. Single-user loopback demo: no sessions, no TLS, no CORS.
//
// Usage: node research/js-actors/split-server.mjs [--port N] [--app showcase]

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import * as H from './host.mjs';
import { createCodec, encode } from './split-codec.mjs';

const MAX_BODY = 4096;
const AUTHORITY_TIMEOUT_MS = 4000;
const MAX_STREAMS = 32;

const CSP_PAGE =
  "default-src 'none'; script-src 'self'; worker-src 'self'; child-src 'self'; " +
  "connect-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; " +
  "object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

function staticTable(app) {
  const js = 'text/javascript; charset=utf-8';
  const json = 'application/json; charset=utf-8';
  return new Map([
    ['/', ['showcase.html', 'text/html; charset=utf-8', CSP_PAGE]],
    ['/showcase.html', ['showcase.html', 'text/html; charset=utf-8', CSP_PAGE]],
    ['/showcase-page.mjs', ['showcase-page.mjs', js]],
    ['/split-worker.mjs', ['split-worker.mjs', js]],
    ['/split-codec.mjs', ['split-codec.mjs', js]],
    ['/host.mjs', ['host.mjs', js]],
    [`/out/${app}-client.mjs`, [`out/${app}-client.mjs`, js]],
    [`/out/${app}.contract.json`, [`out/${app}.contract.json`, json]],
    [`/out/${app}.split.json`, [`out/${app}.split.json`, json]],
  ]);
}

function send(res, status, payload, extra = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...extra,
  });
  res.end(body);
}

function readBody(req, limit) {
  return new Promise(resolve => {
    const chunks = [];
    let size = 0;
    let tooLarge = false;
    req.on('data', chunk => {
      size += chunk.length;
      if (tooLarge) return;
      if (size > limit) { tooLarge = true; chunks.length = 0; return; }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(tooLarge ? { tooLarge } : { tooLarge, text: Buffer.concat(chunks).toString('utf8') }));
    req.on('error', () => resolve({ tooLarge: true }));
  });
}

// The bridge to the ONE BL authority in this process.
function createAuthority(codec, bundleUrl) {
  const waiting = new Map();       // request → { resolve, timer }
  const listeners = new Set();     // snapshot subscribers
  let failure = null;
  let current = null;              // latest { revision, board } (JSON)
  let resolveReady, rejectReady;
  const ready = new Promise((ok, no) => { resolveReady = ok; rejectReady = no; });

  function fail(reason) {
    if (!failure) failure = reason;
    for (const [, w] of waiting) { clearTimeout(w.timer); w.reject(new Error(reason)); }
    waiting.clear();
    rejectReady(new Error(reason));
  }

  H.setEmitter((topic, value) => {
    let frame;
    try { frame = encode(value); } catch (error) { fail('authority emitted non-wire data: ' + error.message); return; }
    if (topic === 'ready') {
      if (frame.digest !== codec.digest) fail('server bundle digest does not match the contract');
      else { current = { revision: frame.revision, board: frame.board }; resolveReady(); }
    } else if (topic === 'result') {
      current = { revision: frame.revision, board: frame.board };
      const w = waiting.get(frame.request);
      if (w) { waiting.delete(frame.request); clearTimeout(w.timer); w.resolve(frame); }
    } else if (topic === 'snapshot') {
      current = { revision: frame.revision, board: frame.board };
      for (const fn of listeners) fn(frame);
    }
  });

  import(bundleUrl).catch(error => fail('authority failed: ' + error.message));

  let tail = Promise.resolve();
  function propose(request, value) {
    const run = tail.then(() => new Promise((resolve, reject) => {
      if (failure) { reject(new Error(failure)); return; }
      const timer = setTimeout(() => {
        waiting.delete(request);
        fail(`authority did not answer request ${request} within ${AUTHORITY_TIMEOUT_MS}ms`);
      }, AUTHORITY_TIMEOUT_MS);
      waiting.set(request, { resolve, reject, timer });
      try { H.enqueueData('intent', value, { nodes: 256, depth: 8, text: 4096 }); }
      catch (error) { waiting.delete(request); clearTimeout(timer); reject(error); }
    }));
    tail = run.then(() => {}, () => {});
    return run;
  }

  return {
    ready, propose, fail,
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    get current() { return current; },
    get failure() { return failure; },
  };
}

export async function startSplitServer({ port = 0, app = 'showcase' } = {}) {
  const dir = new URL('./', import.meta.url);
  const contract = JSON.parse(readFileSync(new URL(`out/${app}.contract.json`, dir), 'utf8'));
  const codec = createCodec(contract);
  const authority = createAuthority(codec, new URL(`out/${app}-server.mjs`, dir).href);
  await authority.ready;
  const STATIC = staticTable(app);
  const streams = new Set();
  const pendingTabs = new Map();   // server request → proposing tab id
  let nextRequest = 0;

  let boundPort = 0;
  const hostOK = req => [`127.0.0.1:${boundPort}`, `localhost:${boundPort}`].includes(req.headers.host);
  const originOK = req => req.headers.origin === undefined ||
    [`http://127.0.0.1:${boundPort}`, `http://localhost:${boundPort}`].includes(req.headers.origin);

  authority.subscribe(frame => {
    const by = pendingTabs.get(frame.request) ?? null;
    pendingTabs.delete(frame.request);
    const { request: _internal, ...pub } = frame;
    const line = `event: snapshot\ndata: ${JSON.stringify({ ...pub, by })}\n\n`;
    for (const res of streams) res.write(line);
  });

  async function handleIntent(req, res) {
    if (req.method !== 'POST') return send(res, 405, { ok: false, reason: 'method-not-allowed' }, { allow: 'POST' });
    if (!hostOK(req)) return send(res, 403, { ok: false, reason: 'host-refused' });
    if (!originOK(req)) return send(res, 403, { ok: false, reason: 'origin-refused' });
    const type = (req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (type !== 'application/json') return send(res, 415, { ok: false, reason: 'content-type-refused' });
    const body = await readBody(req, MAX_BODY);
    if (body.tooLarge) return send(res, 413, { ok: false, reason: 'oversized-body' });
    let json;
    try { json = JSON.parse(body.text); } catch { return send(res, 400, { ok: false, reason: 'malformed-json' }); }
    const decoded = codec.decodeProposal(json);
    if (!decoded.ok) {
      const cur = authority.current;
      return send(res, decoded.reason === 'client-outdated' ? 409 : 400,
                  { ...decoded, request: json && json.request, revision: cur.revision, board: cur.board });
    }
    // The browser's request number is ITS correlation id; the authority gets a
    // server-unique one so two tabs can never collide on a waiter.
    const serverRequest = ++nextRequest;
    const value = H.mapPut(decoded.value, H.kw('request'), serverRequest);
    // Which tab proposed it: transport metadata for the timeline only (it
    // never reaches the BL authority and authorizes nothing).
    const tab = /^[a-z0-9]{8,32}$/.test(req.headers['x-split-tab'] || '') ? req.headers['x-split-tab'] : null;
    pendingTabs.set(serverRequest, tab);
    let frame;
    try { frame = await authority.propose(serverRequest, value); }
    catch { pendingTabs.delete(serverRequest); return send(res, 503, { ok: false, reason: 'authority-unavailable' }); }
    if (!frame.ok) pendingTabs.delete(serverRequest);
    const out = { ...frame, request: json.request };
    return send(res, frame.ok ? 200 : (frame.reason === 'stale-revision' ? 409 : 422), out);
  }

  function handleEvents(req, res) {
    if (req.method !== 'GET') return send(res, 405, { ok: false, reason: 'method-not-allowed' });
    if (!hostOK(req)) return send(res, 403, { ok: false, reason: 'host-refused' });
    if (streams.size >= MAX_STREAMS) return send(res, 503, { ok: false, reason: 'too-many-streams' });
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      connection: 'keep-alive',
    });
    const cur = authority.current;
    res.write(`event: hello\ndata: ${JSON.stringify({ digest: codec.digest, ...cur })}\n\n`);
    streams.add(res);
    const ping = setInterval(() => res.write(': ping\n\n'), 15000);
    req.on('close', () => { clearInterval(ping); streams.delete(res); });
  }

  async function handleStatic(req, res, pathname) {
    if (req.method !== 'GET' && req.method !== 'HEAD')
      return send(res, 405, { ok: false, reason: 'method-not-allowed' }, { allow: 'GET, HEAD' });
    const entry = STATIC.get(pathname);
    if (!entry) return send(res, 404, { ok: false, reason: 'not-found' });
    const [file, type, csp] = entry;
    try {
      const data = await readFile(new URL(file, dir));
      res.writeHead(200, {
        'content-type': type, 'content-length': data.length, 'cache-control': 'no-store',
        'x-content-type-options': 'nosniff', ...(csp ? { 'content-security-policy': csp } : {}),
      });
      res.end(req.method === 'HEAD' ? undefined : data);
    } catch {
      send(res, 500, { ok: false, reason: 'static-unavailable' });
    }
  }

  const server = createServer((req, res) => {
    if (/(?:\.\.|%2e|%2f|%5c|\\)/i.test(req.url || '')) return send(res, 404, { ok: false, reason: 'not-found' });
    let pathname;
    try { pathname = new URL(req.url, `http://127.0.0.1:${boundPort}`).pathname; }
    catch { return send(res, 400, { ok: false, reason: 'malformed-url' }); }
    const task = pathname === '/api/intent' ? handleIntent(req, res)
      : pathname === '/api/events' ? handleEvents(req, res)
      : handleStatic(req, res, pathname);
    Promise.resolve(task).catch(() => send(res, 500, { ok: false, reason: 'internal-error' }));
  });

  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  boundPort = server.address().port;
  return {
    port: boundPort, server, codec,
    close: () => new Promise(resolve => {
      for (const res of streams) res.end();
      streams.clear();
      server.close(() => resolve());
    }),
  };
}

const direct = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (direct) {
  const argv = process.argv.slice(2);
  let port = 0;
  let app = 'showcase';
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port') port = Number(argv[++i]);
    else if (argv[i] === '--app') app = argv[++i];
  }
  if (!Number.isInteger(port) || port < 0 || port > 65535 || !/^[a-z][a-z0-9-]{0,31}$/.test(app)) {
    console.error('usage: split-server.mjs [--port 0..65535] [--app name]');
    process.exit(2);
  }
  try {
    const service = await startSplitServer({ port, app });
    console.error(`SPLIT LISTEN http://127.0.0.1:${service.port}/  (contract ${service.codec.digest.slice(0, 12)})`);
    const stop = () => service.close().then(() => process.exit(0));
    process.on('SIGTERM', stop);
    process.on('SIGINT', stop);
  } catch (error) {
    console.error('SPLIT FAILED ' + error.message);
    process.exit(1);
  }
}
