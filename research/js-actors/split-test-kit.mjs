// split-test-kit.mjs — reusable helpers for driving a compiled split app end
// to end, without a browser.
//
// Extracted from verify-split.mjs's patterns and parameterized by app name:
//
//   startApp(app)      a loopback server (a fresh BL authority) + base URL +
//                      post(json) + an SSE collector (`events`) with
//                      `until(pred, label)` and `snapshotNow()` (the current
//                      hello, read from a throwaway stream)
//   spawnClient(app)   the BL client half in a child process exactly as the
//                      browser Worker feeds it: JSON frames on stdout, stdin
//                      fed with hello/event/result/unreachable/stop, returning
//                      `{ frames, tell, next(topic, fromIndex), close }`
//   texts(node)        every string in a view tree
//   findAll(tree, p)   every view node (array) matching a predicate
//   attr(node)         a view node's attribute map, or null
//
// One `startSplitServer` per process: host.mjs keeps ONE active BL runtime, so
// every helper here is built for a single app process.

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { startSplitServer } from './split-server.mjs';

export const HERE = new URL('./', import.meta.url);

export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// A generated artifact under out/, read as text (e.g. 'outline.contract.json').
export const readOut = (file) => readFileSync(new URL(`out/${file}`, HERE), 'utf8');

// The contract's canonical body encoding: the exact form `digest` hashes.
export function canonical(v) {
  if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
  if (v && typeof v === 'object')
    return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + canonical(v[k])).join(',') + '}';
  return JSON.stringify(v);
}

export const contractDigest = contract =>
  createHash('sha256').update(canonical((({ digest, ...body }) => body)(contract))).digest('hex');

// A tab id is the client's identity on the wire: its proposals carry
// `<tab>:<request>` as a nonce, and the hello declares it. It must match the
// wire's /^[a-z0-9]{8,32}$/.
export const DEFAULT_TAB = 'kitclient0000001';

// A proposal's nonce: this tab's id and the request number, stable across
// resends. The server commits a nonce at most once, so a resend is safe even
// if the first answer was lost.
export const nonce = (tab, request) => `${tab}:${request}`;

// The child runs the generated client bundle with the same host bridge the
// browser Worker uses; the app name picks the contract and the bundle, and the
// tab id is the identity every hello declares.
const clientSource = (app, tab) => `
  import * as H from './host.mjs';
  import { createCodec, encode, frameToBL, helloToBL, presenceToBL } from './split-codec.mjs';
  import { readFileSync } from 'node:fs';
  const codec = createCodec(JSON.parse(readFileSync('out/${app}.contract.json', 'utf8')));
  H.setEmitter((topic, value) => { process.stdout.write(JSON.stringify({ topic, value: encode(value) }) + '\\n'); });
  process.stdin.setEncoding('utf8');
  let buf = '';
  process.stdin.on('data', d => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\\n')) >= 0) {
      const msg = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
      if (msg.kind === 'hello') H.enqueueData('hello', helloToBL(codec, msg, ${JSON.stringify(tab)}));
      else if (msg.kind === 'presence') H.enqueueData('presence', presenceToBL(msg));
      else if (msg.kind === 'event') H.enqueueData('event', H.vec(msg.event.map(x => typeof x === 'string' && x.startsWith(':') ? H.kw(x.slice(1)) : x)));
      else if (msg.kind === 'asof') {
        const past = msg.board ? codec.decodeSnapshot(msg.board) : null;
        H.enqueueData('asof', past && Number.isSafeInteger(msg.revision)
          ? H.bmap([[H.kw('revision'), msg.revision], [H.kw('board'), past]]) : H.bmap([]));
      }
      else if (msg.kind === 'unreachable') H.enqueueData('unreachable', msg.request);
      else if (msg.kind === 'offline' || msg.kind === 'online') H.enqueueData(msg.kind, '');
      else if (msg.kind === 'result' || msg.kind === 'snapshot') H.enqueueData(msg.kind, frameToBL(codec, msg.frame));
      else if (msg.kind === 'stop') H.enqueueData('stop', '');
    }
  });
  await import('./out/${app}-client.mjs');
`;

export async function startApp(app, options = {}) {
  const service = await startSplitServer({ port: 0, app, ...options });
  const base = `http://127.0.0.1:${service.port}`;
  const post = async (json) => {
    const r = await fetch(base + '/api/intent', { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify(json) });
    return { status: r.status, body: await r.json() };
  };

  const events = [];
  const sse = await fetch(base + '/api/events');
  const reader = sse.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  (async () => {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      buffer += decoder.decode(value, { stream: true });
      let i;
      while ((i = buffer.indexOf('\n\n')) >= 0) {
        const chunk = buffer.slice(0, i); buffer = buffer.slice(i + 2);
        const ev = /^event: (\w+)\ndata: (.*)$/m.exec(chunk);
        if (ev) events.push({ type: ev[1], data: JSON.parse(ev[2]) });
      }
    }
  })().catch(() => {});

  const until = async (pred, label, timeoutMs = 5000) => {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) { if (pred()) return; await sleep(10); }
    throw new Error('timed out waiting for ' + label);
  };

  // The CURRENT snapshot: open a fresh stream, read its hello, hang up.
  const snapshotNow = async () => {
    const r = await fetch(base + '/api/events');
    const rd = r.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    try {
      for (;;) {
        const { value, done } = await rd.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        const m = /^event: hello\ndata: (.*)$/m.exec(buf);
        if (m) return JSON.parse(m[1]);
      }
    } finally { try { await rd.cancel(); } catch { /* already closed */ } }
    throw new Error('no hello on the events stream');
  };

  const close = async () => {
    try { await reader.cancel(); } catch { /* already closed */ }
    await service.close();
  };

  return { app, service, codec: service.codec, base, post, events, until, snapshotNow, close };
}

export function spawnClient(app, { tab = DEFAULT_TAB } = {}) {
  if (typeof tab !== 'string' || !/^[a-z0-9]{8,32}$/.test(tab))
    throw new Error('spawnClient: tab must match /^[a-z0-9]{8,32}$/');
  const child = spawn(process.execPath, ['--input-type=module', '-e', clientSource(app, tab)],
                      { cwd: HERE.pathname, stdio: ['pipe', 'pipe', 'inherit'] });
  const frames = [];
  let buffer = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', d => {
    buffer += d;
    let i;
    while ((i = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, i); buffer = buffer.slice(i + 1);
      if (line.trim() !== '') frames.push(JSON.parse(line));
    }
  });

  const tell = m => child.stdin.write(JSON.stringify(m) + '\n');
  const next = async (topic, fromIndex = 0, timeoutMs = 15000) => {
    const start = Date.now();
    for (;;) {
      const hit = frames.slice(fromIndex).find(f => f.topic === topic);
      if (hit) return hit;
      if (Date.now() - start >= timeoutMs) throw new Error('timed out waiting for client frame ' + topic);
      await sleep(10);
    }
  };
  const close = async () => {
    if (child.exitCode !== null) return;
    try { tell({ kind: 'stop' }); child.stdin.end(); } catch { /* already gone */ }
    await new Promise(resolve => {
      const timer = setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* gone */ } resolve(); }, 3000);
      child.once('exit', () => { clearTimeout(timer); resolve(); });
    });
  };
  return { child, frames, tell, next, close, tab };
}

// Every string anywhere in a view tree.
export function texts(node, acc = []) {
  if (typeof node === 'string') acc.push(node);
  else if (Array.isArray(node)) for (const n of node) texts(n, acc);
  return acc;
}

// Every view node (an array) matching `pred`, depth first.
export function findAll(tree, pred, acc = []) {
  if (Array.isArray(tree)) {
    if (pred(tree)) acc.push(tree);
    for (const n of tree) findAll(n, pred, acc);
  }
  return acc;
}

// A view node's attribute map: `[:tag {...} ...]` → `{...}`, else null.
export function attr(node) {
  return Array.isArray(node) && node[1] !== null && typeof node[1] === 'object' && !Array.isArray(node[1])
    ? node[1] : null;
}
