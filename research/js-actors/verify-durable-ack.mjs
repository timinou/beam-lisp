// verify-durable-ack.mjs — a commit is acknowledged only once it is on disk.
//
// A durable (:history) app records each commit in its log (datom on fjall,
// fsync'd) BEFORE the answer is delivered. If the log refuses, the commit must
// NOT be acknowledged and the service fails closed. Here, after one good
// commit, the log is told to refuse (SPLIT_LOG_REFUSE names a flag file: while
// it exists, split.log/append! raises as a failed disk would).
//
// The same rule is pinned without a socket in test/bl/split/app_test.bl
// (nothing-is-acknowledged-that-is-not-on-disk); this is the HTTP face of it.
//
// Usage: node research/js-actors/verify-durable-ack.mjs

import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startBeam, readOut } from './split-test-kit.mjs';

const dir = mkdtempSync(join(tmpdir(), 'split-durable-'));
const flag = join(dir, 'refuse');
let s = null;
try {
  s = await startBeam(['team'], { data: dir, env: { SPLIT_LOG_REFUSE: flag } });
  const digest = JSON.parse(readOut('team.contract.json')).digest;
  const login = await fetch(s.base + '/api/login', { method: 'POST', headers: { 'content-type': 'application/json' },
                                                     body: JSON.stringify({ user: 'ana' }) });
  const cookie = login.headers.get('set-cookie').split(';')[0];
  const post = (request, revision, title) => fetch(s.base + '/api/intent', {
    method: 'POST', headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ request, revision, digest, nonce: `durabletab1:${request}`, op: 'add-card', args: { title } }) });

  const first = await post(1, 0, 'on disk');
  assert.equal(first.status, 200, 'a commit the log accepts is acknowledged');
  console.log('PASS durable: a commit the log accepts is acknowledged');

  writeFileSync(flag, '');
  const lost = await post(2, 1, 'not on disk');
  assert.equal(lost.status, 503, 'no acknowledgement for a commit that is not on disk');
  assert.notEqual((await lost.json()).ok, true);
  const after = await post(3, 1, 'again');
  assert.equal(after.status, 503, 'the service stays closed');
  console.log('PASS durable: a refused append is never acknowledged, and the service fails closed');
  console.log('js-actors: DURABLE ACK PASS (2 checks)');
} finally {
  if (s) await s.close();
  rmSync(dir, { recursive: true, force: true });
}
