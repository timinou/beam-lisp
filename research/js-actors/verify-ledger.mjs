// verify-ledger.mjs — the exact-money split app, end to end, without a browser.
//
// Proves on the GENERATED artifacts: the `:exact` wire type carries integers
// beyond 2^53 as decimal digits (never a rounded JSON number); the authority
// and the BL client keep them exact through add, total, format and the
// group-by breakdown; placement puts formatting and the breakdown in the
// browser.
import assert from 'node:assert/strict';
import { createCodec, encode } from './split-codec.mjs';
import { startApp, spawnClient, texts, readOut, nonce } from './split-test-kit.mjs';

let passed = 0;
const ok = label => { passed++; console.log('PASS ledger: ' + label); };

const contract = JSON.parse(readOut('ledger.contract.json'));
const manifest = JSON.parse(readOut('ledger.split.json'));
const client = readOut('ledger-client.mjs');
assert.equal(contract.wire.entry[1].cents, 'exact');
const codec = createCodec(contract);
const big = '9007199254740993';
const snap = codec.decodeSnapshot({ entries: [{ id: 1, what: 'x', cat: 'food', cents: big }] });
assert.equal(typeof encode(snap).entries[0].cents, 'string');
assert.equal(encode(snap).entries[0].cents, big, 'a big integer round-trips digit for digit');
assert.equal(encode(codec.decodeSnapshot({ entries: [{ id: 1, what: 'x', cat: 'food', cents: -42 }] })).entries[0].cents, -42);
for (const bad of [9007199254740993, '9007199254740993.5', '1e20', '00012345678901234567', 'NaN', 1.5])
  assert.throws(() => codec.decodeSnapshot({ entries: [{ id: 1, what: 'x', cat: 'food', cents: bad }] }), /exact integer/, String(bad));
ok(':exact carries integers beyond 2^53 as digits; unsafe JSON numbers, fractions and padded digits are refused');

const where = Object.fromEntries(manifest.functions.map(f => [f.name, f.placement]));
for (const n of ['money', 'parse-cents', 'by-category', 'chart', 'ledger-view', 'total']) assert.equal(where[n], 'client', n);
assert.equal(where['add-entry'], 'server');
assert.ok(!client.includes('"js/add-entry"') && !client.includes('"js/initial-ledger"'));
ok('formatting, parsing and the group-by breakdown run in the browser; the ledger stays on the server');

const app = await startApp('ledger');
const hello = await app.snapshotNow();
const treasury = hello.board.entries.find(e => e.what === 'Treasury reserve');
assert.equal(treasury.cents, big, 'the authority publishes the exact digits');
const r = await app.post({ request: 1, revision: 0, digest: contract.digest, nonce: nonce('ledgertab01', 1),
                           op: 'add-entry', args: { what: 'Bond coupon', cat: 'income', cents: '1234567890123456789' } });
assert.equal(r.body.ok, true);
assert.equal(r.body.board.entries.at(-1).cents, '1234567890123456789');
ok('an exact amount far beyond 2^53 commits over HTTP and comes back digit for digit');

const c = await spawnClient('ledger');
let mark = c.frames.length;
c.tell({ kind: 'hello', ...(await app.snapshotNow()) });
const view = (await c.next('view', mark)).value;
const all = texts(view.tree);
const expected = hello.board.entries.reduce((a, e) => a + BigInt(e.cents), 0n) + 1234567890123456789n;
const fmt = cents => { const neg = cents < 0n; const a = neg ? -cents : cents; const whole = (a / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  return (neg ? '−' : '') + whole + '.' + String(a % 100n).padStart(2, '0'); };
assert.ok(all.includes(fmt(expected)), `balance ${fmt(expected)} shown exactly`);
assert.ok(all.includes('90 071 992 547 409.93'), 'the treasury row is formatted exactly');
const asNumber = hello.board.entries.reduce((a, e) => a + Number(e.cents), 0) + 1234567890123456789;
assert.notEqual(BigInt(Math.round(asNumber)), expected, 'a plain Number sum would have been wrong');
ok(`the BL client sums and formats exactly: ${fmt(expected)} (a double would give ${asNumber})`);

for (const [typed, cents] of [['-12.50', -1250], ['3', 300], ['0.5', 50], ['1 000', 100000], ['12345678901234567.89', '1234567890123456789']]) {
  mark = c.frames.length;
  c.tell({ kind: 'event', event: [':amount', typed] });
  await c.next('view', mark);
  mark = c.frames.length;
  c.tell({ kind: 'event', event: [':what', 'probe'] });
  await c.next('view', mark);
  mark = c.frames.length;
  c.tell({ kind: 'event', event: [':add'] });
  const p = (await c.next('propose', mark)).value;
  assert.equal(String(p.args.cents), String(cents), typed);
  const res = await app.post(p);
  mark = c.frames.length;
  c.tell({ kind: 'result', frame: res.body });
  await c.next('view', mark);
}
ok('parse-cents turns typed text into exact cents, including an amount beyond 2^53');

mark = c.frames.length;
c.tell({ kind: 'event', event: [':amount', '12.345'] });
const bad = (await c.next('view', mark)).value;
mark = c.frames.length;
c.tell({ kind: 'event', event: [':add'] });
await new Promise(r => setTimeout(r, 300));
assert.equal(c.frames.slice(mark).some(f => f.topic === 'propose'), false, 'three decimals is not an amount');
ok('an amount with three decimals is refused in the browser (no proposal)');

await c.close();
await app.close();
console.log(`js-actors: LEDGER PASS (${passed} checks)`);
