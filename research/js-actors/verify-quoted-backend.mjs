// verify-quoted-backend.mjs — the acceptance contract for the server-side
// quoted-view demo. Run after the targeted build (compiler.bl):
//   BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl
//   node research/js-actors/verify-quoted-backend.mjs
//
// Node is the test RUNNER and the HTTP CLIENT, never the runtime: it launches
// `quoted-server.mjs`, which imports the GENERATED BL bundle. Every decision
// asserted below is the compiled BL actor's, transported over HTTP.
//
// WHAT IS ASSERTED, and why each half matters:
//   1. the actor's own transcript: `QV-BACKEND READY`, then one typed
//      `QV-BACKEND RESULT <seq> <result>` line per request, with monotonic seq;
//   2. one accepted request advances the version, and the actor reports it;
//   3. a stale request is 409 and does NOT advance — the request AFTER a refusal
//      still sees the correct server version (the refusal changed no state);
//   4. an unknown intent is denied by the BL grant check, not by this client;
//   5. malformed transport (JSON, shape, extra key, version type) is 400;
//   6. an oversized body is 413 and never reaches the actor;
//   7. a browser principal/grants field is refused (no such key is accepted);
//   8. content-type, origin, host and method are checked, with no CORS headers;
//   9. the static allowlist serves a known file and refuses traversal;
//  10. the actor survives every refusal (its transcript keeps answering), and
//      the service shuts down cleanly on SIGTERM.
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const cwd = fileURLToPath(new URL('../../', import.meta.url)); // repository root
const serverPath = fileURLToPath(new URL('./quoted-server.mjs', import.meta.url));
const bundlePath = new URL('./out/quoted-backend.mjs', import.meta.url);

assert.ok(
  existsSync(bundlePath),
  'out/quoted-backend.mjs is missing — run the targeted build first: ' +
    'BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl',
);

// ── launch the service ───────────────────────────────────────────────────────

const child = spawn(process.execPath, [serverPath, '--port', '0'], {
  cwd,
  stdio: ['ignore', 'pipe', 'pipe'],
});

const outLines = [];
const errText = [];
const listen = new Promise((resolve, reject) => {
  const deadline = setTimeout(() => reject(new Error('server did not listen in time')), 30000);
  let buffered = '';
  child.stdout.on('data', chunk => {
    buffered += chunk.toString('utf8');
    let nl;
    while ((nl = buffered.indexOf('\n')) >= 0) {
      const line = buffered.slice(0, nl).replace(/\r$/, '');
      buffered = buffered.slice(nl + 1);
      outLines.push(line);
      const m = /^QV-BACKEND LISTEN 127\.0\.0\.1:([0-9]+)$/.exec(line);
      if (m) { clearTimeout(deadline); resolve(Number(m[1])); }
    }
  });
  child.stderr.on('data', chunk => errText.push(chunk.toString('utf8')));
  child.on('error', error => { clearTimeout(deadline); reject(error); });
  child.on('exit', code => {
    clearTimeout(deadline);
    reject(new Error('server exited early (code ' + code + ')\n' + errText.join('')));
  });
});

let exited = null;
child.on('exit', (code, signal) => { exited = { code, signal }; });

const port = await listen;
console.log(`PASS quoted-backend: actor ready, service listening on 127.0.0.1:${port}`);

// ── a raw HTTP client, so a hostile path is sent exactly as written ──────────

function request(method, path, { headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path, headers }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () =>
        resolve({
          status: res.statusCode,
          headers: res.headers,
          body: Buffer.concat(chunks).toString('utf8'),
        }));
    });
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

const JSON_HEAD = { 'content-type': 'application/json' };
const postRaw = (raw, headers = JSON_HEAD) =>
  request('POST', '/api/intent', { headers, body: raw });
const post = (obj, headers = {}) =>
  postRaw(JSON.stringify(obj), { ...JSON_HEAD, ...headers });

function json(res) {
  try { return JSON.parse(res.body); } catch { return null; }
}
function expect(res, status, reason) {
  assert.equal(res.status, status, `expected ${status}, got ${res.status}: ${res.body}`);
  const parsed = json(res);
  assert.ok(parsed !== null, `response is not JSON: ${res.body}`);
  assert.equal(parsed.ok, status === 200, `unexpected ok flag: ${res.body}`);
  if (reason !== undefined) assert.equal(parsed.reason, reason, `unexpected reason: ${res.body}`);
  return parsed;
}

// ── 1. one accepted request advances the version ─────────────────────────────

const accepted = expect(await post({ op: 'increment', version: '7' }), 200);
assert.equal(accepted.intent, 'increment');
assert.equal(accepted.version, 8);
console.log('PASS quoted-backend: 200 accepted, version 7 -> 8');

// ── 2. a stale request is refused AND does not advance ───────────────────────

expect(await post({ op: 'increment', version: '7' }), 409, 'stale-version');
console.log('PASS quoted-backend: 409 stale version refused');

// The request AFTER a refusal must still see the version the actor held (8).
const afterRefusal = expect(await post({ op: 'increment', version: '8' }), 200);
assert.equal(afterRefusal.version, 9);
console.log('PASS quoted-backend: version after refusal is correct (8 -> 9)');

// ── 3. an unknown intent is denied by the BL grant check ─────────────────────

expect(await post({ op: 'delete', version: '9' }), 403, 'unknown-intent');
console.log('PASS quoted-backend: 403 unknown intent denied');

// ── 4. malformed transport is 400 and never reaches the actor ────────────────

expect(await postRaw('{'), 400, 'malformed-json');
expect(await post({ op: 'increment' }), 400, 'malformed-request');
expect(await post({ version: '9' }), 400, 'malformed-request');
expect(await post({ op: 'increment', version: '9', principal: 'root' }), 400, 'malformed-request');
expect(await post({ op: 'increment', version: '9', grants: ['increment'] }), 400, 'malformed-request');
expect(await post({ op: 'increment', version: 9 }), 400, 'malformed-version');
expect(await post({ op: 'increment', version: '09' }), 400, 'malformed-version');
expect(await post({ op: 'Increment', version: '9' }), 400, 'malformed-op');
console.log('PASS quoted-backend: malformed requests are 400 (no principal/grants accepted)');

// ── 5. content-type, method, origin and host checks ──────────────────────────

const noType = await request('POST', '/api/intent', { body: '{"op":"increment","version":"9"}' });
expect(noType, 415, 'content-type-refused');
expect(await request('GET', '/api/intent'), 405, 'method-not-allowed');
expect(await post({ op: 'increment', version: '9' }, { origin: 'http://evil.example' }), 403, 'origin-refused');
expect(await post({ op: 'increment', version: '9' }, { host: 'evil.example' }), 403, 'host-refused');
console.log('PASS quoted-backend: content-type, method, origin and host are checked');

// ── 6. an oversized body is 413 and never reaches the actor ──────────────────

const huge = JSON.stringify({ op: 'increment', version: '9'.repeat(6000) });
expect(await postRaw(huge), 413, 'oversized-body');
console.log('PASS quoted-backend: oversized body is 413');

// ── 7. static allowlist serves a known file and refuses traversal ────────────

const page = await request('GET', '/browser.html');
assert.equal(page.status, 200, `expected 200 for /browser.html: ${page.status}`);
assert.match(page.headers['content-type'], /text\/html/);
console.log('PASS quoted-backend: allowlisted static file served');

for (const path of ['/../compiler.bl', '/%2e%2e/compiler.bl', '/out/../../compiler.bl', '/etc/passwd']) {
  const res = await request('GET', path);
  assert.notEqual(res.status, 200, `traversal path served: ${path}`);
  assert.equal(res.status, 404, `expected 404 for ${path}, got ${res.status}`);
}
// No CORS header is ever emitted.
assert.equal(page.headers['access-control-allow-origin'], undefined);
const api = await post({ op: 'increment', version: '9' });
assert.equal(api.headers['access-control-allow-origin'], undefined);
console.log('PASS quoted-backend: static traversal refused, no CORS headers');

// ── 8. the actor survived every refusal and its transcript is sequential ─────

const results = outLines.filter(line => line.startsWith('QV-BACKEND RESULT '));
assert.ok(results.length >= 5, `expected one result line per dispatched request, saw ${results.length}`);
const seqs = results.map(line => Number(/^QV-BACKEND RESULT ([0-9]+) /.exec(line)[1]));
assert.deepEqual(seqs, seqs.map((_, i) => i + 1), `result sequence is not 1..n: ${seqs.join(',')}`);
assert.equal(outLines.filter(line => line === 'QV-BACKEND READY').length, 1);
assert.equal(outLines[0], 'QV-BACKEND READY', 'the first actor line must be READY');
assert.ok(
  results.some(line => line.includes('[:ok {:intent :increment, :version 8}]')),
  'the accepted result line is missing',
);
assert.ok(
  results.some(line => line.startsWith('QV-BACKEND RESULT 2 [:refused [:stale-version "7" 8]]')),
  'the stale refusal line is missing',
);
assert.doesNotMatch(errText.join(''), /error\(s\) recorded/);
console.log(`PASS quoted-backend: actor survived refusals (${results.length} typed result lines, seq 1..n)`);

// ── 9. the BL actor's own bounds, probed directly ────────────────────────────
//
// The HTTP transport already refuses an over-long body and a non-canonical
// version, so those bounds would mask the actor's. This second child imports
// the bundle with the real host and feeds the actor payloads the HTTP layer
// would never forward, proving the BL side refuses them too and that a version
// wire is never parsed into a number (a huge or zero-padded decimal is echoed
// verbatim, never rounded).
const probeSource = `
import * as H from './host.mjs';
const lines = [];
console.log = (...a) => lines.push(a.join(' '));
import('./out/quoted-backend.mjs').catch(e => lines.push('BOOT-ERR ' + e.message));
const wait = ms => new Promise(r => setTimeout(r, ms));
for (let i = 0; i < 300 && !lines.includes('QV-BACKEND READY'); i++) await wait(10);
H.enqueueInput('increment', '1'.repeat(40));
await wait(50);
H.enqueueInput('increment', '9007199254740991');
await wait(50);
H.enqueueInput('increment', '0000000000000007');
await wait(50);
process.stdout.write(lines.filter(l => l.startsWith('QV-BACKEND RESULT')).join('\\n') + '\\n');
process.exit(0);
`;
const probe = spawn(process.execPath, ['--input-type=module', '-e', probeSource], {
  cwd: fileURLToPath(new URL('.', import.meta.url)),
  stdio: ['ignore', 'pipe', 'pipe'],
});
let probeOut = '';
probe.stdout.on('data', c => { probeOut += c.toString('utf8'); });
const probeCode = await new Promise(resolve => probe.on('exit', resolve));
assert.equal(probeCode, 0, `actor probe exited ${probeCode}`);
assert.ok(probeOut.includes('[:refused [:oversized-request 40]]'), probeOut);
assert.ok(probeOut.includes('[:refused [:stale-version "9007199254740991" 7]]'), probeOut);
assert.ok(probeOut.includes('[:refused [:stale-version "0000000000000007" 7]]'), probeOut);
console.log('PASS quoted-backend: BL actor bounds (oversized payload, no silent rounding)');

// ── 10. clean shutdown ────────────────────────────────────────────────────────

child.kill('SIGTERM');
const exit = await Promise.race([
  new Promise(resolve => child.on('exit', (code, signal) => resolve({ code, signal }))),
  new Promise(resolve => setTimeout(() => resolve(null), 5000)),
]);
assert.ok(exit !== null, 'server did not exit after SIGTERM');
assert.equal(exit.code, 0, `server exit code ${exit.code} (signal ${exit.signal})`);
assert.equal(exited.code, 0);
console.log('PASS quoted-backend: SIGTERM shutdown is clean');

console.log('js-actors: QUOTED-BACKEND PASS');
