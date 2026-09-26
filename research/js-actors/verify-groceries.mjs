// verify-groceries.mjs — the instant/offline shopping list, end to end.
//
// Drives apps/groceries.bl through the shared kit: one loopback authority and
// one child running the BL client half exactly as the Worker runs it. Proves
//
//   * the contract carries `aisle` as a closed `one-of` (a keyword on the wire),
//     and the codec decodes `dairy` to a keyword while refusing `garden`;
//   * placement: `predict-add` is the browser's, `predict-tick`/`predict-qty`
//     are shared (the server's `:apply` reuses them), `add-item` is the
//     authority's, and the client bundle holds neither it nor `initial-list`;
//   * HTTP: a tick commits once (its nonce is remembered), an add of an existing
//     name MERGES instead of adding a row, and a quantity below one is refused;
//   * the BL client's UX, the point of the track:
//       (a) INSTANT     — the very next view shows the edit before any answer;
//       (b) QUEUE ORDER — two edits, one proposal at a time, drained in order;
//       (c) SLIDES BACK — a rebase conflict drops the intent and shows the
//           confirmed state; a hand-crafted proposal shows a server refusal;
//       (d) DIVERGENCE  — the server merges where the browser predicted a row,
//           the server's board wins and the step is reported;
//       (e) OFFLINE     — edits are shown and queued with nothing sent, then
//           `online` drains the queue in order.

import assert from 'node:assert/strict';
import * as H from './host.mjs';
import { startApp, spawnClient, texts, findAll, attr, contractDigest, nonce, sleep, readOut } from './split-test-kit.mjs';
import { createCodec } from './split-codec.mjs';

let passed = 0;
const ok = (label) => { passed += 1; console.log('PASS groceries: ' + label); };

// Hand-crafted proposals come from fixed "tabs" distinct from the BL client's,
// so no nonce can collide with one the child proposes.
const HTTP_TAB = 'grocerieshttp001';
const OTHER_TAB = 'groceriesother01';

// ── the generated artifacts ─────────────────────────────────────────────────
const contract = JSON.parse(readOut('groceries.contract.json'));
const manifest = JSON.parse(readOut('groceries.split.json'));
const clientBundle = readOut('groceries-client.mjs');
const digest = contract.digest;

assert.equal(contractDigest(contract), digest);
assert.equal(manifest.digest, digest);
assert.equal(contract.snapshot, 'basket');
ok('contract digest is SHA-256 of its canonical body, shared by the manifest');

const where = Object.fromEntries(manifest.functions.map(f => [f.name, f.placement]));
assert.equal(where['predict-add'], 'client', 'the browser owns its add prediction');
assert.equal(where['predict-tick'], 'shared');
assert.equal(where['predict-qty'], 'shared');
assert.equal(where['add-item'], 'server');
assert.ok(where['predict-tick'] === 'shared' && where['predict-qty'] === 'shared',
           'the server :apply reuses the shared predictions');
assert.equal(clientBundle.includes('"js/add-item"'), false, 'the merge policy stays on the server');
assert.equal(clientBundle.includes('initial-list'), false, 'the initial list stays on the server');
ok('placement: predict-add client; predict-tick/qty shared and reused by :apply; add-item server');

// ── the contract: a closed aisle, decoded to a keyword ──────────────────────
assert.deepEqual(contract.wire.aisle, ['one-of', 'produce', 'bakery', 'dairy', 'pantry', 'other']);
const codec = createCodec(contract);
const decodeAdd = aisle => codec.decodeProposal({
  request: 1, revision: 0, digest, nonce: nonce(HTTP_TAB, 1), op: 'add-item', args: { name: 'Test', aisle },
});
const dairy = decodeAdd('dairy');
assert.equal(dairy.ok, true);
const decodedAisle = H.mapGet(H.mapGet(dairy.value, H.kw('args')), H.kw('aisle'));
assert.ok(H.isKw(decodedAisle), 'a one-of decodes to a keyword');
assert.equal(H.kwName(decodedAisle), 'dairy');
assert.equal(decodeAdd('garden').reason, 'malformed-args', 'an undeclared aisle is refused');
ok('a one-of aisle decodes to a keyword; an undeclared aisle is refused');

// ── the authority over HTTP ─────────────────────────────────────────────────
const app = await startApp('groceries');
assert.equal(app.codec.digest, digest);

await app.until(() => app.events.some(e => e.type === 'hello'), 'hello');
const hello = app.events.find(e => e.type === 'hello').data;
assert.equal(hello.revision, 0);
assert.equal(hello.board.items.length, 7);
ok('the authority serves the seven-item list at revision 0 over SSE');

let rev = hello.revision;
let hreq = 0;
// A hand-crafted proposal with a fresh, unique nonce.
const hp = (op, args, revision = rev) => {
  hreq += 1;
  return { request: hreq, revision, digest, nonce: nonce(HTTP_TAB, hreq), op, args };
};

const tick1 = hp('tick-item', { id: 1, got: true }, 0);
let r = await app.post(tick1);
assert.equal(r.status, 200);
assert.equal(r.body.ok, true);
assert.equal(r.body.revision, 1);
assert.equal(r.body.board.items.find(i => i.id === 1).got, true);
rev = r.body.revision;
ok('tick-item {id 1, got true} commits');

const dup = await app.post(tick1);
assert.equal(dup.body.ok, true);
assert.equal(dup.body.duplicate, true);
assert.equal(dup.body.revision, rev, 'a duplicate changes nothing');
assert.deepEqual(dup.body.board, r.body.board);
ok('the SAME nonce again is a duplicate: revision unchanged, the item still got once');

const idsBefore = r.body.board.items.map(i => i.id);
const bananasBefore = r.body.board.items.find(i => i.name === 'Bananas');
assert.equal(bananasBefore.qty, 6);
r = await app.post(hp('add-item', { name: 'Bananas', aisle: 'produce' }));
assert.equal(r.body.ok, true);
assert.equal(r.body.revision, 2);
const bananasAfter = r.body.board.items.find(i => i.name === 'Bananas');
assert.equal(bananasAfter.qty, 7, 'the existing row was raised');
assert.equal(bananasAfter.id, bananasBefore.id, 'the same row, not a new one');
assert.deepEqual(r.body.board.items.map(i => i.id), idsBefore, 'no row was added');
rev = r.body.revision;
ok('add-item of an existing name MERGES: qty +1, no new row');

r = await app.post(hp('change-qty', { id: 2, delta: -1 }));
assert.equal(r.status, 422);
assert.equal(r.body.reason, 'at-least-one');
ok('change-qty below one is refused with at-least-one');

// ── the BL client half, as the Worker runs it ───────────────────────────────
const client = spawnClient('groceries');
await client.next('ready', 0);
const now = await app.snapshotNow();
assert.equal(now.revision, rev);

let mark = client.frames.length;
client.tell({ kind: 'hello', ...now });
let view = await client.next('view', mark);
assert.ok(texts(view.value.tree).includes('Groceries'));
ok('the BL client renders the shared list');

// A view at or after `from` that satisfies `pred` (the actor may render more
// than one view per batch of events, so a bare "next view" is not enough).
const awaitView = async (pred, from, label) => {
  const start = Date.now();
  for (;;) {
    const hit = client.frames.slice(from).filter(f => f.topic === 'view' && pred(f.value)).at(-1);
    if (hit) return hit;
    if (Date.now() - start > 15000) throw new Error('timed out waiting for ' + label);
    await sleep(10);
  }
};
const sendEvent = (event, pred, label) => {
  const from = client.frames.length;
  client.tell({ kind: 'event', event });
  return awaitView(pred, from, label);
};

// Rows are the list items whose key is `i<id>` (a predicted new row is `i0<name>`).
const rowOf = (tree, id) =>
  findAll(tree, n => Array.isArray(n) && n[0] === 'li' && attr(n)?.key === 'i' + id)[0] ?? null;
const rowKey = (tree, key) =>
  findAll(tree, n => Array.isArray(n) && n[0] === 'li' && attr(n)?.key === key)[0] ?? null;
const tickOf = row => findAll(row, n => Array.isArray(n) && n[0] === 'button' && attr(n)?.class === 'tick')[0] ?? null;
const qtyOf = row => {
  const q = findAll(row, n => Array.isArray(n) && n[0] === 'span' && attr(n)?.class === 'qty')[0];
  const num = q && findAll(q, n => Array.isArray(n) && n[0] === 'span' && attr(n)?.class === 'n')[0];
  // `texts` also yields tag names, so pick the numeric text out of the span.
  const t = num && texts(num).find(s => /^[0-9]+$/.test(s));
  return t === undefined || t === null ? null : Number(t);
};
const syncText = tree => texts(
  findAll(tree, n => Array.isArray(n) && n[0] === 'div' && typeof attr(n)?.class === 'string' && attr(n).class.startsWith('sync'))[0] ?? []
).join('');

// ── (a) INSTANT ─────────────────────────────────────────────────────────────
mark = client.frames.length;
client.tell({ kind: 'event', event: [':tick', 3, true] });
view = await client.next('view', mark);
const bananaRow = rowOf(view.value.tree, 3);
assert.ok(bananaRow, 'the Bananas row is rendered');
assert.equal(attr(tickOf(bananaRow))['aria-pressed'], true, 'the very next view is already ticked');
assert.ok(texts(bananaRow).includes('saving'), 'and marked saving');
await sleep(40);
const firstProposes = client.frames.slice(mark).filter(f => f.topic === 'propose');
assert.equal(firstProposes.length, 1, 'exactly one proposal, before any answer');
assert.equal(firstProposes[0].value.op, 'tick-item');
assert.deepEqual(firstProposes[0].value.args, { id: 3, got: true });
ok('an edit lands instantly: the next view is ticked and saving, one propose');

r = await app.post(firstProposes[0].value);
assert.equal(r.body.ok, true);
rev = r.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
view = await awaitView(v => v.revision === r.body.revision, mark, 'the confirmed tick');
assert.equal(attr(tickOf(rowOf(view.value.tree, 3)))['aria-pressed'], true);
assert.equal(texts(rowOf(view.value.tree, 3)).includes('saving'), false, 'saving is cleared');
ok('the confirmed tick clears the saving state');

// ── (b) QUEUE ORDER ─────────────────────────────────────────────────────────
mark = client.frames.length;
client.tell({ kind: 'event', event: [':more', 3] });
client.tell({ kind: 'event', event: [':more', 3] });
view = await awaitView(v => qtyOf(rowOf(v.tree, 3)) === 9, mark, 'both predictions applied');
assert.equal(qtyOf(rowOf(view.value.tree, 3)), 9, 'the confirmed 7 plus both predictions');
await sleep(40);
const queued = client.frames.slice(mark).filter(f => f.topic === 'propose');
assert.equal(queued.length, 1, 'only the head is in flight');
assert.equal(queued[0].value.op, 'change-qty');
assert.deepEqual(queued[0].value.args, { id: 3, delta: 1 });
ok('two quick edits: the view shows +2 but only one propose is outstanding');

const q1 = queued[0].value;
r = await app.post(q1);
assert.equal(r.body.ok, true);
rev = r.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
const q2 = (await client.next('propose', mark)).value;
assert.equal(q2.op, 'change-qty');
assert.deepEqual(q2.args, { id: 3, delta: 1 });
view = await awaitView(v => qtyOf(rowOf(v.tree, 3)) === 9, mark, 'the second prediction');
ok('the first result triggers the second propose automatically');

r = await app.post(q2);
assert.equal(r.body.ok, true);
rev = r.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
view = await awaitView(v => v.revision === r.body.revision, mark, 'both edits settled');
assert.equal(qtyOf(rowOf(view.value.tree, 3)), 9);
assert.equal((await app.snapshotNow()).board.items.find(i => i.id === 3).qty, 9);
ok('both queued edits commit in order: the confirmed qty is +2');

// ── (c) REFUSAL SLIDES BACK ─────────────────────────────────────────────────
let on = 0;
const otherProposal = (op, args, revision) => {
  on += 1;
  return { request: 1000 + on, revision, digest, nonce: nonce(OTHER_TAB, on), op, args };
};

// A rebase conflict: another tab ticks the same item first, so the head goes
// stale; the re-check then finds it already done and drops the intent.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':tick', 6, true] });
const ct = (await client.next('propose', mark)).value;
assert.equal(ct.op, 'tick-item');
const otherTick = await app.post(otherProposal('tick-item', { id: 6, got: true }, ct.revision));
assert.equal(otherTick.body.ok, true);
rev = otherTick.body.revision;
const staleTick = await app.post(ct);
assert.equal(staleTick.body.reason, 'stale-revision');
mark = client.frames.length;
client.tell({ kind: 'result', frame: staleTick.body });
view = await awaitView(v => v.revision === staleTick.body.revision, mark, 'the confirmed tick after a rebase conflict');
assert.ok(client.frames.slice(mark).some(f => f.topic === 'trace' && f.value.step === 'rebase-refused'));
assert.equal(attr(tickOf(rowOf(view.value.tree, 6)))['aria-pressed'], true, 'the confirmed state shows');
assert.equal(texts(rowOf(view.value.tree, 6)).includes('saving'), false, 'the prediction slid back');
assert.ok(texts(view.value.tree).includes('someone already did that.'), 'the client-side reason shows');
assert.equal(findAll(view.value.tree, n => Array.isArray(n) && n[0] === 'p' && attr(n)?.class === 'note client').length, 1);
ok('a rebase conflict drops the intent: the row slides back to the confirmed state, note :client');

// A removal the other tab won: the same shape, reason no-such-item.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':remove', 7] });
const rm = (await client.next('propose', mark)).value;
assert.equal(rm.op, 'remove-item');
const otherRm = await app.post(otherProposal('remove-item', { id: 7 }, rm.revision));
assert.equal(otherRm.body.ok, true);
rev = otherRm.body.revision;
const staleRm = await app.post(rm);
assert.equal(staleRm.body.reason, 'stale-revision');
mark = client.frames.length;
client.tell({ kind: 'result', frame: staleRm.body });
view = await awaitView(v => v.revision === staleRm.body.revision, mark, 'the removed row after a rebase conflict');
assert.ok(client.frames.slice(mark).some(f => f.topic === 'trace' && f.value.step === 'rebase-refused'));
assert.equal(rowOf(view.value.tree, 7), null, 'the row is gone');
assert.ok(texts(view.value.tree).includes('that item is gone from the list.'), 'the client-side reason shows');
ok('a removal conflict drops the intent too: no-such-item, note :client');

// A direct server refusal, hand-crafted: nothing to subtract from one.
const cur = await app.snapshotNow();
r = await app.post(otherProposal('change-qty', { id: 6, delta: -1 }, cur.revision));
assert.equal(r.status, 422);
assert.equal(r.body.reason, 'at-least-one');
ok('a hand-crafted change-qty below one is refused with at-least-one');

// ── (d) DIVERGENCE ──────────────────────────────────────────────────────────
mark = client.frames.length;
client.tell({ kind: 'event', event: [':draft', 'Oat milk'] });
await awaitView(v => findAll(v.tree, n => Array.isArray(n) && n[0] === 'input' && attr(n)?.value === 'Oat milk').length >= 1,
                mark, 'the draft');
mark = client.frames.length;
client.tell({ kind: 'event', event: [':add'] });
view = await awaitView(v => rowKey(v.tree, 'i0Oat milk') !== null, mark, 'the predicted new row');
assert.equal(rowKey(view.value.tree, 'i0Oat milk') !== null, true, 'a provisional id-0 row');
assert.equal(rowOf(view.value.tree, 1) !== null, true, 'the confirmed row is still there');
assert.equal(qtyOf(rowOf(view.value.tree, 1)), 2, 'and untouched by the prediction');
const pd = (await client.next('propose', mark)).value;
assert.equal(pd.op, 'add-item');
assert.deepEqual(pd.args, { name: 'Oat milk', aisle: 'produce' });
ok('adding an existing name shows a provisional id-0 row at once');

r = await app.post(pd);
assert.equal(r.body.ok, true);
rev = r.body.revision;
assert.equal(r.body.board.items.find(i => i.id === 1).qty, 3, 'the server merged into the existing row');
assert.equal(r.body.board.items.some(i => i.id === 0), false);
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
view = await awaitView(v => v.revision === r.body.revision, mark, 'the divergence settled');
assert.ok(client.frames.slice(mark).some(f => f.topic === 'trace' && f.value.step === 'diverged'));
assert.ok(texts(view.value.tree).some(t => t.includes('adjusted')), 'the note reports the adjustment');
assert.equal(qtyOf(rowOf(view.value.tree, 1)), 3, 'the confirmed row wins');
assert.equal(rowKey(view.value.tree, 'i0Oat milk'), null, 'the provisional row is gone');
ok('a divergence is reported: the confirmed merge replaces the prediction, trace :diverged');

// ── (e) OFFLINE ─────────────────────────────────────────────────────────────
mark = client.frames.length;
client.tell({ kind: 'offline' });
view = await awaitView(v => syncText(v.tree).includes('Offline'), mark, 'the offline bar');
assert.ok(syncText(view.value.tree).includes('Offline'));

const vTick = await sendEvent([':tick', 4, true],
  v => attr(tickOf(rowOf(v.tree, 4)))['aria-pressed'] === true, 'tomatoes predicted ticked');
const vMore = await sendEvent([':more', 5],
  v => qtyOf(rowOf(v.tree, 5)) === 2, 'yogurt predicted +1');
await sendEvent([':draft', 'Limes'],
  v => findAll(v.tree, n => Array.isArray(n) && n[0] === 'input' && attr(n)?.value === 'Limes').length >= 1, 'the Limes draft');
const vAdd = await sendEvent([':add'],
  v => rowKey(v.tree, 'i0Limes') !== null, 'the Limes prediction');

await sleep(60);
assert.equal(client.frames.slice(mark).some(f => f.topic === 'propose'), false, 'offline: nothing is sent');
assert.equal(attr(tickOf(rowOf(vTick.value.tree, 4)))['aria-pressed'], true, 'the tick is shown');
assert.equal(qtyOf(rowOf(vMore.value.tree, 5)), 2, 'the quantity is shown');
assert.equal(rowKey(vAdd.value.tree, 'i0Limes') !== null, true, 'the new row is shown');
const barText = syncText(vAdd.value.tree);
assert.ok(barText.includes('Offline'), barText);
assert.ok(barText.includes('3 changes waiting'), barText);
ok('offline: three edits are shown and queued at once, and nothing is proposed');

mark = client.frames.length;
client.tell({ kind: 'online' });
const o1 = (await client.next('propose', mark)).value;
assert.equal(o1.op, 'tick-item');
assert.deepEqual(o1.args, { id: 4, got: true });
r = await app.post(o1);
assert.equal(r.body.ok, true);
rev = r.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
const o2 = (await client.next('propose', mark)).value;
assert.equal(o2.op, 'change-qty');
assert.deepEqual(o2.args, { id: 5, delta: 1 });
r = await app.post(o2);
assert.equal(r.body.ok, true);
rev = r.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
const o3 = (await client.next('propose', mark)).value;
assert.equal(o3.op, 'add-item');
assert.deepEqual(o3.args, { name: 'Limes', aisle: 'produce' });
r = await app.post(o3);
assert.equal(r.body.ok, true);
rev = r.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
view = await awaitView(v => v.revision === r.body.revision && !syncText(v.tree).includes('Offline'), mark, 'online settled');

const finalBoard = (await app.snapshotNow()).board;
assert.ok(finalBoard.items.some(i => i.name === 'Limes'), 'Limes committed');
assert.equal(finalBoard.items.find(i => i.id === 4).got, true, 'tomatoes ticked');
assert.equal(finalBoard.items.find(i => i.id === 5).qty, 2, 'yogurt qty 2');
ok('online drains the queue in order; all three edits commit and the list is saved');

// A NEW name was predicted right: only its id was the server's to choose, and
// the app's :agrees? (same-but-ids?) says that is no divergence.
assert.equal(client.frames.slice(mark).some(f => f.topic === 'trace' && f.value.step === 'diverged'), false,
             'adding a new item is not reported as a divergence');
assert.equal(rowKey(view.tree, 'i0Limes'), null, 'the provisional id-0 row is gone');
ok('a correct prediction of a new row is confirmed quietly; the server-numbered row replaces it');

await client.close();
await app.close();
console.log(`js-actors: GROCERIES PASS (${passed} checks)`);
