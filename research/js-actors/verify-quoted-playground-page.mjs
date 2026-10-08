// Deterministic page-state test: delayed HTTP success cannot update the view;
// only the subsequent BL Worker frame can. Real browser behavior is checked
// separately with a module Worker and the loopback server.
import assert from 'node:assert/strict';
import { fenceQuotedForm } from './quoted-form.mjs';

const source = '[:card {:id "inbox"} [:heading {:level 2 :text "Inbox"}] [:field :unread] [:button {:label "Mark all read" :intent [:intent :increment]}] [:text "local"]]';
const manifest = fenceQuotedForm(source).manifest;
const nodes = new Map();
for (const id of ['source', 'run', 'intent', 'verdict', 'diagnostic', 'title', 'field', 'copy',
  'render', 'view-contract', 'field-contract', 'intent-contract'])
  nodes.set('#' + id, { value: id === 'source' ? source : '', textContent: '', disabled: false,
    dataset: {}, handlers: {}, addEventListener(type, fn) { this.handlers[type] = fn; } });
globalThis.document = { querySelector: id => nodes.get(id) };
globalThis.window = {};
let worker;
globalThis.Worker = class {
  constructor() { this.sent = []; worker = this; }
  postMessage(data) { this.sent.push(data); }
  emit(data) { this.onmessage({ data }); }
};
const calls = [];
let reply;
globalThis.fetch = (url, options) => {
  calls.push({ url, options });
  if (url === '/api/contract') return Promise.resolve({ ok: true, json: async () =>
    ({ schema: 1, op: 'increment', field: 'unread', versionChars: 16, payloadChars: 16 }) });
  if (url === '/api/intent') return new Promise(resolve => { reply = resolve; });
  throw new Error('unexpected network path: ' + url);
};
const tick = () => new Promise(resolve => setTimeout(resolve, 0));
const view = version => ({ card: { id: 'inbox' }, heading: { level: 2, text: 'Inbox' },
  field: { name: 'unread', value: version }, button: { label: 'Mark all read', intent: 'increment' }, text: 'local' });
await import('./quoted-playground-page.mjs');
const demo = window.quotedPlayground;
worker.emit({ kind: 'ready' });
assert.equal(worker.sent[0].kind, 'run');
worker.emit({ kind: 'eligible', manifest });
worker.emit({ kind: 'view', view: view('7') });
await tick();
assert.equal(nodes.get('#intent').disabled, false);
assert.equal(nodes.get('#field').textContent, 'unread: 7');
assert.deepEqual(calls.map(c => c.url), ['/api/contract'], 'Run never POSTs the form');
console.log('PASS pure JS Run renders with no intent POST');

const pending = demo.request();
assert.equal(nodes.get('#intent').disabled, true);
assert.equal(nodes.get('#field').textContent, 'unread: 7', 'no optimistic render while HTTP pending');
assert.deepEqual(JSON.parse(calls.at(-1).options.body), { op: 'increment', version: '7' });
reply({ status: 200, json: async () => ({ ok: true, intent: 'increment', version: 8 }) });
assert.deepEqual(await pending, { ok: true, version: '8' });
assert.equal(nodes.get('#field').textContent, 'unread: 7', 'HTTP success alone cannot mutate the view');
assert.deepEqual(worker.sent.at(-1), { kind: 'server-version', version: '8' });
worker.emit({ kind: 'view', view: view('8') });
assert.equal(nodes.get('#field').textContent, 'unread: 8');
assert.equal(nodes.get('#intent').disabled, false);
console.log('PASS server success waits for compiled BL frame, then advances once');

const stale = demo.request('increment', '7');
reply({ status: 409, json: async () => ({ ok: false, reason: 'stale-version' }) });
assert.deepEqual(await stale, { ok: false, reason: 'stale-version' });
assert.equal(demo.version, '8');
assert.equal(nodes.get('#field').textContent, 'unread: 8');
assert.equal(demo.request('delete', '8') instanceof Promise, true);
assert.equal(calls.filter(c => c.url === '/api/intent').length, 2, 'unknown op never leaves client codec');
console.log('PASS stale and undeclared intents never change confirmed view');

nodes.get('#source').value = source.replace('Inbox', 'Edited');
assert.equal(demo.run(), true);
assert.equal(nodes.get('#intent').disabled, true, 'editing invalidates previous manifest');
worker.emit({ kind: 'refused', ok: false, reason: 'unknown-field', line: 1, column: 1, path: '$' });
assert.equal(nodes.get('#intent').disabled, true, 'rejected edit cannot send prior view intent');
assert.equal(nodes.get('#field').textContent, 'unread: 8');
console.log('PASS refused edit preserves view but revokes old manifest authority');
console.log('js-actors: QUOTED-PLAYGROUND-PAGE PASS');
