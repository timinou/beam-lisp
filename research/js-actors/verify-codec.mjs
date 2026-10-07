// verify-codec.mjs — the browser half's JSON boundary (split-codec.mjs).
//
// The Worker decodes every server frame BY THE CONTRACT before the BL client
// sees it. Proves, without a server:
//   * the contract flags (people, history) and the built-in undo/redo;
//   * a proposal carrying an `actor` is refused (the server stamps it);
//   * entries, the recent list, the undo/redo summary, the roster, presence,
//     hello and result/snapshot frames become bounded BL, dropping garbage;
//   * text bounds count codepoints, as priv/lib/split/wire.bl does.
//
// The server's side of the same boundary (split.web decode, sessions, the
// log) is pinned by test/bl/split/web_test.bl.
//
// Usage: node research/js-actors/verify-codec.mjs

import assert from 'node:assert/strict';
import * as H from './host.mjs';
import { createCodec, entryToBL, recentToBL, historyToBL, personToBL, peopleToBL, presenceToBL, helloToBL, frameToBL, textLength } from './split-codec.mjs';

let passed = 0;
const ok = label => { passed += 1; console.log('PASS codec: ' + label); };

// ── the codec: actor refused, history and helpers decoded ────────────────────

const contract = {
  app: 'tiny', digest: 'a'.repeat(64), schema: 1, snapshot: 'board',
  wire: { board: ['record', { n: ['int', 0, 99] }] },
  intents: {
    bump: { params: { by: ['int', 1, 9] } },
    undo: { params: {} },
    redo: { params: {} },
  },
  people: true, history: true,
};
const codec = createCodec(contract);
assert.equal(codec.people, true);
assert.equal(codec.history, true);
assert.equal(codec.hasOp('bump'), true);
assert.equal(codec.hasOp('undo'), true);
assert.equal(codec.hasOp('drop-table'), false);
assert.equal(createCodec({ ...contract, people: undefined, history: undefined }).people, false);
ok('the contract flags default to false and undo/redo are declared ops');

const proposal = { request: 1, revision: 0, digest: contract.digest, nonce: 'tabtabtab:1', op: 'bump', args: { by: 1 } };
assert.equal(codec.decodeProposal(proposal).ok, true);
assert.equal(codec.decodeProposal({ ...proposal, actor: 'alice' }).reason, 'malformed-proposal');
assert.equal(codec.decodeProposal({ ...proposal, op: 'undo', args: {} }).ok, true);
assert.equal(codec.decodeProposal({ ...proposal, op: 'undo', args: { x: 1 } }).reason, 'malformed-args');
ok('the codec refuses a stamped actor and decodes the built-in undo/redo');

assert.equal(H.mapGet(codec.decodeIntentArgs('bump', { by: 4 }), H.kw('by')), 4);
assert.throws(() => codec.decodeIntentArgs('drop-table', {}), /unknown intent/);
assert.throws(() => codec.decodeIntentArgs('undo', { x: 1 }), /record keys/);
ok('decodeIntentArgs decodes a declared op and refuses an undeclared one');

const blEntry = entryToBL(codec, { revision: 3, actor: 'alice', name: 'Alice', op: 'bump', says: 'bumped it' });
assert.equal(H.mapGet(blEntry, H.kw('revision')), 3);
assert.equal(H.kwName(H.mapGet(blEntry, H.kw('op'))), 'bump');
assert.equal(H.isKw(H.mapGet(blEntry, H.kw('op'))), true);
assert.equal(entryToBL(codec, { revision: 3, actor: 'alice', name: 'Alice', op: 'drop-table', says: 'x' }), null);
assert.equal(entryToBL(codec, { revision: 0, actor: null, name: '', op: 'bump', says: 'x' }), null);
assert.equal(entryToBL(codec, { revision: 3, actor: 'alice', name: 'Alice', op: 'bump', says: 'x'.repeat(201) }), null);
const rawEntry = { revision: 3, actor: 'alice', name: 'Alice', op: 'bump', says: 'bumped it' };
assert.equal(H.vecSize(recentToBL(codec, [rawEntry])), 1);
assert.equal(recentToBL(codec, new Array(65).fill(rawEntry)), null);
const blHistory = historyToBL(codec, { undo: { revision: 2, actor: 'alice', name: 'Alice', op: 'bump', says: 'bump' }, redo: null });
assert.notEqual(H.mapGet(blHistory, H.kw('undo')), null);
assert.equal(H.mapGet(blHistory, H.kw('redo')), null);

ok('entries, the recent list and the undo/redo summary become bounded BL');

const person = personToBL({ id: 'alice', name: 'Alice', role: 'editor' });
assert.equal(H.mapGet(person, H.kw('id')), 'alice');
assert.equal(H.kwName(H.mapGet(person, H.kw('role'))), 'editor');
assert.equal(H.isKw(H.mapGet(person, H.kw('role'))), true);
assert.equal(personToBL({ id: 'alice', name: 'Alice', role: 'EDITOR' }), null);
assert.equal(personToBL(null), null);
assert.equal(H.vecSize(peopleToBL([{ id: 'alice', name: 'Alice', role: 'editor' }])), 1);
assert.equal(peopleToBL('nope'), null);
ok('a roster entry becomes BL with its role a keyword, and garbage is refused');

const blPresence = presenceToBL({ people: [{ id: 'alice', name: 'Alice', role: 'editor' }] });
assert.equal(H.isVec(H.mapGet(blPresence, H.kw('people'))), true);
assert.equal(H.vecSize(H.mapGet(blPresence, H.kw('people'))), 1);
assert.equal(H.vecSize(H.mapGet(presenceToBL({}), H.kw('people'))), 0);
assert.equal(H.vecSize(H.mapGet(presenceToBL(null), H.kw('people'))), 0);
ok('a presence frame becomes BL, with an empty roster for a missing list');

const helloFrame = {
  digest: contract.digest, revision: 2, board: { n: 5 },
  people: [{ id: 'alice', name: 'Alice', role: 'editor' }],
  me: { id: 'alice', name: 'Alice', role: 'editor' },
  recent: [{ revision: 2, actor: 'alice', name: 'Alice', op: 'bump', says: 'bumped' }],
  history: { undo: { revision: 1, actor: 'alice', name: 'Alice', op: 'bump', says: 'bumped' }, redo: null },
};
const blHello = helloToBL(codec, helloFrame, 'tabtabtab');
assert.equal(H.mapGet(blHello, H.kw('digest')), contract.digest);
assert.equal(H.mapGet(blHello, H.kw('tab')), 'tabtabtab');
assert.equal(H.mapGet(H.mapGet(blHello, H.kw('board')), H.kw('n')), 5);
assert.equal(H.mapGet(H.mapGet(blHello, H.kw('me')), H.kw('id')), 'alice');
assert.equal(H.vecSize(H.mapGet(blHello, H.kw('people'))), 1);
assert.equal(H.vecSize(H.mapGet(blHello, H.kw('recent'))), 1);
assert.notEqual(H.mapGet(H.mapGet(blHello, H.kw('history')), H.kw('undo')), null);
ok('helloToBL carries :me, :people, :recent and :history to the BL client');

// A frame without the identity/history fields is byte-for-byte the OLD hello:
// an app built before people/history sees exactly what it saw before.
const bare = helloToBL(codec, { digest: contract.digest, revision: 0, board: { n: 1 } }, 'tabtabtab');
assert.equal(H.mapGet(bare, H.kw('people')), null);
assert.equal(H.mapGet(bare, H.kw('me')), null);
assert.equal(H.mapGet(bare, H.kw('recent')), null);
assert.equal(H.mapGet(bare, H.kw('revision')), 0);
ok('a hello without identity/history fields adds none (old apps unchanged)');

const blResult = frameToBL(codec, { revision: 2, board: { n: 5 }, ok: true, request: 1,
  recent: helloFrame.recent, history: helloFrame.history });
assert.equal(H.vecSize(H.mapGet(blResult, H.kw('recent'))), 1);
assert.notEqual(H.mapGet(H.mapGet(blResult, H.kw('history')), H.kw('undo')), null);
const blPlain = frameToBL(codec, { revision: 2, board: { n: 5 }, ok: true, request: 1 });
assert.equal(H.mapGet(blPlain, H.kw('recent')), null);
assert.equal(H.mapGet(blPlain, H.kw('history')), null);
ok('result/snapshot frames pass recent/history through only when present');

// ── text is measured in codepoints, as the BL wire measures it ─────────────
assert.equal(textLength('🍌🍌🍌'), 3);
assert.equal(textLength('e\u0301'), 2);
const textCodec = createCodec({ ...contract, wire: { board: ['record', { n: ['int', 0, 99] }], t: ['text', 1, 3] },
  intents: { name: { params: { t: 't' } } } });
assert.equal(textCodec.decodeProposal({ ...proposal, op: 'name', args: { t: '🍌🍌🍌' } }).ok, true);
assert.equal(textCodec.decodeProposal({ ...proposal, op: 'name', args: { t: '🍌🍌🍌🍌' } }).reason, 'malformed-args');
ok('text bounds count codepoints: three emoji fit [:text 1 3], four do not');

console.log(`js-actors: CODEC PASS (${passed} checks)`);
