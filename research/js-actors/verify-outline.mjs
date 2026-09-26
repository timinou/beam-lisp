// verify-outline.mjs — the nested-plan split app, end to end, without a browser.
//
// Proves on the GENERATED artifacts (run the source build first):
//   * the contract's `item` type recurses through `kids`, and the digest is the
//     SHA-256 of its canonical body, shared by the manifest;
//   * the manifest places every tree walk in the right half and carries the
//     structural-descent proof for each recursive function;
//   * the client bundle holds none of the server-only rebuilders or the plan;
//   * the codec bounds recursion (25 containers refused, a legal plan accepted)
//     and refuses a widened record;
//   * the BL authority commits adds, refuses bad parents and over-deep adds,
//     flips a whole subtree, removes a phase with its children and fans every
//     commit out over SSE;
//   * the BL client half (run in a child process, as the Worker runs it)
//     renders, tallies, folds, searches, proposes and adopts a result.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createCodec, MAX_DEPTH } from './split-codec.mjs';
import { startApp, spawnClient, texts, findAll, attr, canonical, contractDigest, readOut } from './split-test-kit.mjs';

let passed = 0;
const ok = (label) => { passed += 1; console.log('PASS outline: ' + label); };

// ── board and view-tree walkers ─────────────────────────────────────────────

const findItem = (items, id) => {
  for (const it of items) {
    if (it.id === id) return it;
    const hit = findItem(it.kids, id);
    if (hit) return hit;
  }
  return null;
};
const allIds = (items, acc = []) => { for (const it of items) { acc.push(it.id); allIds(it.kids, acc); } return acc; };
const kidIds = (items, id) => { const it = findItem(items, id); return it ? it.kids.map(k => k.id) : []; };
const subtreeIds = (items, id) => { const it = findItem(items, id); return it ? allIds([it]) : []; };
const depthOf = (items, id, d = 1) => {
  for (const it of items) {
    if (it.id === id) return d;
    const hit = depthOf(it.kids, id, d + 1);
    if (hit) return hit;
  }
  return 0;
};
const leaves = (items, acc = []) => {
  for (const it of items) { if (it.kids.length === 0) acc.push(it); else leaves(it.kids, acc); }
  return acc;
};
const rowNode = (tree, id) =>
  findAll(tree, n => Array.isArray(n) && n[0] === 'li' && attr(n) && attr(n).key === 'i' + id)[0] ?? null;
// A row's nested children carry the `mapv` result as one vector element and the
// optional add row as the next (BL view data nests both), so flatten one level.
const rowKeys = (row) => {
  const ul = row.find(c => Array.isArray(c) && c[0] === 'ul');
  if (!ul) return [];
  return ul.slice(2)
    .flatMap(c => (Array.isArray(c) && Array.isArray(c[0]) ? c : [c]))
    .filter(n => Array.isArray(n) && n[0] === 'li')
    .map(n => attr(n).key);
};

let app = null;
let client = null;
let failed = false;

try {
  // ── the generated artifacts ───────────────────────────────────────────────
  const contract = JSON.parse(readOut('outline.contract.json'));
  const manifest = JSON.parse(readOut('outline.split.json'));
  const clientBundle = readOut('outline-client.mjs');
  const serverBundle = readOut('outline-server.mjs');

  const digest = contract.digest;
  assert.equal(contractDigest(contract), digest, 'digest is the SHA-256 of the canonical contract body');
  assert.equal(contract.schema, 1);
  assert.equal(contract.snapshot, 'plan');
  assert.equal(contract.wire.item[0], 'record');
  assert.deepEqual(contract.wire.item[1].kids, ['list', 16, 'item'], 'item.kids is a bounded list of item');
  assert.deepEqual(contract.wire.plan[1].items, ['list', 16, 'item']);
  assert.equal(manifest.digest, digest, 'manifest and contract agree on the digest');
  ok('the contract names a recursive `item` through a bounded `kids` list, digest = SHA-256 of its canonical body');

  const where = Object.fromEntries(manifest.functions.map(f => [f.name, f.placement]));
  const fn = name => manifest.functions.find(f => f.name === name);
  for (const n of ['plan-view', 'item-row', 'tally', 'prune']) assert.equal(where[n], 'client', n + ' belongs in the browser');
  for (const n of ['find-item', 'depth-of', 'add-problem']) assert.equal(where[n], 'shared', n + ' is shared');
  for (const n of ['toggle-in', 'add-in', 'remove-in', 'set-done']) assert.equal(where[n], 'server', n + ' belongs to the authority');
  ok('the manifest places every tree walk in its half: view/roll-up browser, checks shared, rebuild authority');

  for (const n of ['item-row', 'tally', 'prune', 'find-item'])
    assert.equal(fn(n).evidence.recursion, 'structural', n + ' terminates by structural descent');
  ok('each recursive walk is admitted by a structural-descent proof');

  for (const needle of ['"js/toggle-in"', '"js/add-in"', '"js/remove-in"', '"js/set-done"', 'initial-plan'])
    assert.equal(clientBundle.includes(needle), false, 'client bundle leaks ' + needle);
  assert.ok(serverBundle.includes('"js/toggle-in"') && serverBundle.includes('initial-plan'));
  ok('the server-only rebuilders and the initial plan stay out of the client bundle');

  // ── the codec ─────────────────────────────────────────────────────────────
  const codec = createCodec(contract);
  const bare = (id, kids = []) => ({ id, text: 'x', done: false, kids });
  const chain = (n) => { let node = bare(n); for (let i = n - 1; i >= 1; i -= 1) node = bare(i, [node]); return { items: [node] }; };
  assert.doesNotThrow(() => codec.decodeSnapshot(chain(2)), 'a legal five-level plan is accepted');
  assert.throws(() => codec.decodeSnapshot(chain(12)), /nested deeper than 24/);
  assert.throws(() => codec.decodeSnapshot({ items: [{ ...bare(1), extra: 1 }] }), /record keys/);
  ok('the codec accepts a legal five-level plan, refuses 25 containers and a widened record');

  // one depth bound, three places: the build, the BL authority, the codec
  const bound = file => Number(/\(defn wire-max-depth[\s\S]*?\[\] (\d+)\)/.exec(readFileSync(new URL(file, import.meta.url), 'utf8'))[1]);
  assert.equal(bound('./compiler.bl'), MAX_DEPTH);
  assert.equal(bound('./split-wire.bl'), MAX_DEPTH);
  ok(`the wire depth bound (${MAX_DEPTH}) is the same in compiler.bl, split-wire.bl and the codec`);

  // ── the authority over HTTP ───────────────────────────────────────────────
  app = await startApp('outline');
  assert.equal(app.codec.digest, digest);
  await app.until(() => app.events.some(e => e.type === 'hello'), 'hello');
  const hello = app.events.find(e => e.type === 'hello').data;
  assert.equal(hello.revision, 0);
  assert.equal(hello.board.items.length, 3);
  assert.deepEqual(hello.board.items.map(i => i.id), [1, 7, 14]);
  ok('the authority serves the three-phase plan at revision 0 over SSE');

  let rev = hello.revision;
  let board = hello.board;
  let req = 0;
  const intent = async (op, args) => {
    req += 1;
    const r = await app.post({ request: req, revision: rev, digest, op, args });
    if (r.body && r.body.ok) { rev = r.body.revision; board = r.body.board; }
    return r;
  };

  let r = await intent('add-item', { parent: 8, text: 'Rate limits' });
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
  const at18 = findItem(r.body.board.items, 18);
  assert.ok(at18 && at18.text === 'Rate limits', 'the new item is id 18');
  assert.ok(kidIds(r.body.board.items, 8).includes(18), 'and it sits under Sign-up flow');
  ok('add-item under Sign-up flow commits with the server-assigned id 18');

  await app.until(() => app.events.some(e => e.type === 'snapshot' && e.data.revision === 1), 'snapshot 1');
  ok('the commit is fanned out over SSE as a snapshot');

  r = await intent('add-item', { parent: 999, text: 'Orphan' });
  assert.equal(r.status, 422);
  assert.equal(r.body.reason, 'no-such-item');
  ok('add-item under a nonexistent parent is refused with no-such-item');

  // ── the BL client half, as the Worker runs it ─────────────────────────────
  client = spawnClient('outline');
  await client.next('ready', 0);
  const now = await app.snapshotNow();
  assert.equal(now.revision, rev);
  let mark = client.frames.length;
  client.tell({ kind: 'hello', ...now });
  let view = await client.next('view', mark);
  assert.equal(view.value.revision, now.revision);
  assert.ok(texts(view.value.tree).includes('Product launch'));
  ok('the BL client renders the confirmed plan');

  const boardLeaves = leaves(now.board.items);
  const doneLeaves = boardLeaves.filter(it => it.done).length;
  const sub = texts(view.value.tree).find(t => /steps done/.test(t));
  const progress = /(\d+) of (\d+) steps done/.exec(sub);
  assert.ok(progress, 'the header shows a progress line');
  assert.equal(Number(progress[1]), doneLeaves);
  assert.equal(Number(progress[2]), boardLeaves.length);
  ok(`the progress line (${doneLeaves} of ${boardLeaves.length}) matches a JS tally over the leaves`);

  mark = client.frames.length;
  client.tell({ kind: 'event', event: [':fold', 7] });
  view = await client.next('view', mark);
  assert.equal(texts(view.value.tree).includes('Billing page'), false, 'Build’s children are hidden');
  assert.equal(texts(view.value.tree).includes('Sign-up flow'), false);
  assert.equal(client.frames.slice(mark).some(f => f.topic === 'propose'), false);
  ok(':fold hides a phase’s children in the browser, with no proposal');

  mark = client.frames.length;
  client.tell({ kind: 'event', event: [':unfold-all'] });
  view = await client.next('view', mark);
  assert.ok(texts(view.value.tree).includes('Billing page'), 'expand all restores the children');

  mark = client.frames.length;
  client.tell({ kind: 'event', event: [':query', 'magic'] });
  view = await client.next('view', mark);
  const searchTexts = texts(view.value.tree);
  assert.ok(searchTexts.includes('Build') && searchTexts.includes('Sign-up flow'), 'ancestors are kept');
  assert.ok(rowNode(view.value.tree, 10), 'the matching row is kept');
  assert.equal(rowNode(view.value.tree, 9), null, 'a non-matching sibling step is pruned');
  assert.equal(rowNode(view.value.tree, 11), null, 'a non-matching sibling step is pruned');
  assert.equal(searchTexts.includes('Billing page'), false, 'a sibling is pruned');
  assert.equal(searchTexts.includes('Usage dashboard'), false, 'a sibling is pruned');
  assert.equal(searchTexts.includes('Research'), false, 'another phase is pruned');
  assert.equal(searchTexts.includes('Launch'), false, 'another phase is pruned');
  const marked = findAll(view.value.tree, n => Array.isArray(n) && n[0] === 'em');
  assert.equal(marked.length, 1);
  assert.ok(texts(marked[0]).includes('Magic'));
  ok('a search keeps only matching branches and their ancestors, wrapping the match in <em>');

  mark = client.frames.length;
  client.tell({ kind: 'event', event: [':query', 'zzz-nope'] });
  view = await client.next('view', mark);
  assert.ok(texts(view.value.tree).some(s => s.startsWith('Nothing matches')));
  ok('a search with no match says Nothing matches');

  mark = client.frames.length;
  client.tell({ kind: 'event', event: [':query', ''] });
  view = await client.next('view', mark);
  assert.ok(texts(view.value.tree).includes('Billing page'), 'clearing the search restores the tree');

  mark = client.frames.length;
  client.tell({ kind: 'event', event: [':open-add', 8] });
  view = await client.next('view', mark);
  assert.ok(rowKeys(rowNode(view.value.tree, 8)).includes('adding'), 'the add row opens inside Sign-up flow');

  mark = client.frames.length;
  client.tell({ kind: 'event', event: [':draft', 'Rate limits'] });
  view = await client.next('view', mark);
  assert.ok(findAll(view.value.tree, n => Array.isArray(n) && n[0] === 'input' && attr(n).value === 'Rate limits').length >= 1);

  mark = client.frames.length;
  client.tell({ kind: 'event', event: [':submit'] });
  const proposal = (await client.next('propose', mark)).value;
  assert.equal(proposal.op, 'add-item');
  assert.deepEqual(proposal.args, { parent: 8, text: 'Rate limits' });
  ok(':submit proposes add-item under the open row');

  const res = await app.post(proposal);
  assert.equal(res.body.ok, true);
  rev = res.body.revision;
  board = res.body.board;
  const fresh = kidIds(res.body.board.items, 8).find(id => !kidIds(now.board.items, 8).includes(id));
  assert.ok(fresh, 'the server assigned a new child id under Sign-up flow');
  mark = client.frames.length;
  client.tell({ kind: 'result', frame: res.body });
  view = await client.next('view', mark);
  const freshRow = rowNode(view.value.tree, fresh);
  assert.ok(freshRow && texts(freshRow).includes('Rate limits'));
  assert.ok(rowKeys(rowNode(view.value.tree, 8)).includes('i' + fresh));
  ok('the confirmed result adds the row under Sign-up flow');

  mark = client.frames.length;
  client.tell({ kind: 'event', event: [':toggle', 4] });
  const toggled = (await client.next('propose', mark)).value;
  assert.equal(toggled.op, 'toggle-item');
  assert.deepEqual(toggled.args, { id: 4 });
  ok(':toggle proposes a server-authoritative toggle-item');

  // ── the authority, destructive last (the client needed Build intact) ──────
  let parent = 17;                                   // Tell the beta list, depth 2
  for (let i = 0; i < 3; i += 1) {
    const before = new Set(allIds(board.items));
    r = await intent('add-item', { parent, text: 'step' });
    assert.equal(r.body.ok, true, 'chain add ' + (i + 1));
    parent = allIds(r.body.board.items).find(id => !before.has(id));
  }
  assert.equal(depthOf(board.items, parent), 5, 'the chain reaches depth 5');
  r = await intent('add-item', { parent, text: 'one too many' });
  assert.equal(r.status, 422);
  assert.equal(r.body.reason, 'too-deep');
  ok('add-item refuses a child of a fifth-level item with too-deep');

  const research = subtreeIds(board.items, 1);
  r = await intent('toggle-item', { id: 1 });
  assert.equal(r.body.ok, true);
  for (const id of research) assert.equal(findItem(r.body.board.items, id).done, true, 'id ' + id + ' done');
  r = await intent('toggle-item', { id: 1 });
  for (const id of research) assert.equal(findItem(r.body.board.items, id).done, false, 'id ' + id + ' open');
  ok('toggle-item flips a whole phase’s subtree on, then off');

  const idsBefore = allIds(board.items).length;
  const before7 = subtreeIds(board.items, 7);
  r = await intent('remove-item', { id: 7 });
  assert.equal(r.body.ok, true);
  assert.equal(findItem(r.body.board.items, 7), null, 'Build is gone');
  assert.equal(allIds(r.body.board.items).length, idsBefore - before7.length);
  ok('remove-item drops a phase and its whole subtree');

  await app.until(() => app.events.some(e => e.type === 'snapshot' && e.data.revision === rev), 'snapshot ' + rev);
  const last = app.events.filter(e => e.type === 'snapshot').at(-1);
  assert.equal(allIds(last.data.board.items).length, allIds(board.items).length);
  ok('every commit is fanned out over SSE as a snapshot');
} catch (error) {
  failed = true;
  console.error('FAIL outline: ' + (error && error.message ? error.message : String(error)));
  if (error && error.actual !== undefined) console.error('  expected: ' + JSON.stringify(error.expected) + '\n  actual:   ' + JSON.stringify(error.actual));
} finally {
  try { if (client) await client.close(); } catch { /* ignore */ }
  try { if (app) await app.close(); } catch { /* ignore */ }
}

if (failed) {
  console.error('js-actors: OUTLINE FAIL');
  process.exit(1);
}
console.log(`js-actors: OUTLINE PASS (${passed} checks)`);
