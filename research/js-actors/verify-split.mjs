// verify-split.mjs — the split showcase, end to end, without a browser.
//
// Proves on the GENERATED artifacts (run the source build first):
//   * the contract digest is the SHA-256 of its canonical body;
//   * the client bundle holds none of the server-only code or data;
//   * the codec refuses every malformed proposal by contract;
//   * the BL authority commits, refuses (shared check, server-only guard,
//     stale revision, outdated client) and fans snapshots out over SSE;
//   * the BL client half (run in a child process, as the Worker runs it)
//     renders, checks locally, proposes, adopts results and rebases.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createCodec, encode } from './split-codec.mjs';
import { startSplitServer } from './split-server.mjs';

const here = new URL('./', import.meta.url);
const read = p => readFileSync(new URL(p, here), 'utf8');
let passed = 0;
const ok = (label) => { passed++; console.log('PASS split: ' + label); };

// ── the generated artifacts ─────────────────────────────────────────────────
const contract = JSON.parse(read('out/showcase.contract.json'));
const manifest = JSON.parse(read('out/showcase.split.json'));
const client = read('out/showcase-client.mjs');
const serverBundle = read('out/showcase-server.mjs');

function canonical(v) {
  if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
  if (v && typeof v === 'object')
    return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + canonical(v[k])).join(',') + '}';
  return JSON.stringify(v);
}
const { digest, ...body } = contract;
assert.equal(createHash('sha256').update(canonical(body)).digest('hex'), digest);
assert.equal(manifest.digest, digest);
ok('contract digest is SHA-256 of its canonical body, shared by the manifest');

const where = Object.fromEntries(manifest.functions.map(f => [f.name, f.placement]));
assert.equal(where['board-view'], 'client');
assert.equal(where['add-problem'], 'shared');
assert.equal(where['flagged-title?'], 'server');
for (const f of manifest.functions)
  if (f.placement === 'client' || f.placement === 'shared') assert.equal(f.portable, true, f.name);
ok('every client/shared function carries a portable verdict');

const fn = name => manifest.functions.find(f => f.name === name);
assert.equal(fn('arrange').placement, 'client');
assert.equal(fn('arrange').evidence['calls-values'], true);
for (const v of ['open-first', 'by-title']) {
  assert.equal(fn(v).placement, 'client', v);
  assert.equal(fn(v).evidence['used-as-value'], true, v);
  assert.equal(fn(v).evidence['calls-values'], false, v);
}
assert.ok(client.includes('"js/arrange"') && client.includes('"js/rt-sort-by"'));
ok('a function that calls function values is admitted to the browser, with its evidence');

// Higher order: predicates built by combinators and folded into one.
for (const n of ['chips', 'all-of', 'chip-filter', 'ends-with', 'longer-than']) assert.equal(fn(n).placement, 'client', n);
assert.equal(fn('all-of').evidence['calls-values'], true);
assert.equal(fn('all-of').evidence.recursion, 'capture-order', 'the fold composes closures of its own kind');
assert.equal(fn('longer-than').evidence['used-as-value'], true, 'handed to partial');
for (const rt of ['core-comp', 'core-partial', 'core-complement', 'core-constantly'])
  assert.ok(client.includes(`"js/${rt}"`), rt);
ok('predicates composed with comp/partial/complement and a returned closure run in the browser');

for (const needle of ['api key', 'blocked-words', 'flagged-title', 'contains-word', 'initial-board',
                      'log-entry', ':audit', 'next-id', '"js/add-task"'])
  assert.equal(client.includes(needle), false, `client bundle leaks ${needle}`);
assert.ok(serverBundle.includes('api key'));
ok('server-only code and data are absent from the client bundle');

// ── the codec ───────────────────────────────────────────────────────────────
const codec = createCodec(contract);
const good = { request: 1, revision: 0, digest, op: 'add-task', args: { title: 'Ship it' } };
assert.equal(codec.decodeProposal(good).ok, true);
const bad = [
  [{ ...good, extra: 1 }, 'malformed-proposal'],
  [{ ...good, digest: '0'.repeat(64) }, 'client-outdated'],
  [{ ...good, op: 'drop-table' }, 'unknown-intent'],
  [{ ...good, args: { title: '' } }, 'malformed-args'],
  [{ ...good, args: { title: 'x'.repeat(49) } }, 'malformed-args'],
  [{ ...good, args: { title: 'ok', admin: true } }, 'malformed-args'],
  [{ ...good, op: 'toggle-task', args: { id: 1.5 } }, 'malformed-args'],
  [{ ...good, op: 'toggle-task', args: { id: 10000 } }, 'malformed-args'],
  [{ ...good, request: 0 }, 'malformed-proposal'],
  [null, 'malformed-proposal'],
];
for (const [json, reason] of bad) assert.equal(codec.decodeProposal(json).reason, reason, JSON.stringify(json));
assert.throws(() => codec.decodeSnapshot({ tasks: [{ id: 1, title: 't', done: true, secret: 1 }] }), /record keys/);
ok(`codec refuses ${bad.length} malformed proposals and an over-wide snapshot`);

// ── the authority over HTTP ─────────────────────────────────────────────────
const service = await startSplitServer({ port: 0 });
const base = `http://127.0.0.1:${service.port}`;
const post = async (json) => {
  const r = await fetch(base + '/api/intent', { method: 'POST', headers: { 'content-type': 'application/json' },
                                                 body: JSON.stringify(json) });
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
})();
const until = async (pred, label) => {
  for (let i = 0; i < 200; i++) { if (pred()) return; await new Promise(r => setTimeout(r, 10)); }
  throw new Error('timed out waiting for ' + label);
};
await until(() => events.some(e => e.type === 'hello'), 'hello');
const hello = events.find(e => e.type === 'hello').data;
assert.equal(hello.revision, 0);
assert.deepEqual(Object.keys(hello.board), ['tasks']);
assert.equal(hello.board.tasks.length, 3);
ok('SSE hello carries the projected snapshot (no :audit, no :next-id)');

let r = await post({ ...good, request: 7 });
assert.equal(r.status, 200);
assert.equal(r.body.ok, true);
assert.equal(r.body.request, 7);
assert.equal(r.body.revision, 1);
assert.equal(r.body.board.tasks.at(-1).title, 'Ship it');
assert.equal(r.body.board.tasks.at(-1).id, 4);
await until(() => events.some(e => e.type === 'snapshot' && e.data.revision === 1), 'snapshot 1');
ok('add-task commits: revision 0→1, id from server state, snapshot fanned out');

r = await post({ ...good, request: 8, revision: 0, args: { title: 'Again' } });
assert.equal(r.status, 409);
assert.equal(r.body.reason, 'stale-revision');
assert.equal(r.body.revision, 1);
ok('stale revision refused with the current board');

r = await post({ ...good, request: 9, revision: 1 });
assert.equal(r.body.reason, 'duplicate-title');
r = await post({ ...good, request: 10, revision: 1, args: { title: 'my api key here' } });
assert.equal(r.status, 422);
assert.equal(r.body.reason, 'looks-like-a-credential');
ok('shared check re-runs on the server; server-only guard refuses a credential title');

r = await post({ request: 11, revision: 1, digest, op: 'toggle-task', args: { id: 4 } });
assert.equal(r.body.ok, true);
assert.equal(r.body.board.tasks.find(t => t.id === 4).done, true);
r = await post({ request: 12, revision: 2, digest, op: 'toggle-task', args: { id: 999 } });
assert.equal(r.body.reason, 'no-such-task');
r = await post({ request: 13, revision: 2, digest, op: 'clear-done', args: {} });
assert.equal(r.body.ok, true);
assert.equal(r.body.board.tasks.every(t => !t.done), true);
r = await post({ request: 14, revision: 3, digest, op: 'clear-done', args: {} });
assert.equal(r.body.reason, 'nothing-to-clear');
ok('toggle and clear commit; their checks refuse no-op requests');

r = await post({ ...good, request: 15, digest: 'f'.repeat(64) });
assert.equal(r.status, 409);
assert.equal(r.body.reason, 'client-outdated');
ok('an outdated client build is told so, with the current board');

for (const path of ['/out/showcase-server.mjs', '/showcase.bl', '/split-server.bl', '/../package.json'])
  assert.equal((await fetch(base + path)).status, 404, path);
assert.equal((await fetch(base + '/out/showcase-client.mjs')).status, 200);
ok('the server half and the app source are never served; the client half is');

// ── the BL client half, as the Worker runs it ───────────────────────────────
const child = spawn(process.execPath, ['--input-type=module', '-e', `
  import * as H from './host.mjs';
  import { createCodec, encode, frameToBL } from './split-codec.mjs';
  import { readFileSync } from 'node:fs';
  const codec = createCodec(JSON.parse(readFileSync('out/showcase.contract.json', 'utf8')));
  const out = [];
  H.setEmitter((topic, value) => { process.stdout.write(JSON.stringify({ topic, value: encode(value) }) + '\\n'); });
  process.stdin.setEncoding('utf8');
  let buf = '';
  process.stdin.on('data', d => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\\n')) >= 0) {
      const msg = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
      if (msg.kind === 'hello') H.enqueueData('hello', H.bmap([[H.kw('digest'), msg.digest], [H.kw('revision'), msg.revision], [H.kw('board'), codec.decodeSnapshot(msg.board)]]));
      else if (msg.kind === 'event') H.enqueueData('event', H.vec(msg.event.map(x => typeof x === 'string' && x.startsWith(':') ? H.kw(x.slice(1)) : x)));
      else if (msg.kind === 'unreachable') H.enqueueData('unreachable', msg.request);
      else if (msg.kind === 'result' || msg.kind === 'snapshot') H.enqueueData(msg.kind, frameToBL(codec, msg.frame));
      else if (msg.kind === 'stop') H.enqueueData('stop', '');
    }
  });
  await import('./out/showcase-client.mjs');
`], { cwd: new URL('.', here).pathname, stdio: ['pipe', 'pipe', 'inherit'] });

const frames = [];
let cbuf = '';
child.stdout.setEncoding('utf8');
child.stdout.on('data', d => {
  cbuf += d;
  let i;
  while ((i = cbuf.indexOf('\n')) >= 0) { frames.push(JSON.parse(cbuf.slice(0, i))); cbuf = cbuf.slice(i + 1); }
});
const tell = m => child.stdin.write(JSON.stringify(m) + '\n');
const next = async (topic, from) => {
  await until(() => frames.slice(from).some(f => f.topic === topic), topic);
  return frames.slice(from).find(f => f.topic === topic);
};
const texts = (node, acc = []) => {
  if (typeof node === 'string') acc.push(node);
  else if (Array.isArray(node)) node.forEach(n => texts(n, acc));
  return acc;
};

await next('ready', 0);
const now = await (await fetch(base + '/api/events')).body.getReader().read();
const helloNow = JSON.parse(/data: (.*)\n/.exec(new TextDecoder().decode(now.value))[1]);
let mark = frames.length;
tell({ kind: 'hello', ...helloNow });
let view = await next('view', mark);
assert.equal(view.value.revision, helloNow.revision);
assert.ok(texts(view.value.tree).includes('Launch checklist'));
ok('BL client renders the confirmed snapshot');

mark = frames.length;
tell({ kind: 'event', event: [':draft', 'Write the release notes'] });
await next('view', mark);
mark = frames.length;
tell({ kind: 'event', event: [':submit'] });
view = await next('view', mark);
assert.equal(frames.slice(mark).some(f => f.topic === 'propose'), false);
assert.ok(texts(view.value.tree).includes('duplicate-title'));
assert.ok(texts(view.value.tree).includes('Checked in your browser: '));
ok('shared check refuses a duplicate IN THE BROWSER — no proposal leaves');

mark = frames.length;
tell({ kind: 'event', event: [':draft', 'Book the venue'] });
await next('view', mark);
mark = frames.length;
tell({ kind: 'event', event: [':submit'] });
const proposal = (await next('propose', mark)).value;
view = await next('view', mark);
assert.equal(proposal.op, 'add-task');
assert.equal(proposal.revision, helloNow.revision);
assert.ok(texts(view.value.tree).includes('sending'));
ok('a valid submit proposes once and shows a pending ghost row');

r = await post(proposal);
assert.equal(r.body.ok, true);
mark = frames.length;
tell({ kind: 'result', frame: r.body });
view = await next('view', mark);
assert.equal(view.value.revision, helloNow.revision + 1);
assert.ok(texts(view.value.tree).includes('Book the venue'));
assert.equal(texts(view.value.tree).includes('sending'), false);
ok('the confirmed result replaces the ghost with the server-assigned row');

// Sorting is a COMPUTED call in the browser: local state only, no proposal.
const rowTitles = tree => {
  const out = [];
  const walk = n => {
    if (!Array.isArray(n)) return;
    if (n[0] === 'li' && n[1] && typeof n[1].key === 'string' && n[1].key.startsWith('t')) {
      const t = n.find(c => Array.isArray(c) && c[0] === 'span' && c[1].class === 'title');
      out.push(t[2]);
      return;
    }
    n.forEach(walk);
  };
  walk(tree);
  return out;
};
const added = rowTitles(view.value.tree);
const orderings = [
  [':title', xs => [...xs].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))],
  [':recent', xs => [...xs].reverse()],
  [':added', xs => xs],
];
for (const [key, expect] of orderings) {
  mark = frames.length;
  tell({ kind: 'event', event: [':order', key] });
  view = await next('view', mark);
  assert.deepEqual(rowTitles(view.value.tree), expect(added), key);
  assert.equal(frames.slice(mark).some(f => f.topic === 'propose'), false);
  assert.equal(view.value.revision, helloNow.revision + 1);
}
// `open-first` is a NAMED comparator passed as a value: with every task open
// it keeps the added order; a confirmed toggle then moves that task last.
mark = frames.length;
tell({ kind: 'event', event: [':order', ':open'] });
view = await next('view', mark);
assert.deepEqual(rowTitles(view.value.tree), added);
const firstId = (() => {
  let id = null;
  const walk = n => { if (id === null && Array.isArray(n)) { if (n[0] === 'li' && n[1]?.key?.startsWith('t')) id = Number(n[1].key.slice(1)); else n.forEach(walk); } };
  walk(view.value.tree);
  return id;
})();
mark = frames.length;
tell({ kind: 'event', event: [':toggle', firstId] });
const doneIt = (await next('propose', mark)).value;
r = await post(doneIt);
assert.equal(r.body.ok, true);
mark = frames.length;
tell({ kind: 'result', frame: r.body });
view = await next('view', mark);
const open = rowTitles(view.value.tree);
assert.equal(open[open.length - 1], added[0], 'the task just done sorts last');
assert.deepEqual(open.slice(0, -1), added.slice(1));
mark = frames.length;
tell({ kind: 'event', event: [':order', ':added'] });
await next('view', mark);
ok('sort orders are function values called in the browser: every order right, no network');

// Refine chips: each is a composed predicate; active chips fold into one.
const allRows = () => rowTitles(frames.filter(f => f.topic === 'view').at(-1).value.tree);
const everyRow = allRows();
const chipTo = async (k) => { mark = frames.length; tell({ kind: 'event', event: [':chip', k] }); return (await next('view', mark)).value; };
view = await chipTo(':open');
assert.deepEqual(rowTitles(view.tree), everyRow.filter(t => t !== added[0]), 'open: (complement :done)');
view = await chipTo(':long');
assert.deepEqual(rowTitles(view.tree), everyRow.filter(t => t !== added[0] && t.length > 20), 'open AND long: (partial longer-than 20)');
view = await chipTo(':open');
assert.deepEqual(rowTitles(view.tree), everyRow.filter(t => t.length > 20), 'long only, after toggling open off');
view = await chipTo(':long');
assert.deepEqual(rowTitles(view.tree), everyRow, 'no chip: (constantly true)');
assert.equal(frames.slice(mark).some(f => f.topic === 'propose'), false);
ok('refine chips fold composed predicates into one, in the browser, with no network');

// Another tab wins: a toggle proposed against an old revision is rebased.
mark = frames.length;
tell({ kind: 'event', event: [':toggle', 2] });
const stale = (await next('propose', mark)).value;
const other = await post({ request: 99, revision: stale.revision, digest, op: 'add-task', args: { title: 'Other tab' } });
assert.equal(other.body.ok, true);
r = await post(stale);
assert.equal(r.body.reason, 'stale-revision');
mark = frames.length;
tell({ kind: 'result', frame: r.body });
const rebased = (await next('propose', mark)).value;
assert.equal(rebased.revision, other.body.revision);
assert.equal(rebased.op, 'toggle-task');
r = await post(rebased);
assert.equal(r.body.ok, true);
mark = frames.length;
tell({ kind: 'result', frame: r.body });
view = await next('view', mark);
assert.ok(texts(view.value.tree).includes('Other tab'));
assert.ok(frames.some(f => f.topic === 'trace' && f.value.step === 'rebased'));
ok('a stale proposal is rebased by the BL client and re-checked, then commits');

mark = frames.length;
tell({ kind: 'event', event: [':draft', 'the secret plan'] });
await next('view', mark);
mark = frames.length;
tell({ kind: 'event', event: [':submit'] });
const secret = (await next('propose', mark)).value;
r = await post(secret);
mark = frames.length;
tell({ kind: 'result', frame: r.body });
view = await next('view', mark);
assert.ok(texts(view.value.tree).includes('Refused by the server: '));
assert.ok(texts(view.value.tree).includes('looks-like-a-credential'));
const inputOf = tree => {
  let found = null;
  const walk = n => { if (Array.isArray(n)) { if (n[0] === 'input') found = n[1]; n.forEach(walk); } };
  walk(tree);
  return found;
};
assert.equal(inputOf(view.value.tree).value, 'the secret plan', 'a refused submit gives the draft back');
ok('the browser cannot pre-check a server-only guard; its refusal is labelled as the server\'s');

// No answer at all: the pending intent is dropped, the board does not move.
mark = frames.length;
tell({ kind: 'event', event: [':draft', 'Offline idea'] });
await next('view', mark);
mark = frames.length;
tell({ kind: 'event', event: [':submit'] });
const lost = (await next('propose', mark)).value;
const before = frames.filter(f => f.topic === 'view').at(-1).value.revision;
mark = frames.length;
tell({ kind: 'unreachable', request: lost.request });
// the actor traces first, then renders: wait for the view AFTER the trace
const afterTrace = () => {
  const i = frames.findIndex((f, j) => j >= mark && f.topic === 'trace' && f.value.step === 'unreachable');
  return i < 0 ? undefined : frames.slice(i).find(f => f.topic === 'view');
};
await until(() => afterTrace() !== undefined, 'view after the unreachable trace');
view = afterTrace();
assert.equal(view.value.revision, before);
assert.ok(texts(view.value.tree).includes('server-unreachable'));
assert.equal(inputOf(view.value.tree).value, 'Offline idea', 'the draft comes back for a retry');
assert.equal(texts(view.value.tree).includes('sending'), false, 'no ghost row survives');
assert.equal(texts(view.value.tree).filter(t => t === 'Offline idea').length, 0, 'the title is not a task row');
ok('an unanswered intent is dropped, never assumed committed, and its draft returns');

// Typing after submit wins: a later failure must not overwrite newer text.
mark = frames.length;
tell({ kind: 'event', event: [':submit'] });
const lost2 = (await next('propose', mark)).value;
mark = frames.length;
tell({ kind: 'event', event: [':draft', 'something newer'] });
await next('view', mark);
mark = frames.length;
tell({ kind: 'unreachable', request: lost2.request });
await until(() => afterTrace() !== undefined, 'view after the second unreachable trace');
assert.equal(inputOf(afterTrace().value.tree).value, 'something newer');
ok('a failure never overwrites text typed after the submit');

tell({ kind: 'stop' });
child.stdin.end();
await new Promise(res => child.on('exit', res));
await reader.cancel();
await service.close();
console.log(`js-actors: SPLIT PASS (${passed} checks)`);
