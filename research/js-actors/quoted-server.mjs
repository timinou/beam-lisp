// quoted-server.mjs — loopback HTTP transport for the compiled BL backend actor.
//
// TRANSPORT, NOT POLICY. Every accept/refuse decision, and the reason for it,
// comes from the compiled BL actor (`out/quoted-backend.mjs`, built from
// runtime.bl + quoted-view-core.bl + quoted-backend.bl). This file:
//
//   1. imports the bundle and waits for its `QV-BACKEND READY` line;
//   2. listens on 127.0.0.1 only (port 0 picks an ephemeral port);
//   3. routes a fixed allowlist of static files out of research/js-actors;
//   4. accepts `POST /api/intent` as bounded, strictly-shaped JSON `{op, version}`
//      — a browser never sends a principal or grants, and no extra key survives;
//   5. forwards `{op, version}` to the actor with `H.enqueueInput(op, version)`;
//   6. reads back the actor's one typed `QV-BACKEND RESULT <seq> <result>` line,
//      correlates it by sequence, and maps the typed result to an HTTP status.
//
// It never decides whether an intent is allowed, and it never converts the
// version wire to a number: the version stays the exact string the browser sent
// until the BL core compares it to the string form of the version it holds.
//
// FAIL CLOSED. Requests are serialized one at a time. A missing or timed-out
// actor response, a boot failure or a sequence mismatch refuses the request AND
// marks the service failed, so no later request is answered on stale state.
//
// NOT PRODUCTION AUTHENTICATION. This is a single-user loopback demo: no
// cookies, no sessions, no TLS and no CORS — and no claim of a security
// boundary. A browser frontend that consumes it must never assign untrusted
// text to `innerHTML`; this file serves no such code.
//
// Usage:
//   node research/js-actors/quoted-server.mjs [--port N]
// It prints `QV-BACKEND LISTEN 127.0.0.1:<port>` once the actor is ready and
// the socket is listening.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import * as H from './host.mjs';

const nativeLog = console.log.bind(console);

// The frame bounds. The JSON body is small by design; the version is a canonical
// decimal that fits `Number.MAX_SAFE_INTEGER` in at most 16 digits.
const MAX_BODY = 4096;
const OP_RE = /^[a-z][a-z0-9-]{0,31}$/;
const VERSION_RE = /^(0|[1-9][0-9]{0,15})$/;
const ACTOR_TIMEOUT_MS = 4000;

// A fixed allowlist. `pathname` is never joined to a directory: an unknown path
// has no entry and is refused, so no request can reach outside this table.
const STATIC = new Map([
  ['/', ['browser.html', 'text/html; charset=utf-8']],
  ['/browser.html', ['browser.html', 'text/html; charset=utf-8']],
  ['/demo.html', ['demo.html', 'text/html; charset=utf-8']],
  ['/super-demo.html', ['super-demo.html', 'text/html; charset=utf-8']],
  ['/trace-demo.html', ['trace-demo.html', 'text/html; charset=utf-8']],
  ['/host.mjs', ['host.mjs', 'text/javascript; charset=utf-8']],
  ['/demo-worker.mjs', ['demo-worker.mjs', 'text/javascript; charset=utf-8']],
  ['/super-demo-worker.mjs', ['super-demo-worker.mjs', 'text/javascript; charset=utf-8']],
  ['/trace-demo-worker.mjs', ['trace-demo-worker.mjs', 'text/javascript; charset=utf-8']],
]);

// The BL reasons this transport knows how to place on the HTTP status line.
// Anything else is a 400; the REASON itself always comes from the actor.
const STATUS = new Map([
  ['stale-version', 409],
  ['version-exhausted', 409],
  ['unknown-intent', 403],
  ['unauthorized', 403],
  ['oversized-request', 413],
]);

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

// ── the actor bridge ─────────────────────────────────────────────────────────
//
// A thin line-matching bridge. `console.log` is the actor's `host/write`; the
// bridge watches for READY and for one result line per request. Nothing here
// interprets the result beyond splitting its first token.
function createBridge() {
  const waiters = [];
  let expectedSeq = 0;
  let failure = null;
  let resolveReady;
  let rejectReady;
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });

  function fail(reason) {
    if (!failure) failure = reason;
    while (waiters.length > 0) waiters.shift().reject(new Error(reason));
    rejectReady(new Error(reason));
  }

  function onLine(line) {
    if (line === 'QV-BACKEND READY') { resolveReady(); return; }
    const m = /^QV-BACKEND RESULT ([0-9]+) (.+)$/.exec(line);
    if (!m) return;
    const waiter = waiters.shift();
    if (waiter) waiter.resolve({ seq: Number(m[1]), body: m[2] });
  }

  console.log = (...args) => {
    const line = args.map(a => (typeof a === 'string' ? a : String(a))).join(' ');
    onLine(line);
    nativeLog(line);
  };

  import('./out/quoted-backend.mjs').catch(error => fail('BL actor failed: ' + error.message));

  // One in-flight request at a time: the next dispatch starts only after the
  // previous one has its answer (or fails closed).
  let tail = Promise.resolve();
  function serialize(task) {
    const run = tail.then(task, task);
    tail = run.then(() => {}, () => {});
    return run;
  }

  async function dispatch(op, version) {
    if (failure) throw new Error(failure);
    const seq = expectedSeq + 1;
    const answer = await new Promise((resolve, reject) => {
      const entry = {
        resolve: value => { clearTimeout(entry.timer); resolve(value); },
        reject: error => { clearTimeout(entry.timer); reject(error); },
      };
      entry.timer = setTimeout(() => {
        const i = waiters.indexOf(entry);
        if (i >= 0) waiters.splice(i, 1);
        fail('BL actor did not answer sequence ' + seq + ' within ' + ACTOR_TIMEOUT_MS + 'ms');
      }, ACTOR_TIMEOUT_MS);
      waiters.push(entry);
      try {
        H.enqueueInput(op, version);
      } catch (error) {
        const j = waiters.indexOf(entry);
        if (j >= 0) waiters.splice(j, 1);
        clearTimeout(entry.timer);
        reject(error);
      }
    });
    if (answer.seq !== seq) {
      fail('BL sequence mismatch: expected ' + seq + ', got ' + answer.seq);
      throw new Error(failure);
    }
    expectedSeq = answer.seq;
    return answer.body;
  }

  return { ready, serialize, dispatch, fail };
}

// The typed result the actor wrote, split into the fields the HTTP body needs.
// This is DECODING, not deciding: the accept/refuse split and the reason are
// the actor's; only the numeric `:version` is turned back into a JSON number,
// and only for a value the actor accepted (`(inc version)`, always exact).
function classify(body) {
  const ok = /^\[:ok \{:intent :([a-z][a-z0-9-]*), :version ([0-9]+)\}\]$/.exec(body);
  if (ok) return { ok: true, intent: ok[1], version: Number(ok[2]) };
  const refused = /^\[:refused \[:([a-z][a-z0-9-]*)/.exec(body);
  if (refused) return { ok: false, reason: refused[1] };
  return { ok: false, reason: 'unparsed-response' };
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
    req.on('end', () =>
      resolve(tooLarge ? { tooLarge: true } : { tooLarge: false, text: Buffer.concat(chunks).toString('utf8') }));
    req.on('error', () => resolve({ tooLarge: true }));
  });
}

export async function startBackend({ port = 0 } = {}) {
  const bridge = createBridge();
  await bridge.ready;

  let boundPort = 0;
  const allowedHosts = () => [`127.0.0.1:${boundPort}`, `localhost:${boundPort}`];
  const allowedOrigins = () => [`http://127.0.0.1:${boundPort}`, `http://localhost:${boundPort}`];

  async function handleIntent(req, res) {
    if (req.method !== 'POST') {
      return send(res, 405, { ok: false, reason: 'method-not-allowed' }, { allow: 'POST' });
    }
    // Same-origin only, and loopback Host only: no CORS response headers exist,
    // so a cross-origin browser cannot read an answer, and a rebound DNS name
    // cannot reach the endpoint.
    if (!allowedHosts().includes(req.headers.host)) {
      return send(res, 403, { ok: false, reason: 'host-refused' });
    }
    if (req.headers.origin !== undefined && !allowedOrigins().includes(req.headers.origin)) {
      return send(res, 403, { ok: false, reason: 'origin-refused' });
    }
    const mediaType = (req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (mediaType !== 'application/json') {
      return send(res, 415, { ok: false, reason: 'content-type-refused' });
    }
    const body = await readBody(req, MAX_BODY);
    if (body.tooLarge) return send(res, 413, { ok: false, reason: 'oversized-body' });

    let parsed;
    try { parsed = JSON.parse(body.text); } catch { return send(res, 400, { ok: false, reason: 'malformed-json' }); }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return send(res, 400, { ok: false, reason: 'malformed-request' });
    }
    const keys = Object.keys(parsed);
    if (!(keys.length === 2 && keys.includes('op') && keys.includes('version'))) {
      return send(res, 400, { ok: false, reason: 'malformed-request' });
    }
    if (typeof parsed.op !== 'string' || !OP_RE.test(parsed.op)) {
      return send(res, 400, { ok: false, reason: 'malformed-op' });
    }
    if (typeof parsed.version !== 'string' || !VERSION_RE.test(parsed.version)) {
      return send(res, 400, { ok: false, reason: 'malformed-version' });
    }

    let answer;
    try {
      answer = await bridge.serialize(() => bridge.dispatch(parsed.op, parsed.version));
    } catch {
      return send(res, 503, { ok: false, reason: 'backend-unavailable' });
    }
    const outcome = classify(answer);
    if (outcome.reason === 'unparsed-response' ||
        (outcome.ok && (!Number.isSafeInteger(outcome.version) || outcome.intent !== 'increment'))) {
      bridge.fail('BL actor returned an unrecognized or inexact response');
      return send(res, 503, { ok: false, reason: 'backend-unavailable' });
    }
    if (outcome.ok) return send(res, 200, outcome);
    return send(res, STATUS.get(outcome.reason) || 400, outcome);
  }

  async function handleStatic(req, res, pathname) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return send(res, 405, { ok: false, reason: 'method-not-allowed' }, { allow: 'GET, HEAD' });
    }
    const entry = STATIC.get(pathname);
    if (!entry) return send(res, 404, { ok: false, reason: 'not-found' });
    const [file, type] = entry;
    try {
      const data = await readFile(new URL(file, import.meta.url));
      res.writeHead(200, {
        'content-type': type,
        'content-length': data.length,
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
      });
      res.end(req.method === 'HEAD' ? undefined : data);
    } catch {
      send(res, 500, { ok: false, reason: 'static-unavailable' });
    }
  }

  const server = createServer((req, res) => {
    // URL resolution would normalize /../ to /; reject traversal before parsing.
    if (/(?:\.\.|%2e|%2f|%5c|\\)/i.test(req.url || ''))
      return send(res, 404, { ok: false, reason: 'not-found' });
    let pathname;
    try {
      pathname = new URL(req.url, `http://127.0.0.1:${boundPort}`).pathname;
    } catch {
      return send(res, 400, { ok: false, reason: 'malformed-url' });
    }
    const task = pathname === '/api/intent' ? handleIntent(req, res) : handleStatic(req, res, pathname);
    Promise.resolve(task).catch(() => send(res, 500, { ok: false, reason: 'internal-error' }));
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  boundPort = server.address().port;

  return {
    port: boundPort,
    server,
    close: () => new Promise(resolve => server.close(() => resolve())),
  };
}

// ── CLI ──────────────────────────────────────────────────────────────────────

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) {
  const argv = process.argv.slice(2);
  let port = 0;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port' && argv[i + 1] !== undefined) { port = Number(argv[i + 1]); i++; }
  }
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    nativeLog('quoted-server: --port must be an integer in 0..65535');
    process.exit(2);
  }

  let service = null;
  let closing = false;
  const shutdown = () => {
    if (closing) return;
    closing = true;
    if (service === null) process.exit(0);
    else service.close().then(() => process.exit(0), () => process.exit(1));
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  try {
    service = await startBackend({ port });
    nativeLog('QV-BACKEND LISTEN 127.0.0.1:' + service.port);
  } catch (error) {
    nativeLog('QV-BACKEND FAILED ' + error.message);
    process.exit(1);
  }
}
