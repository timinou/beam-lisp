// verify-split.mjs — the split showcase, end to end, without a browser.
//
// Drives the GENERATED artifacts through the shared kit (split-test-kit.mjs):
// one loopback authority, one child process running the BL client half exactly
// as the Worker runs it. Proves:
//   * the contract digest is the SHA-256 of its canonical body;
//   * the client bundle holds none of the server-only code or data;
//   * the codec refuses every malformed proposal by contract (including a
//     missing or ill-formed nonce);
//   * the BL authority commits, refuses (shared check, server-only guard,
//     stale revision, outdated client) and fans snapshots out over SSE;
//   * the BL client half renders, checks locally, proposes, adopts results and
//     rebases;
//   * an unanswered intent stays PENDING as :queued (the link goes down, the
//     note says so, nothing is sent), `:online` re-proposes the SAME proposal,
//     the server commits its nonce once and answers a repeat as `duplicate`.

import assert from 'node:assert/strict';
import { startApp, spawnClient, texts, contractDigest, nonce, sleep, readOut } from './split-test-kit.mjs';
import { createCodec } from './split-codec.mjs';

let passed = 0;
const ok = (label) => { passed += 1; console.log('PASS split: ' + label); };

// Hand-crafted proposals come from a fixed "tab" distinct from the BL client's
// so no nonce can collide with one the child proposes.
const HTTP_TAB = 'splithttp0000001';

// ── the generated artifacts ─────────────────────────────────────────────────
const contract = JSON.parse(readOut('showcase.contract.json'));
const manifest = JSON.parse(readOut('showcase.split.json'));
const clientBundle = readOut('showcase-client.mjs');
const serverBundle = readOut('showcase-server.mjs');
const digest = contract.digest;

assert.equal(contractDigest(contract), digest);
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
assert.ok(clientBundle.includes('"js/arrange"') && clientBundle.includes('"js/rt-sort-by"'));
ok('a function that calls function values is admitted to the browser, with its evidence');

// Higher order: predicates built by combinators and folded into one.
for (const n of ['chips', 'all-of', 'chip-filter', 'ends-with', 'longer-than']) assert.equal(fn(n).placement, 'client', n);
assert.equal(fn('all-of').evidence['calls-values'], true);
assert.equal(fn('all-of').evidence.recursion, 'capture-order', 'the fold composes closures of its own kind');
assert.equal(fn('longer-than').evidence['used-as-value'], true, 'handed to partial');
for (const rt of ['core-comp', 'core-partial', 'core-complement', 'core-constantly'])
  assert.ok(clientBundle.includes(`"js/${rt}"`), rt);
ok('predicates composed with comp/partial/complement and a returned closure run in the browser');

for (const needle of ['api key', 'blocked-words', 'flagged-title', 'contains-word', 'initial-board',
                      'log-entry', ':audit', 'next-id', '"js/add-task"'])
  assert.equal(clientBundle.includes(needle), false, `client bundle leaks ${needle}`);
assert.ok(serverBundle.includes('api key'));
ok('server-only code and data are absent from the client bundle');

// ── the codec ───────────────────────────────────────────────────────────────
const codec = createCodec(contract);
const good = { request: 1, revision: 0, digest, nonce: nonce(HTTP_TAB, 1), op: 'add-task', args: { title: 'Ship it' } };
assert.equal(codec.decodeProposal(good).ok, true);
const bad = [
  [{ ...good, extra: 1 }, 'malformed-proposal'],
  [{ ...good, nonce: undefined }, 'malformed-proposal'],
  [{ ...good, nonce: 'not-a-nonce' }, 'malformed-proposal'],
  [{ ...good, nonce: 'x:1' }, 'malformed-proposal'],
  [{ ...good, nonce: `${HTTP_TAB}:` }, 'malformed-proposal'],
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
ok(`codec refuses ${bad.length} malformed proposals (nonce included) and an over-wide snapshot`);

// ── the authority over HTTP, and the shared shell ───────────────────────────
const app = await startApp('showcase');
assert.equal(app.codec.digest, digest);

const appInfo = await (await fetch(app.base + '/api/app')).json();
assert.equal(appInfo.app, 'showcase');
assert.equal(typeof appInfo.digest, 'string');
const shellCss = await fetch(app.base + '/app.css');
assert.equal(shellCss.headers.get('content-type'), 'text/css; charset=utf-8');
assert.ok((await shellCss.text()).includes('#app'));
ok('/api/app names the app and /app.css serves its stylesheet as text/css');

await app.until(() => app.events.some(e => e.type === 'hello'), 'hello');
const hello = app.events.find(e => e.type === 'hello').data;
assert.equal(hello.revision, 0);
assert.deepEqual(Object.keys(hello.board), ['tasks']);
assert.equal(hello.board.tasks.length, 3);
ok('SSE hello carries the projected snapshot (no :audit, no :next-id)');

let rev = hello.revision;
let hreq = 0;
// A hand-crafted proposal with a fresh, unique nonce; `revision` defaults to the
// authority's current one.
const hp = (op, args, revision = rev) => {
  hreq += 1;
  return { request: hreq, revision, digest, nonce: nonce(HTTP_TAB, hreq), op, args };
};

let r = await app.post(hp('add-task', { title: 'Ship it' }));
assert.equal(r.status, 200);
assert.equal(r.body.ok, true);
assert.equal(r.body.request, 1);
assert.equal(r.body.revision, 1);
assert.equal(r.body.board.tasks.at(-1).title, 'Ship it');
assert.equal(r.body.board.tasks.at(-1).id, 4);
rev = r.body.revision;
await app.until(() => app.events.some(e => e.type === 'snapshot' && e.data.revision === 1), 'snapshot 1');
ok('add-task commits: revision 0→1, id from server state, snapshot fanned out');

r = await app.post(hp('add-task', { title: 'Again' }, 0));
assert.equal(r.status, 409);
assert.equal(r.body.reason, 'stale-revision');
assert.equal(r.body.revision, 1);
ok('stale revision refused with the current board');

r = await app.post(hp('add-task', { title: 'Ship it' }));
assert.equal(r.body.reason, 'duplicate-title');
r = await app.post(hp('add-task', { title: 'my api key here' }));
assert.equal(r.status, 422);
assert.equal(r.body.reason, 'looks-like-a-credential');
ok('shared check re-runs on the server; server-only guard refuses a credential title');

r = await app.post(hp('toggle-task', { id: 4 }));
assert.equal(r.body.ok, true);
assert.equal(r.body.board.tasks.find(t => t.id === 4).done, true);
rev = r.body.revision;
r = await app.post(hp('toggle-task', { id: 999 }));
assert.equal(r.body.reason, 'no-such-task');
r = await app.post(hp('clear-done', {}));
assert.equal(r.body.ok, true);
assert.equal(r.body.board.tasks.every(t => !t.done), true);
rev = r.body.revision;
r = await app.post(hp('clear-done', {}));
assert.equal(r.body.reason, 'nothing-to-clear');
ok('toggle and clear commit; their checks refuse no-op requests');

r = await app.post({ ...hp('add-task', { title: 'Outdated' }), digest: 'f'.repeat(64) });
assert.equal(r.status, 409);
assert.equal(r.body.reason, 'client-outdated');
ok('an outdated client build is told so, with the current board');

for (const path of ['/out/showcase-server.mjs', '/showcase.bl', '/split-server.bl', '/../package.json'])
  assert.equal((await fetch(app.base + path)).status, 404, path);
assert.equal((await fetch(app.base + '/out/showcase-client.mjs')).status, 200);
ok('the server half and the app source are never served; the client half is');

// ── the BL client half, as the Worker runs it ───────────────────────────────
const client = spawnClient('showcase');
await client.next('ready', 0);
const now = await app.snapshotNow();
assert.equal(now.revision, rev);
let mark = client.frames.length;
client.tell({ kind: 'hello', ...now });
let view = await client.next('view', mark);
assert.equal(view.value.revision, now.revision);
assert.ok(texts(view.value.tree).includes('Launch checklist'));
ok('BL client renders the confirmed snapshot');

mark = client.frames.length;
client.tell({ kind: 'event', event: [':draft', 'Write the release notes'] });
await client.next('view', mark);
mark = client.frames.length;
client.tell({ kind: 'event', event: [':submit'] });
view = await client.next('view', mark);
assert.equal(client.frames.slice(mark).some(f => f.topic === 'propose'), false);
assert.ok(texts(view.value.tree).includes('duplicate-title'));
assert.ok(texts(view.value.tree).includes('Checked in your browser: '));
ok('shared check refuses a duplicate IN THE BROWSER — no proposal leaves');

mark = client.frames.length;
client.tell({ kind: 'event', event: [':draft', 'Book the venue'] });
await client.next('view', mark);
mark = client.frames.length;
client.tell({ kind: 'event', event: [':submit'] });
const proposal = (await client.next('propose', mark)).value;
view = await client.next('view', mark);
assert.equal(proposal.op, 'add-task');
assert.equal(proposal.revision, now.revision);
assert.ok(texts(view.value.tree).includes('sending'));
ok('a valid submit proposes once and shows a pending ghost row');

r = await app.post(proposal);
assert.equal(r.body.ok, true);
rev = r.body.revision;
const afterAddRev = r.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
view = await client.next('view', mark);
assert.equal(view.value.revision, afterAddRev);
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
  mark = client.frames.length;
  client.tell({ kind: 'event', event: [':order', key] });
  view = await client.next('view', mark);
  assert.deepEqual(rowTitles(view.value.tree), expect(added), key);
  assert.equal(client.frames.slice(mark).some(f => f.topic === 'propose'), false);
  assert.equal(view.value.revision, afterAddRev);
}
// `open-first` is a NAMED comparator passed as a value: with every task open
// it keeps the added order; a confirmed toggle then moves that task last.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':order', ':open'] });
view = await client.next('view', mark);
assert.deepEqual(rowTitles(view.value.tree), added);
const firstId = (() => {
  let id = null;
  const walk = n => { if (id === null && Array.isArray(n)) { if (n[0] === 'li' && n[1]?.key?.startsWith('t')) id = Number(n[1].key.slice(1)); else n.forEach(walk); } };
  walk(view.value.tree);
  return id;
})();
mark = client.frames.length;
client.tell({ kind: 'event', event: [':toggle', firstId] });
const doneIt = (await client.next('propose', mark)).value;
r = await app.post(doneIt);
assert.equal(r.body.ok, true);
rev = r.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
view = await client.next('view', mark);
const open = rowTitles(view.value.tree);
assert.equal(open[open.length - 1], added[0], 'the task just done sorts last');
assert.deepEqual(open.slice(0, -1), added.slice(1));
mark = client.frames.length;
client.tell({ kind: 'event', event: [':order', ':added'] });
await client.next('view', mark);
ok('sort orders are function values called in the browser: every order right, no network');

// Refine chips: each is a composed predicate; active chips fold into one.
const allRows = () => rowTitles(client.frames.filter(f => f.topic === 'view').at(-1).value.tree);
const everyRow = allRows();
const chipTo = async (k) => { mark = client.frames.length; client.tell({ kind: 'event', event: [':chip', k] }); return (await client.next('view', mark)).value; };
view = await chipTo(':open');
assert.deepEqual(rowTitles(view.tree), everyRow.filter(t => t !== added[0]), 'open: (complement :done)');
view = await chipTo(':long');
assert.deepEqual(rowTitles(view.tree), everyRow.filter(t => t !== added[0] && t.length > 20), 'open AND long: (partial longer-than 20)');
view = await chipTo(':open');
assert.deepEqual(rowTitles(view.tree), everyRow.filter(t => t.length > 20), 'long only, after toggling open off');
view = await chipTo(':long');
assert.deepEqual(rowTitles(view.tree), everyRow, 'no chip: (constantly true)');
assert.equal(client.frames.slice(mark).some(f => f.topic === 'propose'), false);
ok('refine chips fold composed predicates into one, in the browser, with no network');

// Another tab wins: a toggle proposed against an old revision is rebased.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':toggle', 2] });
const stale = (await client.next('propose', mark)).value;
const other = await app.post(hp('add-task', { title: 'Other tab' }, stale.revision));
assert.equal(other.body.ok, true);
rev = other.body.revision;
r = await app.post(stale);
assert.equal(r.body.reason, 'stale-revision');
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
const rebased = (await client.next('propose', mark)).value;
assert.equal(rebased.revision, other.body.revision);
assert.equal(rebased.op, 'toggle-task');
r = await app.post(rebased);
assert.equal(r.body.ok, true);
rev = r.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
view = await client.next('view', mark);
assert.ok(texts(view.value.tree).includes('Other tab'));
assert.ok(client.frames.some(f => f.topic === 'trace' && f.value.step === 'rebased'));
ok('a stale proposal is rebased by the BL client and re-checked, then commits');

const inputOf = tree => {
  let found = null;
  const walk = n => { if (Array.isArray(n)) { if (n[0] === 'input') found = n[1]; n.forEach(walk); } };
  walk(tree);
  return found;
};

mark = client.frames.length;
client.tell({ kind: 'event', event: [':draft', 'the secret plan'] });
await client.next('view', mark);
mark = client.frames.length;
client.tell({ kind: 'event', event: [':submit'] });
const secret = (await client.next('propose', mark)).value;
r = await app.post(secret);
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
view = await client.next('view', mark);
assert.ok(texts(view.value.tree).includes('Refused by the server: '));
assert.ok(texts(view.value.tree).includes('looks-like-a-credential'));
assert.equal(inputOf(view.value.tree).value, 'the secret plan', 'a refused submit gives the draft back');
ok('the browser cannot pre-check a server-only guard; its refusal is labelled as the server\'s');

// No answer: the intent STAYS pending — :queued at the head — and the link is
// marked down. The board does not move and nothing is sent while down.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':draft', 'Offline idea'] });
await client.next('view', mark);
mark = client.frames.length;
client.tell({ kind: 'event', event: [':submit'] });
const lost = (await client.next('propose', mark)).value;
// The submit's instant render is a separate frame: drain it before the link
// test, or the first view after the mark would be that render, not the note.
const pendingView = await client.next('view', mark);
const beforeRev = pendingView.value.revision;
mark = client.frames.length;
client.tell({ kind: 'unreachable', request: lost.request });
view = await client.next('view', mark);
assert.equal(view.value.revision, beforeRev);
assert.ok(texts(view.value.tree).includes('offline'), 'the note names the offline link');
assert.ok(texts(view.value.tree).includes('Offline idea'), 'the intent is still pending');
assert.ok(texts(view.value.tree).includes('sending'), 'the pending row is still shown');
assert.ok(client.frames.slice(mark).some(f => f.topic === 'trace' && f.value.step === 'queued'));
ok('an unanswered intent stays pending (queued) with an offline note — never dropped');

// While the link is down, a second intent joins the queue but is NOT sent.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':draft', 'Second thought'] });
await client.next('view', mark);
mark = client.frames.length;
client.tell({ kind: 'event', event: [':submit'] });
view = await client.next('view', mark);
await sleep(50);
assert.equal(client.frames.slice(mark).some(f => f.topic === 'propose'), false,
             'no proposal leaves while the link is down');
ok('with the link down a second intent queues but nothing is sent');

// `:online` sends the head again: the SAME proposal (same nonce, op, args).
mark = client.frames.length;
client.tell({ kind: 'online' });
const again = (await client.next('propose', mark)).value;
assert.deepEqual(again, lost, 'the same proposal goes out again');
ok('online re-proposes the head: the same nonce, op and args');

r = await app.post(lost);
assert.equal(r.body.ok, true);
const committedRev = r.body.revision;
rev = committedRev;
const dup = await app.post(lost);
assert.equal(dup.body.ok, true);
assert.equal(dup.body.duplicate, true);
assert.equal(dup.body.revision, committedRev);
ok('the resent proposal commits once; the SAME proposal again is a duplicate, revision unchanged');

mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
const second = (await client.next('propose', mark)).value;
assert.equal(second.op, 'add-task');
assert.deepEqual(second.args, { title: 'Second thought' });
view = await client.next('view', mark);
assert.ok(texts(view.value.tree).includes('Offline idea'));
assert.ok(texts(view.value.tree).includes('Second thought'));
const r2 = await app.post(second);
assert.equal(r2.body.ok, true);
rev = r2.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r2.body });
view = await client.next('view', mark);
assert.equal(view.value.revision, r2.body.revision);
ok('after the first result settles, the queued intent is proposed automatically');

// Typing after submit wins: a refusal never overwrites text typed since.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':draft', 'my api key'] });
await client.next('view', mark);
mark = client.frames.length;
client.tell({ kind: 'event', event: [':submit'] });
const guarded = (await client.next('propose', mark)).value;
mark = client.frames.length;
client.tell({ kind: 'event', event: [':draft', 'something newer'] });
await client.next('view', mark);
const gr = await app.post(guarded);
assert.equal(gr.body.reason, 'looks-like-a-credential');
mark = client.frames.length;
client.tell({ kind: 'result', frame: gr.body });
view = await client.next('view', mark);
assert.equal(inputOf(view.value.tree).value, 'something newer');
ok('a refused intent never overwrites text typed after the submit');

await client.close();
await app.close();
console.log(`js-actors: SPLIT PASS (${passed} checks)`);
