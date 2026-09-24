import assert from 'node:assert/strict';
import { createIntentCodec, parseContractLine } from './quoted-intent-codec.mjs';
import { fenceQuotedForm } from './quoted-form.mjs';

const line = 'QV-BACKEND CONTRACT 1 :increment :unread 16 16';
const contract = parseContractLine(line);
assert.deepEqual(contract, { schema: 1, op: 'increment', field: 'unread', versionChars: 16, payloadChars: 16 });
for (const bad of ['QV-BACKEND CONTRACT 2 :increment :unread 16 16',
  'QV-BACKEND CONTRACT 1 :increment :unread 17 16', line + '\nQV-BACKEND READY'])
  assert.equal(parseContractLine(bad), null);
assert.throws(() => createIntentCodec({ ...contract, extra: true }), /unsupported/);
const codec = createIntentCodec(contract);
const source = '[:card {:id "inbox"} [:heading {:level 2 :text "Inbox"}] [:field :unread] [:button {:label "Mark all read" :intent [:intent :increment]}] [:text "no unread mail"]]';
const fenced = fenceQuotedForm(source);
assert.equal(fenced.ok, true);
assert.equal(codec.matchesView(fenced.manifest), true);
assert.equal(codec.matchesView({ ...fenced.manifest, intent: { authority: 'server', op: 'delete' } }), false);
console.log('PASS declaration and client manifest agree; unsupported descriptors fail closed');

// Finite, exhaustive sample domain for the *wire*, not a proof of all BL values.
for (let n = 0; n <= 4096; n++) {
  const version = String(n);
  const encoded = codec.encodeRequest(contract.op, version);
  assert.equal(encoded.ok, true);
  assert.deepEqual(codec.decodeRequest(JSON.parse(encoded.body)), { ok: true, op: contract.op, version });
  assert.deepEqual(codec.decodeResponse(200, { ok: true, intent: contract.op, version: n + 1 }, version),
    { ok: true, version: String(n + 1) });
}
console.log('PASS 4097 finite exact request/response wire roundtrips');

for (const wire of ['07', '-1', '1.0', '1e0', '', '9007199254740992', '9'.repeat(17)]) {
  assert.equal(codec.encodeRequest(contract.op, wire).ok, false, wire);
  assert.equal(codec.decodeRequest({ op: contract.op, version: wire }).reason, 'malformed-version', wire);
}
assert.equal(codec.encodeRequest('delete', '7').ok, false);
assert.equal(codec.decodeRequest({ op: 'delete', version: '7' }).ok, true,
  'unknown op must still reach the authoritative BL grant check');
assert.equal(codec.decodeRequest({ op: 'increment', version: '7', principal: 'root' }).reason, 'malformed-request');
for (const value of [null, {}, { ok: true, intent: contract.op, version: 9 },
  { ok: true, intent: 'delete', version: 8 }, { ok: true, intent: contract.op, version: 8, extra: 1 }]) {
  assert.deepEqual(codec.decodeResponse(200, value, '7'),
    { ok: false, reason: 'inconsistent-response', fatal: true });
}
assert.deepEqual(codec.decodeResponse(409, { ok: false, reason: 'stale-version' }, '7'),
  { ok: false, reason: 'stale-version' });
assert.equal(codec.decodeResponse(409, { ok: true, intent: contract.op, version: 8 }, '7').fatal, true);
console.log('PASS malformed wires, spoofed authority and inconsistent success refuse');
console.log('js-actors: QUOTED-INTENT-CODEC PASS');
