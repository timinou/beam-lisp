// verify-quoted-browser.mjs — the acceptance contract for the browser half of
// the quoted-view prototype: the page, the Worker and the strict frame decoder.
// Run after the targeted build (which produces both bundles):
//   BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl
//   node research/js-actors/verify-quoted-browser.mjs
//
// WHAT IS ASSERTED, and why each half matters:
//   1. the frame decoder accepts the actor's ONE canonical frame and returns the
//      exact typed value object the page renders;
//   2. the decoder REFUSES every malicious or malformed variation — a changed op,
//      tag, heading level, field name or intent, an extra/missing/reordered
//      child, trailing syntax, a huge string, a malformed JSON escape, a decoded
//      control character — and NEVER throws, even on random input;
//   3. the page / Worker / decoder never assign a string as markup: no
//      innerHTML-family token appears in the served sources, and the page writes
//      through textContent and a data attribute;
//   4. the Worker and decoder parse as modules (`node --check`) and build no
//      JavaScript at runtime (no eval / new Function);
//   5. the server serves the page (with its CSP header), the Worker, the decoder
//      and the compiled frontend bundle, refuses the compiled BACKEND bundle and
//      any other unknown path, denies an unknown intent, advances the version on
//      a real increment and refuses a stale version — all over real HTTP;
//   6. the Worker, driven in Node with a fake `postMessage`, decodes the actor's
//      frames end to end: view(7) → view(8), a typed refusal for a bad wire, a
//      typed error for an unsupported topic and a non-string payload, then STOP —
//      with no decode or import error.
//
// Node is the RUNNER and the HTTP CLIENT; every value asserted is the compiled BL
// actor's own answer or the decoder's own decision.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import http from 'node:http';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { decodeViewFrame, isViewLine } from './quoted-view-frame.mjs';

const dir = fileURLToPath(new URL('.', import.meta.url));
const serverPath = fileURLToPath(new URL('./quoted-server.mjs', import.meta.url));
const pagePath = fileURLToPath(new URL('./quoted-view.html', import.meta.url));
const pageModulePath = fileURLToPath(new URL('./quoted-view-page.mjs', import.meta.url));
const workerPath = fileURLToPath(new URL('./quoted-view-worker.mjs', import.meta.url));
const framePath = fileURLToPath(new URL('./quoted-view-frame.mjs', import.meta.url));
const frontendBundle = new URL('./out/quoted-frontend.mjs', import.meta.url);
const backendBundle = new URL('./out/quoted-backend.mjs', import.meta.url);

assert.ok(
  existsSync(frontendBundle),
  'out/quoted-frontend.mjs is missing — run the targeted build first: ' +
    'BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl',
);
assert.ok(existsSync(backendBundle), 'out/quoted-backend.mjs is missing — run the targeted build first');

// ── helpers: build the actor's ONE canonical frame ──────────────────────────

const json = JSON.stringify;
const viewString = (value) =>
  'view{card(' + json('inbox') + '){heading(2,' + json('Inbox') + ') ' +
  'field(unread=' + json(value) + ') button(' + json('Mark all read') + ',increment) ' +
  'text(' + json('no unread mail') + ')}}';
const frameLine = (value) => 'QV-FRONT VIEW [:ok ' + json(viewString(value)) + ']';
const frameOf = (inner) => 'QV-FRONT VIEW [:ok ' + json(inner) + ']';

// ── 1. the canonical frame decodes to the exact typed value ──────────────────

const expectedView = {
  card: { id: 'inbox' },
  heading: { level: 2, text: 'Inbox' },
  field: { name: 'unread', value: '7' },
  button: { label: 'Mark all read', intent: 'increment' },
  text: 'no unread mail',
};
const good = decodeViewFrame(frameLine('7'));
assert.equal(good.ok, true, 'the canonical frame must decode');
assert.deepEqual(good.view, expectedView, 'decoded view differs from the fixed shape');
assert.equal(decodeViewFrame(frameLine('8')).view.field.value, '8');
assert.equal(isViewLine(frameLine('7')), true);
assert.equal(isViewLine('QV-FRONT REFUSED [:refused [:stale-version "7" "9"]]'), false);
assert.equal(isViewLine(''), false);
console.log('PASS quoted-browser: canonical frame decodes to the fixed typed view');

// ── 2. malformed and malicious frames are refused, never thrown ──────────────

const reordered =
  'view{card("inbox"){field(unread="7") heading(2,"Inbox") button("l",increment) text("c")}}';
const cases = [
  ['wrong-prefix', 'QV-FRONT VIEEW [:ok "x"]'],
  ['refused-line', 'QV-FRONT REFUSED [:refused [:stale-version "7" "9"]]'],
  ['not-a-string', 'QV-FRONT VIEW [:ok 3]'],
  ['not-a-view', 'QV-FRONT VIEW [:ok "hello"]'],
  ['trailing-space', frameLine('7') + ' '],
  ['trailing-junk', frameLine('7') + 'x'],
  ['two-outer-values', 'QV-FRONT VIEW [:ok "x", "y"]'],
  ['unterminated-outer', 'QV-FRONT VIEW [:ok ' + json(viewString('7'))],
  ['inner-trailing', frameOf(viewString('7') + 'x')],
  ['unknown-op', frameOf(viewString('7').replace('card(', 'panel('))],
  ['unknown-tag', frameOf(viewString('7').replace('heading(', 'title('))],
  ['changed-level', frameOf(viewString('7').replace('heading(2,', 'heading(3,'))],
  ['unknown-field', frameOf(viewString('7').replace('field(unread=', 'field(secret='))],
  ['unknown-intent', frameOf(viewString('7').replace(',increment)', ',delete)'))],
  ['extra-child', frameOf(viewString('7').replace(' text("no unread mail")', ' text("no unread mail") text("x")'))],
  ['missing-child', frameOf(viewString('7').replace(' text("no unread mail")', ''))],
  ['reordered-children', frameOf(reordered)],
  ['oversized-string', frameOf(viewString('7').replace('"Inbox"', json('x'.repeat(200))))],
  ['oversized-frame', 'QV-FRONT VIEW [:ok ' + json('view{' + 'x'.repeat(2000) + '}') + ']'],
  ['malformed-escape', frameOf(viewString('7').replace('card("inbox")', 'card("in\\qbox")'))],
  ['raw-newline', frameOf(viewString('7').replace('"inbox"', '"in\nbox"'))],
  ['decoded-control', frameOf(viewString('7').replace('heading(2,"Inbox")', 'heading(2,"a\\u000ab")'))],
  ['quote-injection', frameOf(viewString('7').replace('text("no unread mail")', 'text("a")} }'))],
  ['empty-line', ''],
  ['backslash-end', 'QV-FRONT VIEW [:ok "abc\\'],
];
for (const [name, line] of cases) {
  let result;
  try { result = decodeViewFrame(line); } catch (error) {
    assert.fail(`decoder threw on ${name}: ${error.message}`);
  }
  assert.equal(result.ok, false, `${name} must be refused, got ${json(result)}`);
  assert.equal(typeof result.reason, 'string', `${name} must carry a typed reason`);
  assert.ok(result.view === undefined, `${name} must not carry a view`);
}
for (const bad of [null, undefined, 42, {}, ['x'], true]) {
  const result = decodeViewFrame(bad);
  assert.equal(result.ok, false, `non-string input ${json(bad)} must be refused`);
}
console.log(`PASS quoted-browser: ${cases.length} malformed/malicious frames refused, none thrown`);

// Random input can never make the decoder throw or emit a view: the decoder is
// total, which is what lets the Worker trust it with a fully server-influenced
// line.
let seed = 0x2f6e2b1;
const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
const alphabet = 'abc{}()[],:"\\ \nview card heading field button text unread increment 0123456789';
let fuzzViews = 0;
for (let i = 0; i < 5000; i++) {
  let s = 'QV-FRONT VIEW [:ok "';
  const n = Math.floor(rnd() * 90);
  for (let k = 0; k < n; k += 1) s += alphabet[Math.floor(rnd() * alphabet.length)];
  s += '"]';
  let r;
  try { r = decodeViewFrame(s); } catch (error) {
    assert.fail(`decoder threw on fuzz input: ${error.message}`);
  }
  if (r.ok) fuzzViews += 1;
}
assert.equal(fuzzViews, 0, 'no random frame may decode to a view');
console.log('PASS quoted-browser: 5000 random frames refused with no throw');

// ── 3. no string is assigned as markup anywhere in the served sources ────────

const MARKUP_TOKENS = [/innerHTML/, /outerHTML/, /insertAdjacentHTML/, /document\s*\.\s*write/];
const served = { page: readFileSync(pagePath, 'utf8'), pageModule: readFileSync(pageModulePath, 'utf8'), worker: readFileSync(workerPath, 'utf8'), frame: readFileSync(framePath, 'utf8') };
for (const [name, source] of Object.entries(served)) {
  for (const token of MARKUP_TOKENS) {
    assert.doesNotMatch(source, token, `${name} assigns a string as markup (${token})`);
  }
}
const textWrites = (served.pageModule.match(/\.textContent\s*=/g) || []).length;
assert.ok(textWrites >= 4, `the page must write dynamic text through textContent, saw ${textWrites}`);
assert.match(served.pageModule, /\.dataset\.cardId\s*=/, 'the card id must be applied as a data attribute');
assert.match(served.page, /<script type="module" src="\.\/quoted-view-page\.mjs"><\/script>/);
assert.doesNotMatch(served.page, /<script[^>]*>\s*[^<\s]/, 'the page must contain no inline script');
console.log(`PASS quoted-browser: no markup-assignment in page/worker/decoder (${textWrites} textContent writes)`);

// ── 4. worker and decoder are valid modules that build no JavaScript ─────────

for (const [name, path] of [['page', pageModulePath], ['worker', workerPath], ['frame', framePath]]) {
  const check = spawnSync(process.execPath, ['--check', path], { encoding: 'utf8' });
  assert.equal(check.status, 0, `${name} failed to parse: ${check.stderr}`);
}
for (const [name, source] of [['page', served.pageModule], ['worker', served.worker], ['frame', served.frame]]) {
  assert.doesNotMatch(source, /\beval\s*\(/, `${name} calls eval`);
  assert.doesNotMatch(source, /new\s+Function\s*\(/, `${name} constructs a Function`);
}
console.log('PASS quoted-browser: worker + decoder parse, and build no JavaScript at runtime');

// ── 5. the server serves the allowlist and refuses everything else ───────────

const serverSource = readFileSync(serverPath, 'utf8');
for (const entry of ['/quoted-view.html', '/quoted-view-page.mjs', '/quoted-view-worker.mjs', '/quoted-view-frame.mjs', '/out/quoted-frontend.mjs']) {
  assert.ok(serverSource.includes(`'${entry}'`), `STATIC allowlist is missing ${entry}`);
}
assert.doesNotMatch(
  serverSource,
  /\[\s*'\/out\/quoted-backend\.mjs'/,
  'the compiled backend bundle must not be in the static allowlist',
);
console.log('PASS quoted-browser: static allowlist lists the browser files only');

const child = spawn(process.execPath, [serverPath, '--port', '0'], { cwd: dir, stdio: ['ignore', 'pipe', 'pipe'] });
const errText = [];
const port = await new Promise((resolve, reject) => {
  const deadline = setTimeout(() => reject(new Error('server did not listen in time')), 30000);
  let buffered = '';
  child.stdout.on('data', chunk => {
    buffered += chunk.toString('utf8');
    let nl;
    while ((nl = buffered.indexOf('\n')) >= 0) {
      const line = buffered.slice(0, nl).replace(/\r$/, '');
      buffered = buffered.slice(nl + 1);
      const m = /^QV-BACKEND LISTEN 127\.0\.0\.1:([0-9]+)$/.exec(line);
      if (m) { clearTimeout(deadline); resolve(Number(m[1])); }
    }
  });
  child.stderr.on('data', chunk => errText.push(chunk.toString('utf8')));
  child.on('error', error => { clearTimeout(deadline); reject(error); });
  child.on('exit', code => { clearTimeout(deadline); reject(new Error('server exited early (code ' + code + ')')); });
});
console.log(`PASS quoted-browser: service listening on 127.0.0.1:${port}`);

function request(method, path, { headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path, headers }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}
const post = (obj) =>
  request('POST', '/api/intent', { headers: { 'content-type': 'application/json' }, body: JSON.stringify(obj) });

const page = await request('GET', '/quoted-view.html');
assert.equal(page.status, 200, `expected 200 for the page, got ${page.status}`);
assert.match(page.headers['content-type'], /text\/html/);
const csp = page.headers['content-security-policy'] || '';
for (const directive of ["default-src 'none'", "script-src 'self';", "connect-src 'self'", "worker-src 'self'", "object-src 'none'", "frame-ancestors 'none'"])
  assert.ok(csp.includes(directive), `CSP is missing ${directive}: ${csp}`);
assert.doesNotMatch(csp, /script-src[^;]*unsafe-inline/, 'inline scripts must be refused');
for (const token of MARKUP_TOKENS) assert.doesNotMatch(page.body, token, 'served page assigns a string as markup');
console.log('PASS quoted-browser: page served with a restrictive same-origin CSP');

for (const path of ['/quoted-view-page.mjs', '/quoted-view-worker.mjs', '/quoted-view-frame.mjs', '/out/quoted-frontend.mjs', '/host.mjs']) {
  const res = await request('GET', path);
  assert.equal(res.status, 200, `expected 200 for ${path}, got ${res.status}`);
  assert.match(res.headers['content-type'], /javascript/);
}
console.log('PASS quoted-browser: worker, decoder, frontend bundle and host are served');

for (const path of ['/out/quoted-backend.mjs', '/quoted-server.mjs', '/../compiler.bl', '/etc/passwd']) {
  const res = await request('GET', path);
  assert.equal(res.status, 404, `expected 404 for ${path}, got ${res.status}`);
}
console.log('PASS quoted-browser: backend bundle and non-allowlisted paths are refused');

const denied = await post({ op: 'delete', version: '7' });
assert.equal(denied.status, 403, `unknown intent must be 403, got ${denied.status}: ${denied.body}`);
assert.equal(JSON.parse(denied.body).reason, 'unknown-intent');
const accepted = await post({ op: 'increment', version: '7' });
assert.equal(accepted.status, 200, accepted.body);
assert.deepEqual(JSON.parse(accepted.body), { ok: true, intent: 'increment', version: 8 });
const stale = await post({ op: 'increment', version: '7' });
assert.equal(stale.status, 409, `stale version must be 409, got ${stale.status}: ${stale.body}`);
assert.equal(JSON.parse(stale.body).reason, 'stale-version');
assert.equal(page.headers['access-control-allow-origin'], undefined, 'no CORS header may be emitted');
console.log('PASS quoted-browser: unknown intent denied, increment 7 -> 8, stale refused, no CORS');

child.kill('SIGTERM');
const exit = await Promise.race([
  new Promise(resolve => child.on('exit', (code, signal) => resolve({ code, signal }))),
  new Promise(resolve => setTimeout(() => resolve(null), 5000)),
]);
assert.ok(exit !== null, 'server did not exit after SIGTERM');
assert.equal(exit.code, 0, `server exit code ${exit.code}`);
assert.equal(errText.join(''), '', `server wrote to stderr: ${errText.join('')}`);
console.log('PASS quoted-browser: SIGTERM shutdown is clean');

// ── 6. the Worker decodes the actor's frames and forwards typed messages ─────

const workerUrl = pathToFileURL(workerPath).href;
const harness = `
  const posted = [];
  globalThis.postMessage = (message) => { posted.push(message); };
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const count = (kind) => posted.filter((m) => m.kind === kind).length;
  const until = async (predicate) => {
    for (let i = 0; i < 2000 && !predicate(); i += 1) await wait(5);
    return predicate();
  };
  import(${JSON.stringify(workerUrl)}).catch((error) => posted.push({ kind: 'import-error', text: String(error) }));
  await until(() => count('view') >= 1);
  globalThis.onmessage({ data: { kind: 'event', topic: 'version', payload: '8' } });
  await until(() => count('view') >= 2);
  globalThis.onmessage({ data: { kind: 'event', topic: 'version', payload: '7' } });
  await until(() => count('refused') >= 1);
  globalThis.onmessage({ data: { kind: 'event', topic: 'bogus', payload: 'x' } });
  globalThis.onmessage({ data: { kind: 'event', topic: 'version', payload: 5 } });
  await wait(40);
  globalThis.onmessage({ data: { kind: 'event', topic: 'stop', payload: '' } });
  await until(() => count('stopped') >= 1 && count('done') >= 1);
  process.stdout.write(JSON.stringify(posted));
  process.exit(0);
`;
const run = spawnSync(process.execPath, ['--input-type=module', '-e', harness], {
  cwd: dir,
  encoding: 'utf8',
  timeout: 60000,
  maxBuffer: 4 * 1024 * 1024,
});
assert.ifError(run.error);
assert.equal(run.status, 0, run.stdout + run.stderr);
const posted = JSON.parse(run.stdout);

const views = posted.filter(m => m.kind === 'view');
assert.equal(views.length, 2, `expected two rendered views, saw ${views.length}: ${run.stdout}`);
assert.deepEqual(views[0].view, expectedView, 'the first rendered view is not the fixed view at version 7');
assert.equal(views[1].view.field.value, '8', 'the second rendered view must show version 8');
assert.equal(posted[0].kind, 'view', 'the first Worker message must be the initial view');

const refusals = posted.filter(m => m.kind === 'refused');
assert.equal(refusals.length, 1, 'the bad wire must produce exactly one typed refusal');
assert.match(refusals[0].text, /^QV-FRONT REFUSED \[:refused \[/, 'the refusal must be typed');

const errors = posted.filter(m => m.kind === 'error');
assert.deepEqual(
  errors.map(m => m.text).sort(),
  ['unsupported event topic: bogus', 'version event payload must be a string'],
  `unexpected Worker errors: ${JSON.stringify(errors)}`,
);
assert.equal(posted.some(m => m.kind === 'import-error'), false, 'the frontend bundle failed to import');
assert.equal(errors.some(m => m.text.startsWith('frame rejected')), false, 'a frame failed to decode');
assert.equal(posted.filter(m => m.kind === 'stopped').length, 1, 'STOP must be forwarded once');
assert.equal(posted.filter(m => m.kind === 'done').length, 1, 'the import must resolve after STOP');
console.log('PASS quoted-browser: Worker decodes view 7 -> 8, forwards refusal/error/stop, no decode error');

console.log('js-actors: QUOTED-BROWSER PASS');
