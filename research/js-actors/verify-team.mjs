// verify-team.mjs — the team board (apps/team.bl), end to end.
//
// One loopback authority (the compiled BL server half) plus child processes
// running the BL client half exactly as the browser Worker runs it. Proves
//
//   * the contract: identity and history are on, undo/redo take no params, and
//     `col` is a closed one-of;
//   * placement: the shared checks ride both halves, the allow/lead-only/says
//     functions and `add-card` stay on the server, and the client bundle
//     carries none of them;
//   * identity: a signed cookie is HttpOnly; SameSite=Strict; Path=/;
//     Max-Age=43200, a flipped MAC is a stranger, logout clears it, and the
//     server STAMPS the actor from the session (a browser cannot claim one);
//   * permissions over HTTP: the full matrix — viewer read-only, member owns
//     or is assigned, only the lead assigns/deletes/undoes;
//   * the activity feed, undo/redo summaries and the future being cleared;
//   * presence: who has the app open, deduplicated, over real SSE cookies;
//   * "view as of" any kept revision (and null past the kept window);
//   * the durable log: one line per commit, replayed identically by a second
//     boot, a duplicate nonce surviving replay, a partial last line tolerated
//     (and truncated) and a bad line failing the boot closed;
//   * the BL client's UX: guest read-only, Ben moves his own, Ana assigns,
//     Undo disabled with no history, and `asof` rendering the past read-only.
//
// Usage: node research/js-actors/verify-team.mjs

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, appendFileSync, copyFileSync, statSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startApp, spawnClient, texts, findAll, attr, contractDigest, nonce, sleep, readOut, HERE } from './split-test-kit.mjs';

let passed = 0;
const ok = label => { passed += 1; console.log('PASS team: ' + label); };

// ── the generated artifacts ─────────────────────────────────────────────────
const contract = JSON.parse(readOut('team.contract.json'));
const manifest = JSON.parse(readOut('team.split.json'));
const clientBundle = readOut('team-client.mjs');
const serverBundle = readOut('team-server.mjs');
const digest = contract.digest;

// ── cleanup: every process and file this run owns ───────────────────────────
const tmpDir = mkdtempSync(join(tmpdir(), 'team-verify-'));
const logFile = join(tmpDir, 'team.log.jsonl');
const closers = [];
const later = fn => { closers.push(fn); return fn; };
const closeLater = obj => { closers.push(() => obj.close()); return obj; };
// A synchronous safety net: even if an assertion throws before `cleanUp` runs,
// no child process and no temp file outlives this run.
const children = new Set();
const track = child => { children.add(child); child.once('exit', () => children.delete(child)); return child; };
process.on('exit', () => {
  for (const c of children) { try { c.kill('SIGKILL'); } catch { /* gone */ } }
  try { rmSync(tmpDir, { recursive: true, force: true }); } catch { /* gone */ }
});
later(() => rmSync(tmpDir, { recursive: true, force: true }));
async function cleanUp() {
  for (const fn of closers.splice(0).reverse()) { try { await fn(); } catch { /* already gone */ } }
}

// ── check 1: the contract ───────────────────────────────────────────────────
assert.equal(contract.schema, 1);
assert.equal(contract.people, true, 'the team board has a roster');
assert.equal(contract.history, true, 'the team board keeps history');
assert.equal(contract.snapshot, 'board');
assert.deepEqual(Object.keys(contract.intents).sort(),
                 ['add-card', 'assign-card', 'delete-card', 'move-card', 'redo', 'rename-card', 'undo']);
assert.deepEqual(contract.intents.undo.params, {}, 'undo takes no params');
assert.deepEqual(contract.intents.redo.params, {}, 'redo takes no params');
assert.deepEqual(contract.wire.col, ['one-of', 'todo', 'doing', 'done'], 'col is a closed one-of');
assert.equal(contractDigest(contract), digest, 'the digest is the SHA-256 of the canonical body');
assert.equal(manifest.digest, digest);
ok('contract: people/history on, undo/redo take no params, col is one-of todo/doing/done');

// ── check 2: where each function lives ──────────────────────────────────────
const where = Object.fromEntries(manifest.functions.map(f => [f.name, f.placement]));
for (const name of ['can?', 'role-of', 'find-card'])
  assert.equal(where[name], 'shared', name + ' is shared');
assert.equal(where['board-view'], 'client', 'the view is the browser\'s');
for (const name of ['allow-add', 'allow-card-op', 'allow-move', 'allow-rename', 'allow-assign', 'allow-delete', 'lead-only'])
  assert.equal(where[name], 'server', name + ' is server-only');
for (const name of ['add-card', 'says-add', 'says-move', 'says-rename', 'says-assign', 'says-delete'])
  assert.equal(where[name], 'server', name + ' is server-only');
const says = manifest.functions.filter(f => f.name.startsWith('says-'));
assert.ok(says.length >= 5 && says.every(f => f.placement === 'server'), 'every says-* is server-only');
for (const name of ['allow-move', 'lead-only', 'says-move', 'add-card'])
  assert.ok(manifest['excluded-from-client'].includes(name), name + ' is excluded from the client');
for (const needle of ['"js/allow-move"', '"js/lead-only"', '"js/says-move"'])
  assert.equal(clientBundle.includes(needle), false, 'the client bundle must not contain ' + needle);
assert.equal(clientBundle.includes('"js/board-view"'), true, 'the client carries its own view');
assert.equal(serverBundle.includes('"js/allow-move"'), true, 'the server carries the permission');
ok('placement: checks shared; allow/lead/says/add-card server; the client bundle carries none of them');

// ── the authority ───────────────────────────────────────────────────────────
const app = closeLater(await startApp('team', { logFile }));
const base = app.base;
assert.equal(app.codec.digest, digest);

await app.until(() => app.events.some(e => e.type === 'hello'), 'the boot hello');
const hello0 = app.events.find(e => e.type === 'hello').data;
assert.equal(hello0.revision, 0);
assert.equal(hello0.board.cards.length, 6);

// The board at each revision, captured from the commit that produced it.
const boards = new Map([[0, hello0.board]]);

// ── check 3: sessions and cookies ───────────────────────────────────────────
const postJSON = async (url, body, headers = {}) => {
  const r = await fetch(base + url, { method: 'POST', headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body) });
  return { status: r.status, body: await r.json(), setCookie: r.headers.get('set-cookie') };
};
const login = async user => {
  const r = await postJSON('/api/login', { user });
  return { status: r.status, body: r.body, cookie: r.setCookie };
};
const me = async cookie => (await (await fetch(base + '/api/me', { headers: cookie ? { cookie } : {} })).json()).person;

const ana = await login('ana');
const ben = await login('ben');
const chloe = await login('chloe');
const dev = await login('dev');
assert.equal(ana.status, 200); assert.equal(ana.body.ok, true); assert.equal(ana.body.person.id, 'ana');
assert.equal(ben.body.person.name, 'Ben'); assert.equal(ben.body.person.role, 'member');
assert.equal(chloe.body.person.name, 'Chloé');
assert.equal(dev.body.person.role, 'viewer');
const zed = await login('zed');
assert.equal(zed.status, 403); assert.equal(zed.body.reason, 'unknown-person');
ok('login: ana/ben/chloe/dev sign in (200); an unknown id is refused (403)');

assert.match(ana.cookie, /^split_sid=[A-Za-z0-9_-]{24}\.[A-Za-z0-9_-]{43}; HttpOnly; SameSite=Strict; Path=\/; Max-Age=43200$/);
ok('the session cookie is exactly HttpOnly; SameSite=Strict; Path=/; Max-Age=43200');

// A flipped MAC character is not a session. Keep the header well-formed so it
// reaches the constant-time compare rather than being refused as garbage.
const throwaway = await login('ana');
const cookieValue = throwaway.cookie.split(';')[0].split('=')[1];
const flipped = cookieValue.slice(0, -1) + (cookieValue.slice(-1) === 'A' ? 'B' : 'A');
const tampered = 'split_sid=' + flipped;
assert.equal(await me(tampered), null, 'a tampered cookie is not a person');
let r = await postJSON('/api/intent', { request: 1, revision: 0, digest, nonce: nonce('teamtampertab01', 1), op: 'add-card', args: { title: 'nope' } }, { cookie: tampered });
assert.equal(r.status, 401); assert.equal(r.body.reason, 'not-signed-in');
ok('a cookie with a flipped MAC is signed out: /api/me is null and an intent is 401');

const out = await postJSON('/api/logout', {}, { cookie: throwaway.cookie });
assert.equal(out.status, 200);
assert.match(out.setCookie, /^split_sid=; HttpOnly; SameSite=Strict; Path=\/; Max-Age=0$/);
assert.equal(await me(throwaway.cookie), null, 'the logged-out cookie names no one');
r = await postJSON('/api/intent', { request: 2, revision: 0, digest, nonce: nonce('teamtampertab01', 2), op: 'add-card', args: { title: 'nope' } }, { cookie: throwaway.cookie });
assert.equal(r.status, 401);
ok('logout clears the cookie (Max-Age=0) and the old cookie then gets 401');

// ── checks 4-6: the permission matrix, stamping and the activity feed ───────
let rev = hello0.revision;
let hreq = 0;
const HTTP_TAB = 'teamhttptab001';
const post = async (cookie, op, args, revision = rev) => {
  hreq += 1;
  const proposal = { request: hreq, revision, digest, nonce: nonce(HTTP_TAB, hreq), op, args };
  const res = await fetch(base + '/api/intent', { method: 'POST',
    headers: { 'content-type': 'application/json', ...(cookie ? { cookie } : {}) }, body: JSON.stringify(proposal) });
  const body = await res.json();
  if (body.board !== undefined && Number.isSafeInteger(body.revision)) boards.set(body.revision, body.board);
  if (body.ok === true && body.duplicate !== true && body.revision > rev) rev = body.revision;
  return { status: res.status, body, proposal };
};

r = await post(null, 'add-card', { title: 'x' });
assert.equal(r.status, 401); assert.equal(r.body.reason, 'not-signed-in');
r = await post(dev.cookie, 'add-card', { title: 'x' });
assert.equal(r.status, 422); assert.equal(r.body.reason, 'viewers-cannot-add');
r = await post(dev.cookie, 'move-card', { id: 1, col: 'done' });
assert.equal(r.status, 422); assert.equal(r.body.reason, 'viewers-cannot-edit');
ok('a viewer reads only: add is viewers-cannot-add, move is viewers-cannot-edit, anonymous is 401');

r = await post(ben.cookie, 'add-card', { title: 'Write release notes' });
assert.equal(r.status, 200); assert.equal(r.body.ok, true); assert.equal(r.body.revision, 1);
const addEntry = r.body.recent.at(-1);
assert.equal(addEntry.op, 'add-card'); assert.equal(addEntry.actor, 'ben'); assert.equal(addEntry.name, 'Ben');
assert.equal(addEntry.says, 'added “Write release notes”');
assert.equal(r.body.history.undo.says, 'added “Write release notes”');
assert.equal(r.body.history.redo, null);
ok('Ben adds a card: the entry is stamped with the SESSION user (ben/Ben) and says the server\'s words');

r = await post(ben.cookie, 'move-card', { id: 1, col: 'done' });
assert.equal(r.status, 422); assert.equal(r.body.reason, 'not-your-card');
r = await post(ben.cookie, 'move-card', { id: 2, col: 'doing' });
assert.equal(r.status, 200); assert.equal(r.body.revision, 2);
assert.equal(r.body.recent.at(-1).says, 'moved “Fix flaky login test” to In progress');
r = await post(ben.cookie, 'assign-card', { id: 4, to: 'ben' });
assert.equal(r.status, 422); assert.equal(r.body.reason, 'only-the-lead-assigns');
r = await post(ben.cookie, 'undo', {});
assert.equal(r.status, 422); assert.equal(r.body.reason, 'only-the-lead-undoes');
ok('a member moves only their own card and cannot assign or undo for everyone');

r = await post(chloe.cookie, 'rename-card', { id: 3, title: 'Pricing page v2' });
assert.equal(r.status, 200); assert.equal(r.body.revision, 3);
assert.equal(r.body.recent.at(-1).says, 'renamed “Pricing page copy” to “Pricing page v2”');
r = await post(chloe.cookie, 'delete-card', { id: 3 });
assert.equal(r.status, 422); assert.equal(r.body.reason, 'only-the-lead-deletes');
ok('Chloé renames the card assigned to her but may not delete it');

r = await post(ana.cookie, 'assign-card', { id: 4, to: 'chloe' });
assert.equal(r.status, 200); assert.equal(r.body.revision, 4);
assert.equal(r.body.recent.at(-1).says, 'assigned “Upgrade the database” to Chloé');
const assignSay = r.body.recent.at(-1).says;
assert.equal(r.body.history.undo.says, assignSay);
assert.equal(r.body.history.redo, null);
ok('the lead assigns a card; the history summary offers that commit as the next undo');

r = await post(ana.cookie, 'undo', {});
assert.equal(r.status, 200); assert.equal(r.body.revision, 5);
assert.equal(r.body.recent.at(-1).says, 'undid ' + assignSay);
assert.equal(r.body.history.redo.says, assignSay, 'redo now offers the undone commit');
r = await post(ana.cookie, 'redo', {});
assert.equal(r.status, 200); assert.equal(r.body.revision, 6);
assert.equal(r.body.recent.at(-1).says, 'redid ' + assignSay);
assert.equal(r.body.history.redo, null);
ok('undo says "undid <that>" and redo "redid <that>"; the summaries track each step');

r = await post(ana.cookie, 'undo', {});
assert.equal(r.status, 200); assert.equal(r.body.revision, 7);
assert.equal(r.body.recent.at(-1).says, 'undid ' + assignSay);
assert.equal(r.body.history.redo.says, assignSay);
r = await post(ana.cookie, 'add-card', { title: 'Fresh notes' });
assert.equal(r.status, 200); assert.equal(r.body.revision, 8);
assert.equal(r.body.recent.at(-1).says, 'added “Fresh notes”');
assert.equal(r.body.history.redo, null, 'a fresh commit clears the future');
r = await post(ana.cookie, 'redo', {});
assert.equal(r.status, 422); assert.equal(r.body.reason, 'nothing-to-redo');
ok('a fresh commit clears the redo future, so redo is nothing-to-redo');

hreq += 1;
const forged = { request: hreq, revision: rev, digest, nonce: nonce(HTTP_TAB, hreq), op: 'delete-card', args: { id: 3 }, actor: 'ana' };
const forgedRes = await fetch(base + '/api/intent', { method: 'POST',
  headers: { 'content-type': 'application/json', cookie: ben.cookie }, body: JSON.stringify(forged) });
assert.equal(forgedRes.status, 400);
assert.equal((await forgedRes.json()).reason, 'malformed-proposal');
ok('a proposal carrying an `actor` key is refused 400 malformed-proposal');

// ── check 7: presence ───────────────────────────────────────────────────────
const openStream = async cookie => {
  const res = await fetch(base + '/api/events', { headers: cookie ? { cookie } : {} });
  const reader = res.body.getReader();
  // Drain in the background so the server keeps pushing presence to everyone.
  (async () => { try { for (;;) { if ((await reader.read()).done) return; } } catch { /* closed */ } })();
  return { close: async () => { try { await reader.cancel(); } catch { /* gone */ } } };
};
// Every stream (including the kit's) sees each presence push, so watch the
// kit's collector for the roster the server broadcast.
const presenceIDs = () => {
  const e = [...app.events].reverse().find(x => x.type === 'presence');
  return e ? e.data.people.map(p => p.id) : null;
};
const waitPresence = pred => app.until(() => { const ids = presenceIDs(); return ids !== null && pred(ids); }, 'presence');

const anaStream = closeLater(await openStream(ana.cookie));
await waitPresence(ids => ids.length === 1 && ids[0] === 'ana');
ok('opening a stream as Ana lists exactly {Ana}');

const chloeStream = closeLater(await openStream(chloe.cookie));
await waitPresence(ids => ids.length === 2 && ids[0] === 'ana' && ids[1] === 'chloe');
const presencePeople = [...app.events].reverse().find(e => e.type === 'presence').data.people;
assert.deepEqual(presencePeople.map(p => p.name), ['Ana', 'Chloé']);
ok('a second stream as Chloé lists exactly {Ana, Chloé}');

const mark7 = app.events.length;
const anaStream2 = closeLater(await openStream(ana.cookie));
await app.until(() => app.events.slice(mark7).some(e => e.type === 'presence'), 'presence after the second Ana');
const afterAna2 = app.events.slice(mark7).find(e => e.type === 'presence').data.people.map(p => p.id);
assert.deepEqual(afterAna2, ['ana', 'chloe'], 'a second Ana stream does not duplicate her');
ok('a second Ana stream does not duplicate her in presence');

await chloeStream.close();
await waitPresence(ids => ids.length === 1 && ids[0] === 'ana');
ok('closing Chloé\'s stream leaves presence {Ana}');
await anaStream.close(); await anaStream2.close();

// ── check 8: view as of ─────────────────────────────────────────────────────
for (const k of [0, 1, 2, 3, 4, 5, 6, 7, 8]) {
  const peek = await (await fetch(base + `/api/peek?revision=${k}`)).json();
  assert.equal(peek.revision, k);
  assert.deepEqual(peek.board, boards.get(k), 'peek ' + k + ' is the board that commit produced');
}
ok('peek returns the board as of every kept revision, identical to its commit');

const far = await (await fetch(base + '/api/peek?revision=999999')).json();
assert.equal(far.board, null, 'an unknown far-past revision has no board');
const future = await (await fetch(base + `/api/peek?revision=${rev + 1000}`)).json();
assert.equal(future.board, null, 'a future revision has no board');
assert.equal((await fetch(base + '/api/peek?revision=abc')).status, 400);
assert.equal((await fetch(base + '/api/peek')).status, 400);
ok('peek outside the kept window is board null; a malformed revision is 400');

// ── check 9: the durable log, replay and corruption ─────────────────────────
const logText = readFileSync(logFile, 'utf8');
const logEntries = logText.split('\n').filter(l => l !== '').map(l => JSON.parse(l));
assert.equal(logEntries.length, rev, 'one log line per commit');
logEntries.forEach((e, i) => {
  assert.deepEqual(Object.keys(e).sort(), ['actor', 'args', 'at', 'nonce', 'op', 'revision', 'v'].sort());
  assert.equal(e.v, 1);
  assert.equal(e.revision, i + 1);
  assert.ok(typeof e.at === 'string' && !Number.isNaN(Date.parse(e.at)), 'at is a timestamp');
  assert.ok(e.actor === null || typeof e.actor === 'string');
  assert.equal(typeof e.op, 'string');
  assert.ok(e.args !== null && typeof e.args === 'object' && !Array.isArray(e.args));
  assert.ok(/^[a-z0-9]{8,32}:[0-9]{1,9}$/.test(e.nonce));
});
ok(`the durable log holds one {v,revision,at,actor,op,args,nonce} line per commit (${rev})`);

const before = await app.snapshotNow();
assert.equal(before.revision, rev);

// Boot a SECOND server on the same log, in its own process (one BL runtime per
// process), and talk to it over HTTP.
const serverSource = logPath => `
import { startSplitServer } from ${JSON.stringify(new URL('./split-server.mjs', HERE).href)};
try {
  const s = await startSplitServer({ port: 0, app: 'team', logFile: ${JSON.stringify(logPath)} });
  console.error('SPLIT LISTEN http://127.0.0.1:' + s.port + '/');
  const stop = () => s.close().then(() => process.exit(0));
  process.on('SIGTERM', stop); process.on('SIGINT', stop);
} catch (e) { console.error('SPLIT FAILED ' + e.message); process.exit(1); }
`;
const spawnServer = logPath => {
  const child = track(spawn(process.execPath, ['--input-type=module', '-e', serverSource(logPath)],
                      { cwd: HERE.pathname, stdio: ['ignore', 'pipe', 'pipe'] }));
  let stderr = '';
  child.stderr.setEncoding('utf8'); child.stderr.on('data', d => { stderr += d; });
  const exited = new Promise(resolve => child.once('exit', (code, signal) => resolve({ code, signal })));
  const api = {
    child, exited, get stderr() { return stderr; },
    async listen(timeoutMs = 30000) {
      const start = Date.now();
      while (!/SPLIT LISTEN/.test(stderr)) {
        if (child.exitCode !== null) throw new Error('server exited early: ' + stderr);
        if (Date.now() - start > timeoutMs) throw new Error('no SPLIT LISTEN: ' + stderr);
        await sleep(25);
      }
      return Number(/SPLIT LISTEN http:\/\/127\.0\.0\.1:(\d+)\//.exec(stderr)[1]);
    },
    async close() {
      if (child.exitCode !== null) return;
      try { child.kill('SIGTERM'); } catch { /* gone */ }
      await Promise.race([exited, sleep(3000).then(() => { try { child.kill('SIGKILL'); } catch { /* gone */ } })]);
    },
  };
  later(() => api.close());
  return api;
};

const second = spawnServer(logFile);
const secondPort = await second.listen();
const secondBase = `http://127.0.0.1:${secondPort}`;
assert.ok(second.stderr.includes(`SPLIT REPLAYED ${rev} commits`), 'the second boot replays the log: ' + second.stderr.trim());

const sseHello = async (url, cookie) => {
  const res = await fetch(url + '/api/events', { headers: cookie ? { cookie } : {} });
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const m = /^event: hello\ndata: (.*)$/m.exec(buffer);
      if (m) return JSON.parse(m[1]);
    }
  } finally { try { await reader.cancel(); } catch { /* gone */ } }
  throw new Error('no hello on the events stream');
};
const replayed = await sseHello(secondBase);
assert.equal(replayed.digest, digest);
assert.equal(replayed.revision, before.revision);
assert.deepEqual(replayed.board, before.board);
assert.deepEqual(replayed.recent, before.recent);
assert.deepEqual(replayed.history, before.history);
ok('a second boot replays to the identical revision, board, recent and history');

const secondBen = await (async () => {
  const res = await fetch(secondBase + '/api/login', { method: 'POST',
    headers: { 'content-type': 'application/json' }, body: JSON.stringify({ user: 'ben' }) });
  return (res.headers.get('set-cookie') || '').split(';')[0];
})();
const firstEntry = logEntries[0];
const dupRes = await fetch(secondBase + '/api/intent', { method: 'POST',
  headers: { 'content-type': 'application/json', cookie: secondBen },
  body: JSON.stringify({ request: 1, revision: 0, digest, nonce: firstEntry.nonce, op: firstEntry.op, args: firstEntry.args }) });
const dup = await dupRes.json();
assert.equal(dup.ok, true); assert.equal(dup.duplicate, true); assert.equal(dup.revision, rev);
ok('a resend of an already-committed proposal to the replayed server is a duplicate');
await second.close();

// A partial last line (a crash mid-write) is ignored and the file truncated.
const partialLog = join(tmpDir, 'partial.log.jsonl');
copyFileSync(logFile, partialLog);
appendFileSync(partialLog, '{"v":1,"revision":' + (rev + 1) + ',"at":"partial');
const third = spawnServer(partialLog);
await third.listen();
assert.ok(third.stderr.includes('SPLIT LOG ignored a partial last line'), 'the partial line is ignored');
assert.ok(third.stderr.includes(`SPLIT REPLAYED ${rev} commits`), 'the rest still replays');
assert.equal(readFileSync(partialLog, 'utf8'), logText, 'the file is truncated back to its last newline');
assert.equal(statSync(partialLog).size, Buffer.byteLength(logText));
ok('a partial last line is tolerated, the rest replays, and the file is truncated');
await third.close();

// A bad middle line (a revision out of order) fails the boot closed, naming it.
const badLog = join(tmpDir, 'bad.log.jsonl');
const lines = logText.split('\n');
const badLine = JSON.stringify({ v: 1, revision: 1, at: new Date().toISOString(), actor: 'ben',
  op: 'add-card', args: { title: 'bad' }, nonce: 'teambadtab001:1' }) + '\n';
writeFileSync(badLog, lines[0] + '\n' + badLine + lines.slice(1).join('\n'));
const fourth = spawnServer(badLog);
const fourthExit = await fourth.exited;
assert.notEqual(fourthExit.code, 0, 'a bad line is a non-zero exit');
assert.ok(fourth.stderr.includes('SPLIT FAILED'), 'the boot fails closed: ' + fourth.stderr.trim());
assert.ok(fourth.stderr.includes('line 2'), 'the failing line is named');
assert.ok(fourth.stderr.includes('revision-out-of-order'), 'the reason is named');
ok('a bad middle line (wrong revision) fails the boot closed with its line number');

// ── check 10: the BL client half, as the Worker runs it ─────────────────────
const awaitFrame = async (client, from, pred, label) => {
  const start = Date.now();
  for (;;) {
    const hit = client.frames.slice(from).filter(f => f.topic === 'view' && pred(f.value)).at(-1);
    if (hit) return hit;
    if (Date.now() - start > 15000) throw new Error('timed out waiting for ' + label);
    await sleep(10);
  }
};
const spawnTeamed = async (hello, tab) => {
  const client = closeLater(spawnClient('team', { tab }));
  track(client.child);
  await client.next('ready', 0);
  const mark = client.frames.length;
  client.tell({ kind: 'hello', ...hello });
  const view = await client.next('view', mark);
  return { client, view: view.value };
};
const isButton = n => Array.isArray(n) && n[0] === 'button' && attr(n) !== null;
const moveButtons = node => findAll(node, n => isButton(n) && typeof attr(n)['aria-label'] === 'string'
                                            && attr(n)['aria-label'].startsWith('Move '));
const assignButtons = node => findAll(node, n => isButton(n) && typeof attr(n).class === 'string'
                                              && attr(n).class.startsWith('who'));
const cardRows = tree => findAll(tree, n => Array.isArray(n) && n[0] === 'li' && attr(n) !== null
                                        && typeof attr(n).key === 'string' && attr(n).key.startsWith('c'));

const guest = await spawnTeamed(await app.snapshotNow(), 'teamguest0000001');
assert.equal(findAll(guest.view.tree, n => Array.isArray(n) && n[0] === 'input' && attr(n) !== null
                                        && attr(n)['aria-label'] === 'New card title').length, 0);
assert.equal(moveButtons(guest.view.tree).length, 0);
ok('as a guest the board offers no composer input and no move buttons');

const benClient = await spawnTeamed(await sseHello(base, ben.cookie), 'teamben00000001');
const liveBoard = boards.get(rev);
for (const card of liveBoard.cards) {
  const row = cardRows(benClient.view.tree).find(n => attr(n).key === 'c' + card.id);
  assert.ok(row, 'card ' + card.id + ' is rendered');
  const mayMove = card.owner === 'ben' || card.assignee === 'ben';
  assert.equal(moveButtons(row).length > 0, mayMove, 'move buttons for card ' + card.id);
}
assert.equal(assignButtons(benClient.view.tree).length, 0, 'a member is offered no assign buttons');
ok('as Ben: move buttons on his own/assigned cards only, and no assign buttons');

const anaClient = await spawnTeamed(await sseHello(base, ana.cookie), 'teamana00000001');
assert.ok(assignButtons(anaClient.view.tree).length > 0, 'the lead is offered assign buttons');
const undoOf = tree => findAll(tree, n => isButton(n) && attr(n).class === 'ghost' && texts(n).some(t => t.includes('Undo')))[0];
assert.ok(undoOf(anaClient.view.tree), 'the Undo button is rendered');
assert.equal(attr(undoOf(anaClient.view.tree)).disabled, false, 'history.undo is set, so Undo is live');
ok('as Ana: assign buttons are present and Undo is enabled while history.undo is set');

const nilAna = await sseHello(base, ana.cookie);
nilAna.history = { undo: null, redo: null };
const nilClient = await spawnTeamed(nilAna, 'teamnilhistory01');
assert.equal(attr(undoOf(nilClient.view.tree)).disabled, true, 'no history.undo, so Undo is disabled');
ok('with history.undo nil the Undo button is disabled');

const asofClient = await spawnTeamed(await sseHello(base, ana.cookie), 'teamsof00000001');
const past = await (await fetch(base + '/api/peek?revision=1')).json();
assert.ok(past.board.cards.length !== liveBoard.cards.length, 'the past board differs from the live one');
let markA = asofClient.client.frames.length;
asofClient.client.tell({ kind: 'asof', revision: 1, board: past.board });
const asofView = await awaitFrame(asofClient.client, markA,
  v => texts(v.tree).some(t => typeof t === 'string' && t.includes('Revision 1 —')), 'the asof banner');
assert.equal(cardRows(asofView.value.tree).length, past.board.cards.length, 'the past board is rendered');
assert.ok(texts(asofView.value.tree).some(t => typeof t === 'string' && t.includes('Read-only')));
ok('an asof frame renders the past board read-only');

markA = asofClient.client.frames.length;
asofClient.client.tell({ kind: 'event', event: [':move', 2, ':doing'] });
const noteView = await awaitFrame(asofClient.client, markA, v => findAll(v.tree,
  n => Array.isArray(n) && n[0] === 'p' && attr(n) !== null && attr(n).class === 'note client').length === 1,
  'the viewing-history note');
assert.ok(texts(noteView.value.tree).some(t => typeof t === 'string' && t.includes('looking at the past')));
assert.equal(asofClient.client.frames.slice(markA).filter(f => f.topic === 'propose').length, 0,
             'a proposal while viewing history emits nothing');
ok('a proposal while viewing history shows the note and emits no propose');

// ── done ────────────────────────────────────────────────────────────────────
await cleanUp();
console.log(`js-actors: TEAM PASS (${passed} checks)`);
