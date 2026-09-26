// verify-durable-ack.mjs — a commit is acknowledged only once it is on disk.
//
// A durable (:history) app appends each commit to its log BEFORE the answer is
// delivered. If the append fails, the commit must NOT be acknowledged and the
// service fails closed. Here the log path is swapped for a directory after
// boot, so the append throws. (Review finding on dcf88a31, fixed.)
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';
import { startSplitServer } from './split-server.mjs';
const dir = mkdtempSync(join(tmpdir(), 'split-append-'));
const logFile = join(dir, 'team.log.jsonl');
const s = await startSplitServer({ port: 0, app: 'team', logFile });
rmSync(dir, { recursive: true, force: true }); mkdirSync(logFile, { recursive: true }); // the log path is now a DIRECTORY
const base = `http://127.0.0.1:${s.port}`;
const contract = await (await fetch(base + '/out/team.contract.json')).json();
const login = await fetch(base + '/api/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ user: 'ana' }) });
const cookie = login.headers.get('set-cookie').split(';')[0];
const r = await fetch(base + '/api/intent', { method: 'POST', headers: { 'content-type': 'application/json', cookie },
  body: JSON.stringify({ request: 1, revision: 0, digest: contract.digest, nonce: 'appendtab1:1', op: 'add-card', args: { title: 'lost?' } }) });
const body = await r.json();
assert.equal(r.status, 503, 'no acknowledgement for a commit that is not on disk');
assert.notEqual(body.ok, true);
const r2 = await fetch(base + '/api/intent', { method: 'POST', headers: { 'content-type': 'application/json', cookie },
  body: JSON.stringify({ request: 2, revision: 0, digest: contract.digest, nonce: 'appendtab1:2', op: 'add-card', args: { title: 'again' } }) });
assert.equal(r2.status, 503, 'the service stays closed');
console.log('PASS durable: a failed append is never acknowledged, and the service fails closed');
rmSync(dir, { recursive: true, force: true });
await s.close();
console.log('js-actors: DURABLE ACK PASS (1 checks)');
