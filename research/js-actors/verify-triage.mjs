// verify-triage.mjs — the keyboard-first bug inbox, end to end.
//
// Drives apps/triage.bl through the shared kit: one loopback authority and one
// child running the BL client half exactly as the Worker runs it. Proves
//
//   * placement: the view/reducer/checks/prediction split (inbox-view,
//     report-row, on-event, step-sel, parse-id are the browser's;
//     move-before and index-of-id are shared; the seed inbox is the server's);
//   * `move-before` over HTTP — the exact documented cut, up and down, and the
//     two refusals (same-place, no-such-report);
//   * the BL client's interaction grammar: the `:keys` map each view declares,
//     selection, the inline editor (autofocus, keys emptied), the draft/save
//     rename, cancel, a predicted drag-reorder, and the local refusal of a
//     malformed drag id (id 0 fails the wire's int 1..9999);
//   * an event the view never offered is a no-op in the BL reducer;
//   * the page's value-echo guard, modelled purely (the page is browser-only)
//     with a source check so the model cannot drift.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { startApp, spawnClient, texts, findAll, attr, contractDigest, nonce, sleep, readOut, HERE } from './split-test-kit.mjs';

let passed = 0;
const ok = (label) => { passed += 1; console.log('PASS triage: ' + label); };

// Hand-crafted proposals come from a fixed "tab" distinct from the BL client's,
// so no nonce can collide with one the child proposes.
const HTTP_TAB = 'triagehttp000001';

// ── the generated artifacts ─────────────────────────────────────────────────
const contract = JSON.parse(readOut('triage.contract.json'));
const manifest = JSON.parse(readOut('triage.split.json'));
const clientBundle = readOut('triage-client.mjs');
const digest = contract.digest;

assert.equal(contractDigest(contract), digest);
assert.equal(manifest.digest, digest);
assert.equal(contract.snapshot, 'inbox');
ok('contract digest is SHA-256 of its canonical body, shared by the manifest');

// ── 1. placement ────────────────────────────────────────────────────────────
const where = Object.fromEntries(manifest.functions.map(f => [f.name, f.placement]));
for (const name of ['inbox-view', 'report-row', 'on-event', 'step-sel', 'parse-id'])
  assert.equal(where[name], 'client', name + ' is the browser\'s');
for (const name of ['move-before', 'index-of-id'])
  assert.equal(where[name], 'shared', name + ' is shared');
assert.equal(where['initial-inbox'], 'server', 'the seed inbox is the authority\'s');
assert.ok(clientBundle.includes('"js/on-event"') && clientBundle.includes('"js/step-sel"') &&
          clientBundle.includes('"js/report-row"'), 'the client half carries the UX');
assert.equal(clientBundle.includes('"js/initial-inbox"'), false, 'the seed stays on the server');
assert.equal(manifest.functions.find(f => f.name === 'initial-inbox').placement, 'server', 'the server owns the seed');
assert.ok(clientBundle.includes('"js/move-before"') && manifest.functions.find(f => f.name === 'move-before').placement === 'shared',
          'move-before is shared, so the prediction and the :apply are one function');
ok('placement: inbox-view/report-row/on-event/step-sel/parse-id client; move-before/index-of-id shared; initial-inbox server');

// ── the authority ───────────────────────────────────────────────────────────
const app = await startApp('triage');
assert.equal(app.codec.digest, digest);
await app.until(() => app.events.some(e => e.type === 'hello'), 'hello');
const hello0 = app.events.find(e => e.type === 'hello').data;
assert.equal(hello0.revision, 0);
assert.deepEqual(hello0.board.reports.map(r => r.id), [1, 2, 3, 4, 5, 6, 7]);
ok('the authority serves the seven-report inbox at revision 0 over SSE');

// ── 3. the BL client half, as the Worker runs it ────────────────────────────
const client = spawnClient('triage');
await client.next('ready', 0);
const now = await app.snapshotNow();
let mark = client.frames.length;
client.tell({ kind: 'hello', ...now });
let view = await client.next('view', mark);
assert.ok(texts(view.value.tree).includes('Bug inbox'));
ok('the BL client renders the shared inbox');

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
const section = tree =>
  findAll(tree, n => Array.isArray(n) && n[0] === 'section' && attr(n)?.class === 'triage')[0] ?? null;
const keysOf = tree => { const s = section(tree); return s ? attr(s).keys : null; };
const rowOf = (tree, id) =>
  findAll(tree, n => Array.isArray(n) && n[0] === 'li' && attr(n)?.key === 'r' + id)[0] ?? null;
const rows = tree =>
  findAll(tree, n => Array.isArray(n) && n[0] === 'li' && typeof attr(n)?.key === 'string' && attr(n).key.startsWith('r'));
const inputOf = (tree, autofocus) => findAll(tree, n => Array.isArray(n) && n[0] === 'input' &&
  (autofocus === undefined || attr(n)?.autofocus === autofocus))[0] ?? null;

// The view's `:keys` map is what the page turns into key handlers. The kit
// encodes with split-codec `encode` (keywords → bare names), so a handler like
// `[:sel 2]` arrives as `['sel', 2]` — the shape asserted below.
const keys = keysOf(view.value.tree);
const WANT_KEYS = ['j', 'k', 'ArrowDown', 'ArrowUp', '?', 'h', 'x', 'e', 'Enter', 'p'];
assert.ok(keys && typeof keys === 'object', 'the root section carries a keys map');
assert.deepEqual(Object.keys(keys).sort(), [...WANT_KEYS].sort());
for (const k of WANT_KEYS) assert.ok(Array.isArray(keys[k]) && keys[k].length >= 1, k + ' is a handler vector');
assert.deepEqual(keys.j, ['sel', 2], 'j is the +1 selection step from the initial sel (id 1)');
assert.deepEqual(keys['?'], ['help']);
assert.deepEqual(keys.h, ['hide-fixed']);
assert.equal(keys.x[0], 'fix');
assert.equal(keys.e[0], 'edit');
assert.equal(keys.Enter[0], 'edit');
assert.equal(keys.p[0], 'prio');
ok('the view declares j/k/arrows/?,h,x,e,Enter,p as handler vectors (encoded as bare names)');

// `:sel` via the j handler.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':' + keys.j[0], ...keys.j.slice(1)] });
view = await awaitView(v => { const r = rowOf(v.tree, 2); return r !== null && String(attr(r).class).includes('sel'); },
                       mark, 'the selection on row 2');
assert.ok(String(attr(rowOf(view.value.tree, 2)).class).includes('sel'));
assert.equal(attr(rowOf(view.value.tree, 2)).focused, true);
assert.equal(String(attr(rowOf(view.value.tree, 1)).class).includes('sel'), false);
assert.equal(attr(rowOf(view.value.tree, 1)).focused, false);
ok(':sel moves the selection: row 2 takes class sel and focused true, row 1 does not');

// `:edit id title` — an autofocused input, and the keys map empties.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':edit', 1, 'Crash when pasting an image into a comment'] });
view = await awaitView(v => inputOf(v.tree, true) !== null, mark, 'the inline editor');
const editor = inputOf(view.value.tree, true);
assert.equal(attr(editor).value, 'Crash when pasting an image into a comment');
assert.equal(Object.keys(keysOf(view.value.tree)).length, 0, 'the keys belong to the text field now');
ok(':edit renders an autofocused input and empties the keys map while editing');

// `:draft` + `:save` proposes the rename.
const TITLE = 'Renamed by the client';
await sendEvent([':draft', TITLE], v => { const i = inputOf(v.tree); return i !== null && attr(i).value === TITLE; },
                'the draft');
mark = client.frames.length;
client.tell({ kind: 'event', event: [':save'] });
const rename = await client.next('propose', mark);
assert.equal(rename.value.op, 'rename-report');
assert.deepEqual(rename.value.args, { id: 1, title: TITLE });
ok(':draft then :save proposes rename-report with the draft');

let r = await app.post(rename.value);
assert.equal(r.status, 200);
assert.equal(r.body.ok, true);
let rev = r.body.revision;
mark = client.frames.length;
client.tell({ kind: 'result', frame: r.body });
await awaitView(v => v.revision === rev && texts(v.tree).includes(TITLE), mark, 'the confirmed rename');
ok('the rename commits and the confirmed title renders');

// `:cancel` proposes nothing and closes the editor.
await sendEvent([':edit', 2, 'Dark mode: the date picker is unreadable'],
                v => inputOf(v.tree, true) !== null, 'the second editor');
mark = client.frames.length;
client.tell({ kind: 'event', event: [':cancel'] });
view = await awaitView(v => inputOf(v.tree) === null, mark, 'the editor closed');
assert.equal(client.frames.slice(mark).some(f => f.topic === 'propose'), false, ':cancel proposes nothing');
ok(':cancel proposes nothing and removes the input');

// `:drop '7' '1'` — propose, and the very next view already predicts r7 first.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':drop', '7', '1'] });
const drop = await client.next('propose', mark);
assert.equal(drop.value.op, 'move-report');
assert.deepEqual(drop.value.args, { id: 7, before: 1 });
view = await awaitView(v => { const rs = rows(v.tree); return rs.length > 0 && attr(rs[0]).key === 'r7'; },
                       mark, 'the predicted reorder');
assert.equal(attr(rows(view.value.tree)[0]).key, 'r7', 'the dragged row is first before any answer');
ok(":drop '7' '1' proposes move-report {id 7, before 1} and the next view already has row r7 first");

// `:drop 'abc' '1'` — parse-id 'abc' is 0, which fails the wire's int 1..9999.
mark = client.frames.length;
client.tell({ kind: 'event', event: [':drop', 'abc', '1'] });
view = await awaitView(v => findAll(v.tree, n => Array.isArray(n) && n[0] === 'p' &&
                       attr(n)?.class === 'note client').length === 1, mark, 'the malformed-args note');
assert.equal(client.frames.slice(mark).some(f => f.topic === 'propose'), false, 'id 0 never reaches the wire');
assert.ok(texts(view.value.tree).includes('malformed-args'), 'the client note names malformed-args');
ok(":drop 'abc' '1' parses to id 0, fails the wire's int 1..9999, and is refused locally with a :client note");

// ── 4. an event the view never offered is ignored by the BL reducer ─────────
// (The Worker's own offered-set refusal is covered by verify-split; here we
// show the app-level fallback: `on-event`'s `:else` keeps the local state.)
const lastTree = JSON.stringify(client.frames.filter(f => f.topic === 'view').at(-1).value.tree);
mark = client.frames.length;
client.tell({ kind: 'event', event: [':bogus'] });
// the reducer answers with a view (its `:else` keeps the local state)
await client.next('view', mark);
assert.equal(client.frames.slice(mark).some(f => f.topic === 'propose'), false, 'an unhandled kind proposes nothing');
const strayViews = client.frames.slice(mark).filter(f => f.topic === 'view');
assert.ok(strayViews.length >= 1, 'the reducer still renders');
assert.ok(strayViews.every(f => JSON.stringify(f.value.tree) === lastTree),
          'and the view it renders is byte-identical (local unchanged)');
assert.ok(clientBundle.includes('"js/on-event"'), 'the reducer the fallback lives in is in the client bundle');
ok('an event the view never offered is ignored by on-event: no propose, local unchanged');

await client.close();

// ── 2. `move-before` semantics over HTTP ────────────────────────────────────
// The board is still ordered [1..7] here: the client above only renamed a
// title, and its drag prediction was never posted.
let hreq = 0;
const hp = (op, args, revision = rev) => {
  hreq += 1;
  return { request: hreq, revision, digest, nonce: nonce(HTTP_TAB, hreq), op, args };
};
const ids = board => board.reports.map(x => x.id);

assert.deepEqual((await app.snapshotNow()).board.reports.map(x => x.id), [1, 2, 3, 4, 5, 6, 7]);

r = await app.post(hp('move-report', { id: 7, before: 1 }));
assert.equal(r.status, 200);
assert.equal(r.body.ok, true);
assert.deepEqual(ids(r.body.board), [7, 1, 2, 3, 4, 5, 6]);
rev = r.body.revision;
ok('move-before {id 7, before 1} (dragged up) puts 7 first: [7,1,2,3,4,5,6]');

r = await app.post(hp('move-report', { id: 1, before: 5 }));
assert.equal(r.status, 200);
assert.deepEqual(ids(r.body.board), [7, 2, 3, 4, 5, 1, 6], 'from<to inserts AFTER the target');
rev = r.body.revision;
ok('move-before {id 1, before 5} (dragged down, from<to) inserts AFTER: 1 lands just after 5');

r = await app.post(hp('move-report', { id: 3, before: 3 }));
assert.equal(r.status, 422);
assert.equal(r.body.reason, 'same-place');
ok('move-before onto itself is refused with same-place');

r = await app.post(hp('move-report', { id: 99, before: 1 }));
assert.equal(r.status, 422);
assert.equal(r.body.reason, 'no-such-report');
r = await app.post(hp('move-report', { id: 1, before: 99 }));
assert.equal(r.status, 422);
assert.equal(r.body.reason, 'no-such-report');
ok('an unknown report id (either end) is refused with no-such-report');

await app.close();

// ── 5. the page's value-echo guard, as a pure model ─────────────────────────
// The page is browser-only, so this is a copy of the guard in
// showcase-page.mjs patch(): the `value` branch
//   const i = sent ? sent.lastIndexOf(want) : -1;
//   if (i >= 0 && document.activeElement === el) { sent.splice(0, i + 1); continue; }
//   if (sent) sent.length = 0;
//   if (el.value !== want) el.value = want;
// and the source check right after keeps the model honest.
const showcasePage = readFileSync(new URL('showcase-page.mjs', HERE), 'utf8');
assert.ok(showcasePage.includes('sent.lastIndexOf(want)'), 'showcase-page.mjs still holds the echo guard');

function applyViewValue(slot, want, focused, field) {
  const sent = slot.sent;
  const i = sent ? sent.lastIndexOf(want) : -1;
  if (i >= 0 && focused) { sent.splice(0, i + 1); return; } // echo: drop it and every older one
  if (sent) sent.length = 0;
  if (field.value !== want) field.value = want;
}

const field = { value: 'abc' };
const slot = { sent: ['a', 'ab', 'abc'] };
applyViewValue(slot, 'ab', true, field);
assert.equal(field.value, 'abc', 'an echo of an older value is dropped while the field is focused');
assert.deepEqual(slot.sent, ['abc'], 'and every value up to and including it is forgotten');
applyViewValue(slot, '', true, field);
assert.equal(field.value, '', 'a value the view never sent (cleared) is applied');
assert.deepEqual(slot.sent, []);
ok('the page echo guard model: a focused echo is dropped, a cleared value applies (source still holds it)');

console.log(`js-actors: TRIAGE PASS (${passed} checks)`);
