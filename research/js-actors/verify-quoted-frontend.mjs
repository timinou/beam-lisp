// verify-quoted-frontend.mjs — the acceptance contract for the generated
// quoted-frontend bundle. Run after the targeted build (compiler.bl):
//   BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl
//   node research/js-actors/verify-quoted-frontend.mjs
//
// Node is the test RUNNER, never the runtime: it launches a child that imports
// the GENERATED BL bundle (`out/quoted-frontend.mjs`, built from
// runtime.bl + quoted-view-core.bl + quoted-frontend.bl) and reads its stdout.
// Every value asserted below is the compiled BL actor's own answer.
//
// WHAT IS ASSERTED, and why each half matters:
//   1. the FULL expected transcript: the initial frame (version "7"), the second
//      frame after an accepted :version "8", one typed REFUSED line per bad or
//      oversized wire and per unknown topic, and the STOP line — in order;
//   2. determinism — a second run is byte-identical;
//   3. fail-closed — every refusal is typed, contains NO rendered view and NO
//      accepted value, and no refusal line can masquerade as a QV-FRONT VIEW
//      line (the distinct prefix is what prevents a bad input from forging a
//      frame in a separate log entry);
//   4. clean termination — the child exits 0 with an empty stderr after the
//      pre-enqueued STOP, proving the actor ended the scheduler rather than
//      hanging;
//   5. no unchecked global references — every `H.ref(rt, ns, name)` in the
//      generated bundle resolves to a definition in the same namespace or in
//      `core`, exactly the resolution the host's `ref` performs at boot;
//   6. no JavaScript is constructed at runtime, and the host ABI the evaluator
//      is written against is present.
//
// THE INPUTS ARE ENQUEUED BEFORE THE IMPORT. The host holds early browser input
// until the bundle creates its runtime and the actor registers as the sink, so
// the very first events this actor sees are the ones below, in this order.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import * as H from './host.mjs';

const cwd = new URL('.', import.meta.url);
const bundlePath = new URL('./out/quoted-frontend.mjs', import.meta.url);
const gatePath = new URL('./out/numeric-gate.quoted-frontend.mjs.json', import.meta.url);

assert.ok(
  existsSync(bundlePath),
  'out/quoted-frontend.mjs is missing — run the targeted build first: ' +
    'BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl',
);

// The events, in the order the actor must answer them. `version "8"` is the one
// accepted wire; the rest are bad wires (non-canonical), one oversized wire, one
// unknown topic, and the STOP that terminates the actor.
const INPUTS = [
  ['version', '8'],
  ['version', '07'],
  ['version', '7.0'],
  ['version', '7e0'],
  ['version', '-7'],
  ['version', ''],
  // A wire that tries to forge a second log entry: a leading newline plus the
  // view prefix. `host/describe` must escape it onto the SAME refused line.
  ['version', '\nQV-FRONT VIEW'],
  ['version', '1'.repeat(20)],
  ['bogus', 'x'],
  ['stop', ''],
];

function runBundle() {
  const source = `
import * as H from './host.mjs';
const lines = [];
console.log = (...a) => lines.push(a.map(x => (typeof x === 'string' ? x : String(x))).join(' '));
for (const [topic, payload] of ${JSON.stringify(INPUTS)}) H.enqueueInput(topic, payload);
await import('./out/quoted-frontend.mjs');
process.stdout.write(lines.join('\\n') + (lines.length ? '\\n' : ''));
`;
  return spawnSync(process.execPath, ['--input-type=module', '-e', source], {
    cwd,
    encoding: 'utf8',
    timeout: 60000,
    maxBuffer: 4 * 1024 * 1024,
  });
}

// ── the expected transcript ───────────────────────────────────────────────────
//
// The ONE view the frontend renders, as the core's fixed template message, with
// the dynamic `:unread` field carrying the canonical version string. The view
// string is described exactly as the host renders a BL string, so the expected
// line is built the same way the bundle built it.
const FRAME = (version) =>
  'view{card("inbox"){heading(2,"Inbox") field(unread="' + version + '") ' +
  'button("Mark all read",increment) text("no unread mail")}}';

const viewLine = (version) => `QV-FRONT VIEW [:ok ${JSON.stringify(FRAME(version))}]`;

// `[:refused [:stale-version <wire> <expected>]]` and the two other typed
// reasons, described by the host. The expected successor after the accepted "8"
// is "9", so the bad wires are judged against it.
const staleLine = (wire, expected) =>
  `QV-FRONT REFUSED [:refused [:stale-version ${JSON.stringify(wire)} ${JSON.stringify(expected)}]]`;

const expected = [
  viewLine('7'),                                    // initial frame
  viewLine('8'),                                    // second frame after :version "8"
  staleLine('07', '9'),
  staleLine('7.0', '9'),
  staleLine('7e0', '9'),
  staleLine('-7', '9'),
  staleLine('', '9'),
  staleLine('\nQV-FRONT VIEW', '9'),
  'QV-FRONT REFUSED [:refused [:oversized-request 20]]',
  'QV-FRONT REFUSED [:refused [:unknown-topic :bogus]]',
  'QV-FRONT STOP',
];

// ── 1. the expected transcript ────────────────────────────────────────────────
const first = runBundle();
assert.ifError(first.error);
assert.equal(first.status, 0, first.stdout + first.stderr);
assert.equal(first.stderr, '', `bundle wrote to stderr: ${first.stderr}`);

const lines = first.stdout.split('\n').filter((line) => line.length > 0);
assert.deepEqual(lines, expected, 'generated frontend bundle transcript differs');
console.log(`PASS quoted-frontend transcript: ${lines.length} lines, exact`);

// ── 2. determinism ────────────────────────────────────────────────────────────
const second = runBundle();
assert.equal(second.status, 0, second.stdout + second.stderr);
assert.equal(second.stdout, first.stdout, 'transcript is not deterministic');
console.log('PASS quoted-frontend transcript is byte-identical across runs');

// ── 3. fail-closed: no partial view, and no refusal can forge a frame ─────────
const rendered = lines.filter((line) => line.startsWith('QV-FRONT VIEW '));
assert.equal(rendered.length, 2, `expected exactly two rendered frames, saw ${rendered.length}`);
assert.equal(rendered[0], viewLine('7'));
assert.equal(rendered[1], viewLine('8'));

const refused = lines.filter((line) => line.startsWith('QV-FRONT REFUSED '));
assert.equal(refused.length, INPUTS.length - 2, `expected one refusal per bad event, saw ${refused.length}`);
for (const line of refused) {
  assert.match(line, /^QV-FRONT REFUSED \[:refused \[/, `refusal is not typed: ${line}`);
  assert.doesNotMatch(line, /view\{/, `a refusal leaked a rendered view: ${line}`);
  assert.doesNotMatch(line, /\[:ok /, `a refusal carried an accepted value: ${line}`);
  assert.ok(!line.startsWith('QV-FRONT VIEW'), `a refusal forged a view line: ${line}`);
}
// The newline-forgery wire stays escaped on ONE refused line: it can neither
// split the log nor promote itself to a `QV-FRONT VIEW` entry.
const escapedAttempt = lines.filter((line) => line.startsWith('QV-FRONT REFUSED ') && line.includes('QV-FRONT VIEW'));
assert.equal(escapedAttempt.length, 1, 'the forged wire must stay on exactly one refused line');
assert.equal(lines.filter((line) => line.startsWith('QV-FRONT VIEW ')).length, 2);
// The static template carries no markup, and the frame is the accepted one.
assert.doesNotMatch(FRAME('7'), /[<>]/);
console.log(`PASS quoted-frontend fail-closed: ${refused.length} typed refusals, two frames, no partial view`);

// ── 4. clean termination ──────────────────────────────────────────────────────
// The STOP is the last event; if the actor had not ended the scheduler, the child
// would not exit and this assertion (with its timeout) would fail.
assert.equal(lines.at(-1), 'QV-FRONT STOP', 'the last actor line must be STOP');
assert.equal(first.status, 0, 'the actor did not terminate cleanly after STOP');
console.log('PASS quoted-frontend: actor terminates cleanly after STOP');

// ── 5. no unchecked global references ─────────────────────────────────────────
// The same resolution the host's `ref` performs: `ns/name`, else `core/name`.
// The compiler's build-time audit already refuses an unresolved global; this
// re-checks the GENERATED text so a regression in the emitter is visible here.
const bundleSource = readFileSync(bundlePath, 'utf8');
const defined = new Set(
  [...bundleSource.matchAll(/H\.def(?:Alias)?\(rt,\s*"([^"]+)"/g)].map((m) => m[1]),
);
const refs = [...bundleSource.matchAll(/H\.ref\(rt,\s*"([^"]+)",\s*"([^"]+)"\)/g)]
  .map((m) => [m[1], m[2]]);
const unchecked = new Set();
for (const [ns, name] of refs) {
  if (!defined.has(ns + '/' + name) && !defined.has('core/' + name)) unchecked.add(ns + '/' + name);
}
assert.deepEqual([...unchecked], [], `unchecked global references: ${[...unchecked].join(', ')}`);
assert.ok(refs.length > 0, 'the generated bundle has no global references to check');
console.log(`PASS quoted-frontend: ${refs.length} global references all resolve (no unchecked globals)`);

// ── 6. no runtime JavaScript construction, and the host ABI ───────────────────
assert.doesNotMatch(bundleSource, /\beval\s*\(/, 'generated bundle contains an eval call');
assert.doesNotMatch(bundleSource, /new\s+Function\s*\(/, 'generated bundle constructs a Function');
assert.match(bundleSource, /import \* as H from "\.\.\/host\.mjs";/);
console.log('PASS quoted-frontend bundle builds no JavaScript at runtime');

const leaves = new Set(H.hostNames());
const USED = ['arith', 'describe', 'eq', 'is-str', 'lt', 'str-cat', 'str-size', 'to-str', 'vec-el', 'write'];
for (const leaf of USED) assert.ok(leaves.has(leaf), `host leaf ${leaf} is missing`);
console.log(`PASS quoted-frontend host ABI: ${USED.length} leaves present`);

// ── the build's numeric-gate artifact, when the build wrote it ────────────────
if (existsSync(gatePath)) {
  const gate = JSON.parse(readFileSync(gatePath, 'utf8'));
  assert.equal(gate.bundle, 'quoted-frontend.mjs');
  assert.ok(Number.isInteger(gate.counts.raw) && Number.isInteger(gate.counts.checked));
  console.log(
    `PASS quoted-frontend numeric gate: ${gate.counts.raw} raw / ${gate.counts.checked} checked`,
  );
}

console.log('js-actors: QUOTED-FRONTEND PASS');
