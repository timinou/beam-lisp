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
// IDENTITY (only when the contract says `people: true`). `POST /api/login`
// asks the BL authority who a user id is; a known id mints an opaque session
// id and sets `split_sid=<sid>.<hmac>` — the transport verifies the cookie and
// STAMPS `:actor` onto the proposal. A browser can never send an actor.
// `POST /api/logout`, `GET /api/me` and the SSE hello complete the loop. The
// per-process signing secret means a restart invalidates every cookie.
//
// HISTORY (only when the contract says `history: true`). Every BL `:commit` is
// appended, synchronously, to `data/<app>.log.jsonl`; at boot the transport
// replays the log through the same BL decision loop before it listens. A
// partial last line is ignored and truncated; any other bad line fails the
// service closed. `GET /api/peek?revision=k` answers a past board.
//
// NOT TLS, NOT A PUBLIC SERVICE. Loopback demo: no CORS, no CSRF token.
//
// Usage: node research/js-actors/split-server.mjs [--port N] [--app showcase]

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { readFileSync, appendFileSync, mkdirSync, existsSync, truncateSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import * as H from './host.mjs';
import { createCodec, encode } from './split-codec.mjs';
import * as S from './split-session.mjs';

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
  const css = 'text/css; charset=utf-8';
  return new Map([
    ['/', ['showcase.html', 'text/html; charset=utf-8', CSP_PAGE]],
    ['/showcase.html', ['showcase.html', 'text/html; charset=utf-8', CSP_PAGE]],
    ['/app.css', [`apps/${app}.css`, css]],
    ['/app.page.json', [`apps/${app}.page.json`, json]],
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

const presenceLine = people => `event: presence\ndata: ${JSON.stringify({ people })}\n\n`;

// The bridge to the ONE BL authority in this process.
function createAuthority(codec, bundleUrl, { onCommit, watch } = {}) {
  const waiting = new Map();       // key → { resolve, reject, timer }
  const listeners = new Set();     // snapshot subscribers
  let failure = null;
  let current = null;              // latest { revision, board } (JSON)
  let extra = { people: null, recent: null, history: null };
  let resolveReady, rejectReady;
  const ready = new Promise((ok, no) => { resolveReady = ok; rejectReady = no; });

  function fail(reason) {
    if (!failure) failure = reason;
    for (const [, w] of waiting) { clearTimeout(w.timer); w.reject(new Error(reason)); }
    waiting.clear();
    rejectReady(new Error(reason));
  }

  function settle(key, frame) {
    const w = waiting.get(key);
    if (w) { waiting.delete(key); clearTimeout(w.timer); w.resolve(frame); }
  }

  H.setEmitter((topic, value) => {
    let frame;
    try { frame = encode(value); } catch (error) { fail('authority emitted non-wire data: ' + error.message); return; }
    if (topic === 'ready') {
      if (frame.digest !== codec.digest) { fail('server bundle digest does not match the contract'); return; }
      current = { revision: frame.revision, board: frame.board };
      extra = { people: frame.people ?? null, recent: frame.recent ?? null, history: frame.history ?? null };
      resolveReady();
    } else if (topic === 'result') {
      current = { revision: frame.revision, board: frame.board };
      if (frame.recent !== undefined) extra.recent = frame.recent;
      if (frame.history !== undefined) extra.history = frame.history;
      // A proposal that fails the BL authority's OWN shape check is answered
      // with request -1, because the proposal never got far enough to be
      // correlated. Intents are serialized, so the one outstanding waiter is
      // the one this answers: resolve it rather than time out and fail closed.
      let key = 'result:' + frame.request;
      if (!waiting.has(key) && frame.request === -1)
        for (const k of waiting.keys()) if (k.startsWith('result:')) { key = k; break; }
      settle(key, frame);
    } else if (topic === 'snapshot') {
      current = { revision: frame.revision, board: frame.board };
      if (frame.recent !== undefined) extra.recent = frame.recent;
      if (frame.history !== undefined) extra.history = frame.history;
      for (const fn of listeners) fn(frame);
    } else if (topic === 'login' || topic === 'peek') {
      settle(topic + ':' + frame.request, frame);
    }
    // `commit` (durable log) and `presence` (fan-out) are transport concerns:
    // the watcher runs here, synchronously, BEFORE any awaiting HTTP answer is
    // delivered — a commit is on disk before its result is written.
    if (watch) watch(topic, frame);
    if (topic === 'commit' && onCommit) {
      try { onCommit(frame); } catch (error) { fail('could not append the commit log: ' + error.message); }
    }
  });

  import(bundleUrl).catch(error => fail('authority failed: ' + error.message));

  let tail = Promise.resolve();
  // One intent at a time, in order: the authority's own queue demands it, and
  // the `tail` chain keeps a second proposal from being posted before the first
  // is answered.
  function propose(request, value) {
    const run = tail.then(() => new Promise((resolve, reject) => {
      if (failure) { reject(new Error(failure)); return; }
      const key = 'result:' + request;
      const timer = setTimeout(() => {
        waiting.delete(key);
        fail(`authority did not answer request ${request} within ${AUTHORITY_TIMEOUT_MS}ms`);
      }, AUTHORITY_TIMEOUT_MS);
      waiting.set(key, { resolve, reject, timer });
      try { H.enqueueData('intent', value, { nodes: 256, depth: 8, text: 4096 }); }
      catch (error) { waiting.delete(key); clearTimeout(timer); reject(error); }
    }));
    tail = run.then(() => {}, () => {});
    return run;
  }

  // A login/peek question. Not serialized against the intent tail: it decides
  // nothing and may interleave.
  function ask(topic, request, value, timeoutMs = AUTHORITY_TIMEOUT_MS) {
    return new Promise((resolve, reject) => {
      if (failure) { reject(new Error(failure)); return; }
      const key = topic + ':' + request;
      const timer = setTimeout(() => {
        waiting.delete(key);
        fail(`authority did not answer ${key} within ${timeoutMs}ms`);
      }, timeoutMs);
      waiting.set(key, { resolve, reject, timer });
      try { H.enqueueData(topic, value, { nodes: 256, depth: 8, text: 4096 }); }
      catch (error) { waiting.delete(key); clearTimeout(timer); reject(error); }
    });
  }

  // Fire-and-forget input (presence): no answer is expected.
  function post(topic, value) {
    try { H.enqueueData(topic, value, { nodes: 256, depth: 8, text: 4096 }); }
    catch (error) { fail('could not send ' + topic + ': ' + error.message); }
  }

  return {
    ready, propose, ask, post, fail,
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    get current() { return current; },
    get extra() { return extra; },
    get failure() { return failure; },
  };
}

export async function startSplitServer({ port = 0, app = 'showcase', logFile } = {}) {
  const dir = new URL('./', import.meta.url);
  const contract = JSON.parse(readFileSync(new URL(`out/${app}.contract.json`, dir), 'utf8'));
  const codec = createCodec(contract);
  const peopleApp = codec.people;
  const historyApp = codec.history;
  // `undefined` → the default path for a history app; `null` → logging off.
  const logPath = historyApp
    ? (logFile === undefined ? fileURLToPath(new URL(`data/${app}.log.jsonl`, dir)) : logFile)
    : null;

  let replaying = false;
  let nextRequest = 0;    // authority request ids: intents (and replay)
  let nextControl = 0;    // authority request ids: login/peek
  let boundPort = 0;
  let lastPresence = [];

  const secret = S.newSecret();
  const sessions = new Map();    // sid → { user, created }
  const streams = new Set();     // open SSE streams: { res, user }
  const pendingTabs = new Map(); // server request → proposing tab id

  function appendCommit(frame) {
    const e = frame.entry || {};
    const line = JSON.stringify({ v: S.LOG_VERSION, revision: e.revision, at: new Date().toISOString(),
      actor: e.actor ?? null, op: e.op, args: frame.args ?? {}, nonce: frame.nonce });
    appendFileSync(logPath, line + '\n');
  }

  function fanPresence(frame) {
    if (!peopleApp) return;
    lastPresence = Array.isArray(frame.people) ? frame.people : [];
    const line = presenceLine(lastPresence);
    for (const s of streams) s.res.write(line);
  }

  const authority = createAuthority(codec, new URL(`out/${app}-server.mjs`, dir).href, {
    onCommit: frame => { if (logPath !== null && !replaying) appendCommit(frame); },
    watch: (topic, frame) => { if (topic === 'presence') fanPresence(frame); },
  });

  // Replay the durable log through the SAME BL decision loop before anything
  // is served. Any invalid or refused line fails the service closed.
  async function replayLog() {
    const text = readFileSync(logPath, 'utf8');
    if (text === '') return;
    const parsed = S.parseLogText(text);
    if (parsed.error !== null)
      throw new Error(`split log ${logPath} line ${parsed.error.line}: ${parsed.error.reason}`);
    if (parsed.truncated) {
      const keep = S.truncatedByteLength(text);
      truncateSync(logPath, keep);
      console.error(`SPLIT LOG ignored a partial last line; truncated ${logPath} to ${keep} bytes`);
    }
    replaying = true;
    try {
      let expected = 1;
      for (const { line, value } of parsed.entries) {
        const why = S.logEntryError(value, { isKnownOp: codec.hasOp, expectedRevision: expected });
        if (why !== null) throw new Error(`split log ${logPath} line ${line}: ${why}`);
        let args;
        try { args = codec.decodeIntentArgs(value.op, value.args); }
        catch (error) { throw new Error(`split log ${logPath} line ${line}: bad-args (${error.message})`); }
        const request = ++nextRequest;
        const proposal = H.bmap([[H.kw('request'), request], [H.kw('revision'), value.revision - 1],
          [H.kw('digest'), codec.digest], [H.kw('nonce'), value.nonce], [H.kw('actor'), value.actor],
          [H.kw('op'), H.kw(value.op)], [H.kw('args'), args]]);
        let frame;
        try { frame = await authority.propose(request, proposal); }
        catch (error) { throw new Error(`split log ${logPath} line ${line}: authority unavailable (${error.message})`); }
        if (frame.ok !== true) throw new Error(`split log ${logPath} line ${line}: refused (${frame.reason})`);
        if (frame.duplicate === true) throw new Error(`split log ${logPath} line ${line}: duplicate nonce`);
        expected += 1;
      }
      console.error(`SPLIT REPLAYED ${parsed.entries.length} commits from ${logPath}`);
    } finally { replaying = false; }
  }

  await authority.ready;
  if (logPath !== null) {
    mkdirSync(dirname(logPath), { recursive: true });
    if (existsSync(logPath)) await replayLog();
  }

  const STATIC = staticTable(app);

  const hostOK = req => [`127.0.0.1:${boundPort}`, `localhost:${boundPort}`].includes(req.headers.host);
  const originOK = req => req.headers.origin === undefined ||
    [`http://127.0.0.1:${boundPort}`, `http://localhost:${boundPort}`].includes(req.headers.origin);

  // ── identity helpers (people apps only) ───────────────────────────────────
  function sessionOf(req) {
    if (!peopleApp) return null;
    const sid = S.verifySessionCookie(secret, req.headers.cookie);
    if (sid === null) return null;
    const session = sessions.get(sid);
    if (session === undefined) return null;
    if (Date.now() - session.created > S.SESSION_TTL_SECONDS * 1000) { sessions.delete(sid); return null; }
    return session;
  }
  const roster = () => (Array.isArray(authority.extra.people) ? authority.extra.people : []);
  const personOf = id => {
    const found = roster().find(p => p !== null && typeof p === 'object' && p.id === id);
    return found === undefined ? null : found;
  };

  // ── presence helpers (people apps only) ───────────────────────────────────
  function pushPresence() {
    if (!peopleApp) return;
    const users = [...new Set([...streams].map(s => s.user).filter(u => u !== null))].sort();
    authority.post('presence', H.bmap([[H.kw('users'), H.vec(users)]]));
  }

  authority.subscribe(frame => {
    const by = pendingTabs.get(frame.request) ?? null;
    pendingTabs.delete(frame.request);
    const { request: _internal, ...pub } = frame;
    const line = `event: snapshot\ndata: ${JSON.stringify({ ...pub, by })}\n\n`;
    for (const s of streams) s.res.write(line);
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
    // The actor is STAMPED here from a verified session — the codec refuses a
    // proposal that carries one, so a browser cannot claim to be someone.
    let value = decoded.value;
    if (peopleApp) {
      const session = sessionOf(req);
      if (session === null) {
        const cur = authority.current;
        return send(res, 401, { ok: false, reason: 'not-signed-in', revision: cur.revision, board: cur.board });
      }
      value = H.mapPut(value, H.kw('actor'), session.user);
    }
    // The browser's request number is ITS correlation id; the authority gets a
    // server-unique one so two tabs can never collide on a waiter.
    const serverRequest = ++nextRequest;
    value = H.mapPut(value, H.kw('request'), serverRequest);
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

  async function handleLogin(req, res) {
    if (!peopleApp) return send(res, 404, { ok: false, reason: 'not-found' });
    if (req.method !== 'POST') return send(res, 405, { ok: false, reason: 'method-not-allowed' }, { allow: 'POST' });
    if (!hostOK(req)) return send(res, 403, { ok: false, reason: 'host-refused' });
    if (!originOK(req)) return send(res, 403, { ok: false, reason: 'origin-refused' });
    const type = (req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (type !== 'application/json') return send(res, 415, { ok: false, reason: 'content-type-refused' });
    const body = await readBody(req, MAX_BODY);
    if (body.tooLarge) return send(res, 413, { ok: false, reason: 'oversized-body' });
    let json;
    try { json = JSON.parse(body.text); } catch { return send(res, 400, { ok: false, reason: 'malformed-json' }); }
    const user = json !== null && typeof json === 'object' && !Array.isArray(json) ? json.user : undefined;
    if (typeof user !== 'string' || user.length < 1 || user.length > S.MAX_USER)
      return send(res, 400, { ok: false, reason: 'malformed-login' });
    const request = ++nextControl;
    let frame;
    try { frame = await authority.ask('login', request, H.bmap([[H.kw('request'), request], [H.kw('user'), user]])); }
    catch { return send(res, 503, { ok: false, reason: 'authority-unavailable' }); }
    const person = frame.person === undefined ? null : frame.person;
    if (person === null || typeof person !== 'object') return send(res, 403, { ok: false, reason: 'unknown-person' });
    const sid = S.newSessionId();
    sessions.set(sid, { user: person.id, created: Date.now() });
    return send(res, 200, { ok: true, person }, { 'set-cookie': S.setCookieHeader(secret, sid) });
  }

  function handleLogout(req, res) {
    if (!peopleApp) return send(res, 404, { ok: false, reason: 'not-found' });
    if (req.method !== 'POST') return send(res, 405, { ok: false, reason: 'method-not-allowed' }, { allow: 'POST' });
    if (!hostOK(req)) return send(res, 403, { ok: false, reason: 'host-refused' });
    if (!originOK(req)) return send(res, 403, { ok: false, reason: 'origin-refused' });
    const sid = S.verifySessionCookie(secret, req.headers.cookie);
    if (sid !== null) sessions.delete(sid);
    return send(res, 200, { ok: true }, { 'set-cookie': S.clearCookieHeader() });
  }

  function handleMe(req, res) {
    if (!peopleApp) return send(res, 404, { ok: false, reason: 'not-found' });
    if (req.method !== 'GET') return send(res, 405, { ok: false, reason: 'method-not-allowed' }, { allow: 'GET' });
    if (!hostOK(req)) return send(res, 403, { ok: false, reason: 'host-refused' });
    const session = sessionOf(req);
    return send(res, 200, { person: session === null ? null : personOf(session.user), people: roster() });
  }

  async function handlePeek(req, res) {
    if (!historyApp) return send(res, 404, { ok: false, reason: 'not-found' });
    if (req.method !== 'GET') return send(res, 405, { ok: false, reason: 'method-not-allowed' }, { allow: 'GET' });
    if (!hostOK(req)) return send(res, 403, { ok: false, reason: 'host-refused' });
    let url;
    try { url = new URL(req.url, `http://127.0.0.1:${boundPort}`); }
    catch { return send(res, 400, { ok: false, reason: 'malformed-url' }); }
    const raw = url.searchParams.get('revision');
    const revision = raw !== null && /^[0-9]{1,9}$/.test(raw) ? Number(raw) : NaN;
    if (!Number.isSafeInteger(revision)) return send(res, 400, { ok: false, reason: 'malformed-revision' });
    const request = ++nextControl;
    let frame;
    try { frame = await authority.ask('peek', request, H.bmap([[H.kw('request'), request], [H.kw('revision'), revision]])); }
    catch { return send(res, 503, { ok: false, reason: 'authority-unavailable' }); }
    return send(res, 200, { revision: frame.revision, board: frame.board ?? null });
  }

  // Which app this process serves, and the digest it must agree on.
  function handleApp(req, res) {
    if (req.method !== 'GET') return send(res, 405, { ok: false, reason: 'method-not-allowed' }, { allow: 'GET' });
    if (!hostOK(req)) return send(res, 403, { ok: false, reason: 'host-refused' });
    return send(res, 200, { app, digest: codec.digest });
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
    const session = sessionOf(req);
    const cur = authority.current;
    const hello = { digest: codec.digest, ...cur };
    if (peopleApp) { hello.people = roster(); hello.me = session === null ? null : personOf(session.user); }
    if (authority.extra.recent !== null) hello.recent = authority.extra.recent;
    if (authority.extra.history !== null) hello.history = authority.extra.history;
    res.write(`event: hello\ndata: ${JSON.stringify(hello)}\n\n`);
    const record = { res, user: session === null ? null : session.user };
    streams.add(record);
    if (peopleApp) { res.write(presenceLine(lastPresence)); pushPresence(); }
    const ping = setInterval(() => res.write(': ping\n\n'), 15000);
    req.on('close', () => {
      clearInterval(ping);
      streams.delete(record);
      if (peopleApp) pushPresence();
    });
  }

  async function handleStatic(req, res, pathname) {
    if (req.method !== 'GET' && req.method !== 'HEAD')
      return send(res, 405, { ok: false, reason: 'method-not-allowed' }, { allow: 'GET, HEAD' });
    const entry = STATIC.get(pathname);
    if (!entry) return send(res, 404, { ok: false, reason: 'not-found' });
    const [file, type, csp] = entry;
    let data;
    try { data = await readFile(new URL(file, dir)); }
    catch {
      // An app may ship no stylesheet and no page metadata: the shell still works.
      if (pathname === '/app.css') data = Buffer.alloc(0);
      else if (pathname === '/app.page.json') data = Buffer.from(JSON.stringify({ title: app, lede: '', hints: [] }));
      else return send(res, 500, { ok: false, reason: 'static-unavailable' });
    }
    res.writeHead(200, {
      'content-type': type, 'content-length': data.length, 'cache-control': 'no-store',
      'x-content-type-options': 'nosniff', ...(csp ? { 'content-security-policy': csp } : {}),
    });
    res.end(req.method === 'HEAD' ? undefined : data);
  }

  const server = createServer((req, res) => {
    if (/(?:\.\.|%2e|%2f|%5c|\\)/i.test(req.url || '')) return send(res, 404, { ok: false, reason: 'not-found' });
    let pathname;
    try { pathname = new URL(req.url, `http://127.0.0.1:${boundPort}`).pathname; }
    catch { return send(res, 400, { ok: false, reason: 'malformed-url' }); }
    const task = pathname === '/api/app' ? handleApp(req, res)
      : pathname === '/api/intent' ? handleIntent(req, res)
      : pathname === '/api/events' ? handleEvents(req, res)
      : pathname === '/api/login' ? handleLogin(req, res)
      : pathname === '/api/logout' ? handleLogout(req, res)
      : pathname === '/api/me' ? handleMe(req, res)
      : pathname === '/api/peek' ? handlePeek(req, res)
      : handleStatic(req, res, pathname);
    Promise.resolve(task).catch(() => send(res, 500, { ok: false, reason: 'internal-error' }));
  });

  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  boundPort = server.address().port;
  return {
    port: boundPort, server, codec,
    close: () => new Promise(resolve => {
      for (const s of streams) s.res.end();
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
