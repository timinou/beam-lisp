// verify-session.mjs — the pure, no-authority half of the transport's identity
// and history state.
//
// Runs NOW, against the current out/ artifacts, because it needs no compiled
// server bundle:
//   * a session cookie signs and verifies, and any tamper is refused;
//   * the compare is the constant-time path and never throws on junk;
//   * the cookie attribute string is exactly what the transport promises;
//   * the JSONL log parses good lines, tolerates a partial LAST line (and says
//     where to truncate), and fails closed on a bad middle line, naming it;
//   * the codec refuses a proposal that carries an `actor`, and decodes
//     undo/redo and the entry/person/frame helpers the Worker and the page use.
//
// Usage: node research/js-actors/verify-session.mjs

import assert from 'node:assert/strict';
import * as S from './split-session.mjs';
import * as H from './host.mjs';
import { createCodec, entryToBL, recentToBL, historyToBL, personToBL, peopleToBL, presenceToBL, helloToBL, frameToBL } from './split-codec.mjs';

let passed = 0;
const ok = label => { passed += 1; console.log('PASS session: ' + label); };

// ── sessions and cookies ─────────────────────────────────────────────────────

const secret = S.newSecret();
assert.equal(secret.length, 32);
const sid = S.newSessionId();
assert.match(sid, /^[A-Za-z0-9_-]{24}$/);
assert.notEqual(S.newSessionId(), sid);
ok('a secret is 32 random bytes and a session id is 24 base64url characters');

const value = S.sessionCookieValue(secret, sid);
assert.equal(value, `${sid}.${S.sessionMac(secret, sid)}`);
assert.equal(S.verifySessionCookie(secret, `${S.SESSION_COOKIE}=${value}`), sid);
assert.equal(S.verifySessionCookie(secret, `other=1; ${S.SESSION_COOKIE}=${value}; more=2`), sid);
ok('a signed cookie round-trips, including among other cookies');

// Tamper a sid character: the mac no longer matches.
const flipped = (sid[0] === 'A' ? 'B' : 'A') + sid.slice(1);
assert.equal(S.verifySessionCookie(secret, `${S.SESSION_COOKIE}=${flipped}.${S.sessionMac(secret, sid)}`), null);
// Tamper one mac character: same length, wrong value — the constant-time path.
const mac = S.sessionMac(secret, sid);
const badMac = (mac[0] === 'A' ? 'B' : 'A') + mac.slice(1);
assert.equal(S.verifySessionCookie(secret, `${S.SESSION_COOKIE}=${sid}.${badMac}`), null);
// A shorter/longer mac is refused before the compare, and never throws.
assert.equal(S.verifySessionCookie(secret, `${S.SESSION_COOKIE}=${sid}.${mac.slice(0, 20)}`), null);
ok('a flipped sid or mac is refused; a forged, same-length mac goes through the constant-time compare');

assert.equal(S.verifySessionCookie(S.newSecret(), `${S.SESSION_COOKIE}=${value}`), null);
assert.equal(S.verifySessionCookie(secret, undefined), null);
assert.equal(S.verifySessionCookie(secret, ''), null);
assert.equal(S.verifySessionCookie(secret, 'split_sid=not-a-cookie'), null);
assert.equal(S.verifySessionCookie(secret, 'split_sid=.'), null);
assert.equal(S.verifySessionCookie(secret, 'split_sid=a.b.c'), null);
for (const junk of ['x=y', 'split_sid', ';;;', 'split_sid=', 'split_sid=' + 'z'.repeat(200)])
  assert.equal(S.verifySessionCookie(secret, junk), null);
ok('an unknown secret, a missing header and malformed cookies are refused without throwing');

assert.equal(S.setCookieHeader(secret, sid),
  `${S.SESSION_COOKIE}=${value}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200`);
assert.equal(S.COOKIE_ATTRS, 'HttpOnly; SameSite=Strict; Path=/; Max-Age=43200');
assert.equal(S.clearCookieHeader(), 'split_sid=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
ok('the Set-Cookie attribute string is exact, and logout clears it with Max-Age=0');

assert.equal(S.readCookie('a=1; split_sid=xyz', 'split_sid'), 'xyz');
assert.equal(S.readCookie('split_sid=xyz; a=1', 'split_sid'), 'xyz');
assert.equal(S.readCookie('a=1; b=2', 'split_sid'), null);
assert.equal(S.readCookie('notsplit_sid=xyz', 'split_sid'), null);
ok('readCookie matches an exact name and ignores look-alikes');

// ── the durable commit log ───────────────────────────────────────────────────

const line = n => JSON.stringify({ v: 1, revision: n, at: '2026-09-26T00:00:00.000Z',
  actor: 'alice', op: 'bump', args: { by: 1 }, nonce: `tabtabtab:${n}` });

const good = `${line(1)}\n${line(2)}\n`;
const parsedGood = S.parseLogText(good);
assert.equal(parsedGood.error, null);
assert.equal(parsedGood.truncated, false);
assert.deepEqual(parsedGood.entries.map(e => e.value.revision), [1, 2]);
assert.equal(S.parseLogText('').entries.length, 0);
ok('a well-formed log parses line by line, in order');

// A crash mid-append: the final segment has no newline, so it is ignored and
// the caller knows exactly where to truncate.
const partial = `${line(1)}\n{"v":1,"revision":2,"at":"2026`;
const parsedPartial = S.parseLogText(partial);
assert.equal(parsedPartial.error, null);
assert.equal(parsedPartial.truncated, true);
assert.deepEqual(parsedPartial.entries.map(e => e.value.revision), [1]);
assert.equal(S.truncatedByteLength(partial), Buffer.byteLength(`${line(1)}\n`));
assert.equal(S.truncatedByteLength('no newline at all'), 0);
ok('a partial last line is tolerated, and the truncation offset is its last newline');

const badMiddle = `${line(1)}\nnot json\n${line(3)}\n`;
const parsedBad = S.parseLogText(badMiddle);
assert.deepEqual(parsedBad.error, { line: 2, reason: 'invalid-json' });
assert.equal(parsedBad.entries.length, 1);
assert.equal(S.parseLogText(`${line(1)}\n\n${line(3)}\n`).error.line, 2);
assert.equal(S.parseLogText(`${line(1)}\n\n${line(3)}\n`).error.reason, 'blank-line');
ok('a bad middle line fails closed and names the line');

for (const [mutate, reason] of [
  [o => ({ ...o, v: 2 }), 'bad-version'],
  [o => ({ ...o, revision: 0 }), 'bad-revision'],
  [o => ({ ...o, op: 'NotAnOp' }), 'bad-op'],
  [o => ({ ...o, nonce: '' }), 'bad-nonce'],
  [o => ({ ...o, args: [1] }), 'bad-args'],
  [o => ({ ...o, at: 5 }), 'bad-at'],
  [o => ({ ...o, actor: 7 }), 'bad-actor'],
]) {
  const one = { v: 1, revision: 1, at: '2026-09-26T00:00:00.000Z', actor: 'alice', op: 'bump', args: { by: 1 }, nonce: 'tabtabtab:1' };
  assert.equal(S.parseLogText(JSON.stringify(mutate(one)) + '\n').error.reason, reason);
}
ok('a line of the wrong shape fails closed with a named reason');

const entry = { v: 1, revision: 3, at: '2026-09-26T00:00:00.000Z', actor: 'alice', op: 'bump', args: { by: 1 }, nonce: 'tabtabtab:3' };
assert.equal(S.logEntryError(entry, { isKnownOp: () => true, expectedRevision: 3 }), null);
assert.equal(S.logEntryError(entry, { isKnownOp: () => true, expectedRevision: 4 }), 'revision-out-of-order');
assert.equal(S.logEntryError(entry, { isKnownOp: () => false, expectedRevision: 3 }), 'unknown-op');
ok('the contract-aware check pins revision order and the declared ops');

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

console.log(`js-actors: SESSION PASS (${passed} checks)`);
