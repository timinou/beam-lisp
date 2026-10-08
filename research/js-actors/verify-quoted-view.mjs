// verify-quoted-view.mjs — the transcript contract for the generated
// quoted-view bundle. Run after the targeted build (compiler.bl):
//   BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl
//   node research/js-actors/verify-quoted-view.mjs
//
// Node is only the test runner, not a runtime dependency: the assertions below
// check what the GENERATED BL bundle answered, not a JavaScript re-implementation
// of it. The bundle is a real actor application — its main is spawned by the
// shared runtime and its transcript goes through host/write — so importing it
// and reading its stdout is the same transport the other verifiers use.
//
// WHAT IS ASSERTED, and why each half matters:
//   1. the FULL expected transcript, line for line (the evaluator is a pure
//      function of data, so the transcript is deterministic);
//   2. determinism — a second run produces byte-identical stdout;
//   3. fail-closed — every REFUSED line carries a typed refusal and NO rendered
//      view, and the accepted intent carries typed values;
//   4. no-eval — the generated bundle text constructs no JavaScript at runtime;
//   5. host ABI — every host leaf the evaluator calls is present in the host the
//      bundle imports, the same closed check the bundle runs at boot.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import * as H from './host.mjs';

const cwd = new URL('.', import.meta.url);
const bundlePath = new URL('./out/quoted-view.mjs', import.meta.url);
const gatePath = new URL('./out/numeric-gate.quoted-view.mjs.json', import.meta.url);

assert.ok(
  existsSync(bundlePath),
  'out/quoted-view.mjs is missing — run the targeted build first: ' +
    'BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl',
);

function runBundle() {
  return spawnSync(
    process.execPath,
    ['--input-type=module', '-e', "await import('./out/quoted-view.mjs');"],
    { cwd, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024 },
  );
}

// The ONE view the evaluator renders, as the fixed whitelist template message.
// `JSON.stringify` is exactly how the host renders a BL string in `describe`, so
// the expected line is built the same way the bundle built it.
const RENDER =
  'view{card("main"){heading(2,"Inbox") field(unread="3") ' +
  'button("Mark read",increment) text("no new mail")}}';

const VIEW_OK = `QV-VIEW OK [:ok ${JSON.stringify(RENDER)}]`;

// One row per refusal CLASS the evaluator implements, in the order the bundle
// asks for them. Each string is the reason value the bundle must print.
const VIEW_REFUSALS = [
  '[:unknown-op :marquee]',            // an op outside the closed grammar
  '[:unknown-field :secret]',          // a field outside the closed allowlist
  '[:missing-field :owner]',           // allowlisted field, absent from the env
  '[:unsafe-field :unread]',           // value present but not a bounded string
  '[:malformed-arity :heading 1]',     // a node with no argument at all
  '[:malformed-arity :text 3]',        // a leaf op given a child
  '[:malformed-attributes :heading]',  // attributes that are not a map
  '[:unknown-attribute :href]',        // an attribute the grammar does not name
  '[:level-out-of-range 9]',           // a numeric attribute outside its range
  '[:unknown-intent :delete]',         // a button intent outside the allowlist
  '[:not-a-form]',                     // a value that is not a data form
  '[:not-an-op]',                      // a form whose head is not a keyword
  '[:too-deep 7]',                     // depth bound
  '[:too-many-nodes 65]',              // node-count bound
  '[:oversized-text 200]',             // per-string length bound
  '[:too-much-text 120]',              // total-text bound over the whole view
];

const INTENT_OK = 'QV-INTENT OK [:ok {:intent :increment, :version 8}]';

const INTENT_REFUSALS = [
  '[:unknown-intent :delete]',         // op outside the granted intent list
  '[:unauthorized :guest]',            // principal not in the server grant map
  '[:stale-version 6 7]',              // request version behind the expected one
  '[:malformed-request]',              // not a vector
  '[:malformed-request]',              // arity 1
  '[:malformed-request]',              // head is not the intent keyword
  '[:malformed-intent]',               // op is not a keyword
  '[:oversized-request 40]',           // optional payload past its bound
  '[:malformed-version]',              // wire version must be an integer
  '[:version-exhausted]',              // no silent Number overflow
];

const expected = [
  'quoted-view: data-form view evaluator and intent gate',
  'quoted-view: no quoted literal, no symbol resolution, no eval, no DOM',
  VIEW_OK,
  ...VIEW_REFUSALS.map(reason => `QV-VIEW REFUSED [:refused ${reason}]`),
  INTENT_OK,
  ...INTENT_REFUSALS.map(reason => `QV-INTENT REFUSED [:refused ${reason}]`),
  'quoted-view: done',
];

// ── 1. the expected transcript ────────────────────────────────────────────────
const first = runBundle();
assert.ifError(first.error);
assert.equal(first.status, 0, first.stdout + first.stderr);
assert.equal(first.stderr, '', `bundle wrote to stderr: ${first.stderr}`);

const lines = first.stdout.split('\n').filter(line => line.length > 0);
assert.deepEqual(lines, expected, 'generated bundle transcript differs');
console.log(`PASS quoted-view transcript: ${lines.length} lines, exact`);

// ── 2. determinism ────────────────────────────────────────────────────────────
const second = runBundle();
assert.equal(second.status, 0, second.stdout + second.stderr);
assert.equal(second.stdout, first.stdout, 'transcript is not deterministic');
console.log('PASS quoted-view transcript is byte-identical across runs');

// ── 3. fail-closed ────────────────────────────────────────────────────────────
const refused = lines.filter(line => line.includes(' REFUSED '));
assert.equal(refused.length, VIEW_REFUSALS.length + INTENT_REFUSALS.length);
for (const line of refused) {
  assert.match(line, /^QV-(VIEW|INTENT) REFUSED \[:refused \[/);
  assert.doesNotMatch(line, /view\{/, `a refusal leaked a rendered view: ${line}`);
  assert.doesNotMatch(line, /\[:ok /, `a refusal carried an accepted value: ${line}`);
}
assert.match(VIEW_OK, /\[:ok "view\{/);
assert.match(INTENT_OK, /\[:ok \{:intent :increment, :version 8\}\]/);
// The template message is written from fixed literals: no markup escapes it.
assert.doesNotMatch(RENDER, /[<>]/);
console.log(`PASS quoted-view fail-closed: ${refused.length} typed refusals, no partial render`);

// ── 4. no JavaScript is constructed at runtime ────────────────────────────────
const bundleSource = readFileSync(bundlePath, 'utf8');
assert.doesNotMatch(bundleSource, /\beval\s*\(/, 'generated bundle contains an eval call');
assert.doesNotMatch(bundleSource, /new\s+Function\s*\(/, 'generated bundle constructs a Function');
assert.match(bundleSource, /import \* as H from "\.\.\/host\.mjs";/);
console.log('PASS quoted-view bundle builds no JavaScript at runtime');

// ── 5. the host ABI the evaluator is written against ──────────────────────────
const leaves = new Set(H.hostNames());
const USED = [
  'arith', 'describe', 'eq', 'is-int', 'is-kw', 'is-map', 'is-nil', 'is-str',
  'is-vec', 'lt', 'map-get', 'map-keys', 'str-cat', 'str-size', 'vec-el',
  'vec-size', 'write',
];
for (const leaf of USED) assert.ok(leaves.has(leaf), `host leaf ${leaf} is missing`);
console.log(`PASS quoted-view host ABI: ${USED.length} leaves present`);

// ── the build's numeric-gate artifact, when the build wrote it ────────────────
if (existsSync(gatePath)) {
  const gate = JSON.parse(readFileSync(gatePath, 'utf8'));
  assert.equal(gate.bundle, 'quoted-view.mjs');
  assert.ok(Number.isInteger(gate.counts.raw) && Number.isInteger(gate.counts.checked));
  console.log(
    `PASS quoted-view numeric gate: ${gate.counts.raw} raw / ${gate.counts.checked} checked`
  );
}

console.log('js-actors: QUOTED-VIEW PASS');
