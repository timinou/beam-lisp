// verify-trace.mjs — focused verifier for the logical source-frame slice
// (FEAT-048: reader spans → call-site metadata → runTurn's frame stack →
// BLRaise raw trace → the runtime's rendered failure location).
//
// It defines no actor policy and no source parser. Three independent children:
//
//   1. MECHANISM (host only, no bundle). A raise built with NO trace captures
//      the machine's live logical stack ONCE, so `:erlang/element(2,
//      __STACKTRACE__)` answers a frame list; a raise carrying an EXPLICIT
//      trace keeps it verbatim (a re-raise preserves the original location); a
//      LATER raise captures its OWN stack (a finalizer throw supersedes); an
//      unknown position is an explicit null, never a dropped frame; and the
//      list is capped. Nothing here parses a JavaScript Error.
//
//   2. SUITE (the compiled bundle). The FEAT-048 BL tests run as shipped —
//      f→g, a higher-order dynamic call, a parked timed receive, a typed catch
//      and a typed-catch fallthrough, a nested finalizer override, and a 50k
//      tail loop that must keep the stored stack bounded.
//
//   3. RENDER (the compiled bundle, one dying entry per child). A process that
//      dies uncaught must print a human-readable `file:line:col in fn/arity`
//      from its logical frames — the ORIGINAL raise site through a fallthrough
//      re-raise, and the FINALIZER's site when a finalizer throw supersedes.
//      The expected lines are READ OFF test.bl by marker, not hard-coded.
//
// No BEAM parity is claimed: these are the prototype's own logical frames, not
// native stacktrace frames, and the verifier never pretends otherwise.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const cwd = new URL('.', import.meta.url);
const script = fileURLToPath(import.meta.url);
const mode = process.argv[2];

// ── 1. the mechanism child: host.mjs only ────────────────────────────────────

function mechanismSource() {
  return `
import * as H from './host.mjs';
const rt = H.newRuntime();
const S = (file, line, fn, arity, call) => ({ file, line, col: 1, fn, arity, call });
const proj = fl => H.listToArray(fl).map(f => ({
  file: H.mapGet(f, H.kw('file')), line: H.mapGet(f, H.kw('line')),
  fn: H.mapGet(f, H.kw('fn')), arity: H.mapGet(f, H.kw('arity')),
  call: (() => { const c = H.mapGet(f, H.kw('call')); return c === null ? null : H.kwName(c); })(),
}));
const out = {};
const call = (target, src) => ({ __step: true, k: 'call', f: target, args: [], ...(src === undefined ? {} : { src }) });

function* deep() {
  try { H.ERLANG.raise(H.kw('error'), 'boom', null); }
  catch (e) { out.captured = proj(H.ERLANG.element(2, H.exTrace(e))); }
  out.live = proj(H.RT_HOST['logical-stack'](rt));
  // An explicit trace (a re-raise carrying its __STACKTRACE__) is preserved.
  const explicit = H.listFromArray([
    H.bmap([[H.kw('file'), 'orig.bl'], [H.kw('line'), 42], [H.kw('fn'), 'g']]),
  ]);
  const reused = new H.BLRaise(H.kw('error'), 'x', new H.T([H.ENIL, explicit]));
  out.preserved = H.ERLANG.element(2, H.exTrace(reused)) === explicit;
  // A LATER raise, deeper still, captures its OWN stack: supersession is just
  // "each new envelope captures at construction".
  const deep2 = yield call(deeper, S('later.bl', 11, 'deep', 0, 'call'));
  out.later = proj(deep2);
  return null;
}
let deeper;
function* deepTwo() {
  try { H.ERLANG.raise(H.kw('error'), 'later', null); }
  catch (e) { return H.ERLANG.element(2, H.exTrace(e)); }
}
deeper = H.blFn('deeper', new Map([[0, deepTwo]]), null);
const deepFn = H.blFn('deep', new Map([[0, deep]]), null);
const mid = H.blFn('mid', new Map([[0, function* () { return yield call(deepFn, S('synthetic.bl', 7, 'f', 1, 'direct')); }]]), null);
const leaf = H.blFn('leaf', new Map([[0, function* () { return yield call(mid); }]]), null);
const root = H.blFn('root', new Map([[0, function* () { return yield call(leaf); }]]), null);

const frames = [H.resolveCallee(root, [])(rt, [])];
frames.__srcs = [S('entry.bl', 1, 'entry', 0, 'tail')];
const r = H.runTurn(rt, frames, 100000);
out.status = H.kwName(H.mapGet(r, H.kw('status')));

// A native tail leaf can throw before any new generator frame is pushed. Its
// call-site, not the preceding loop/entry site, must be the innermost frame.
const native = H.blFn('native', new Map([[0, function* () {
  yield { __step: true, k: 'tail', f: () => { throw new Error('native failure'); },
    args: [], src: S('native.bl', 12, 'native', 0, 'tail') };
}]]), null);
const nf = [H.resolveCallee(native, [])(rt, [])];
nf.__srcs = [S('entry.bl', 2, 'entry', 0, 'call')];
const nr = H.runTurn(rt, nf, 1000);
out.nativeStatus = H.kwName(H.mapGet(nr, H.kw('status')));
out.native = proj(H.mapGet(nr, H.kw('frames')));

// The cap: no matter how deep the machine's stack, at most MAX_TRACE frames.
const fake = new Array(200);
fake.__srcs = new Array(200).fill(S('deep.bl', 9, 'x', 0, 'call'));
out.capped = H.listToArray(H.frameValues(fake)).length;
out.cappedKnown = H.listToArray(H.frameValues(fake)).every(f => H.mapGet(f, H.kw('file')) === 'deep.bl');
console.log('TRACE-MECHANISM ' + JSON.stringify(out));
`;
}

function runMechanism() {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', mechanismSource()], {
    cwd, encoding: 'utf8', timeout: 120000, maxBuffer: 4 * 1024 * 1024,
  });
  assert.ifError(result.error);
  const line = result.stdout.split('\n').filter(l => l.startsWith('TRACE-MECHANISM ')).pop();
  assert.ok(line, `no mechanism record: ${result.stdout}${result.stderr}`);
  const out = JSON.parse(line.slice('TRACE-MECHANISM '.length));
  assert.equal(out.status, 'done', 'the probe turn did not finish');
  assert.equal(out.nativeStatus, 'error', 'the native probe did not fail');
  assert.deepEqual(out.native[0],
    { file: 'native.bl', line: 12, fn: 'native', arity: 0, call: 'tail' },
    'native leaf failure lost its tail call-site');

  // Innermost-first, four frames: deep (known) ← mid (known) ← leaf (UNKNOWN) ← root.
  assert.equal(out.captured.length, 4, `captured ${out.captured.length} frames, want 4`);
  assert.deepEqual(out.captured[0],
    { file: 'synthetic.bl', line: 7, fn: 'f', arity: 1, call: 'direct' }, 'innermost frame is the callee call site');
  // An unknown position is EXPLICIT: null fields, the frame still present.
  assert.deepEqual(out.captured[1],
    { file: null, line: null, fn: null, arity: null, call: null }, 'an unknown frame stays visible, not dropped');
  assert.deepEqual(out.captured[3],
    { file: 'entry.bl', line: 1, fn: 'entry', arity: 0, call: 'tail' }, 'the outermost recorded frame is the entry call site');
  // The introspection leaf answers the SAME stack a new raise captures.
  assert.deepEqual(out.live, out.captured, 'host/logical-stack disagrees with the captured trace');
  // Rethrow: the explicit trace survives untouched.
  assert.equal(out.preserved, true, 'an explicit trace was not preserved on re-raise');
  // New envelope, deeper stack: supersession by fresh capture.
  assert.equal(out.later.length, out.captured.length + 1, 'a later raise captured the wrong depth');
  assert.equal(out.later[0].fn, 'deep', 'the later raise did not capture from its own stack');
  // Bound.
  assert.equal(out.capped, 64, `trace cap is ${out.capped}, want 64`);
  assert.equal(out.cappedKnown, true, 'the capped list lost frames');
  console.log(`PASS trace mechanism: ${out.captured.length}-frame stack, explicit trace preserved, later raise recaptures at depth ${out.later.length}, capped at ${out.capped}`);
}

// ── 2/3. the bundle children ─────────────────────────────────────────────────

/** Run the compiled bundle. `entry` (when given) replaces the program entry with
 *  a named BL function from test.bl, so its uncaught death is observed. */
function runBundle(entry, timeout = 180000) {
  const source = entry ? `
import * as H from './host.mjs';
const original = H.RT_HOST['make-frames'];
H.RT_HOST['make-frames'] = (rt, f, args) => f === H.ref(rt, 'js', 'entry')
  ? [H.resolveCallee(H.ref(rt, 'js', '${entry}'), [])(rt, [])]
  : original(rt, f, args);
try { await import('./out/bundle.mjs'); } catch (error) { console.log('ENTRY-THREW ' + error.message); }
` : `await import('./out/bundle.mjs');`;
  return spawnSync(process.execPath, ['--input-type=module', '-e', source], {
    cwd, encoding: 'utf8', timeout, maxBuffer: 8 * 1024 * 1024,
  });
}

function runSuite() {
  const result = runBundle(null);
  assert.ifError(result.error);
  assert.equal(result.status, 0, `the BL suite failed:\n${result.stdout}${result.stderr}`);
  assert.match(result.stdout, /^js-actors: ALL PASS$/m);
  assert.doesNotMatch(result.stdout, /^FAIL /m);
  const checks = result.stdout.split('\n').filter(l => l.startsWith('PASS trace-'));
  assert.ok(checks.length >= 20, `only ${checks.length} trace checks ran`);
  console.log(`PASS trace suite: ${checks.length} FEAT-048 BL checks among the shipped acceptance suite`);
}

/** The 1-indexed source line of the first line of test.bl containing `marker`. */
function lineOf(marker) {
  const src = readFileSync(new URL('test.bl', cwd), 'utf8').split('\n');
  const idx = src.findIndex(l => l.includes(marker));
  assert.ok(idx >= 0, `marker not found in test.bl: ${marker}`);
  return idx + 1;
}

/** The first `  at FILE:LINE:COL in FN/ARITY` line of the rendered failure. */
function firstAt(stdout) {
  const m = stdout.split('\n').find(l => l.trimStart().startsWith('at '));
  assert.ok(m, `no rendered source location in stdout:\n${stdout}`);
  return m.trim();
}

const BOOM = ':trace-boom-throw';
const CLEANUP = ':trace-cleanup-throw';

function runRender(name) {
  const result = runBundle(name);
  assert.ifError(result.error);
  assert.notEqual(result.status, 0, `${name} must die uncaught and fail the batch`);
  assert.match(result.stdout, /actor runtime: 1 error\(s\) recorded/);
  // A human-readable source location must be VISIBLE on stdout.
  assert.match(result.stdout, /research\/js-actors\/test\.bl:\d+:\d+/,
    `no visible source location for ${name}:\n${result.stdout}`);
  const at = firstAt(result.stdout);

  if (name === 'trace-die-direct' || name === 'trace-die-rethrow') {
    // The ORIGINAL throw site. For the rethrow child this is the discriminator:
    // a non-preserving capture would name trace-die-rethrow's own catch line.
    const want = `research/js-actors/test.bl:${lineOf(BOOM)}:`;
    assert.ok(at.includes(want), `${name}: first frame is "${at}", want ${want}`);
    assert.match(at, /in trace-boom\/0$/, `${name}: wrong function in "${at}"`);
    assert.doesNotMatch(result.stdout, /in trace-die-rethrow/,
      `${name}: the re-raise replaced the preserved original location`);
  } else if (name === 'trace-die-finalizer') {
    // The finalizer's throw SUPERSEDES the pending body error, location and all.
    const cleanupLine = lineOf(CLEANUP);
    assert.ok(at.includes(`research/js-actors/test.bl:${cleanupLine}:`),
      `${name}: first frame is "${at}", want the finalizer's line ${cleanupLine}`);
    assert.match(at, /in trace-cleanup\/0$/, `${name}: wrong function in "${at}"`);
    assert.doesNotMatch(result.stdout, new RegExp(`test\\.bl:${lineOf(BOOM)}:`),
      `${name}: the superseded body raise leaked into the rendered trace`);
  } else {
    throw new Error('unknown render child ' + name);
  }
  console.log(`PASS trace render ${name}: ${at}`);
}

function runBrowserTrace() {
  const result = spawnSync(process.execPath, ['./out/trace-demo.mjs'], {
    cwd, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024,
  });
  assert.ifError(result.error);
  assert.notEqual(result.status, 0, 'the deliberately failing BL app returned successfully');
  const text = result.stdout + result.stderr;
  assert.match(text, /deliberate BL source failure/);
  assert.match(text, /research\/js-actors\/trace-demo\.bl:\d+:\d+ in trace-demo-leaf\/0/,
    'the browser app did not render its BL source site');
  console.log('PASS browser trace app: deliberate BL failure shows trace-demo.bl source location');
}

// ── driver ───────────────────────────────────────────────────────────────────

if (mode === 'child-mechanism') {
  runMechanism();
} else if (mode === 'child-suite') {
  runSuite();
} else if (mode === 'child-direct') {
  runRender('trace-die-direct');
} else if (mode === 'child-rethrow') {
  runRender('trace-die-rethrow');
} else if (mode === 'child-finalizer') {
  runRender('trace-die-finalizer');
} else if (mode === 'child-browser') {
  runBrowserTrace();
} else {
  // The parent: isolated children, each with its own process and runtime.
  const spawn = name => {
    const child = spawnSync(process.execPath, [script, name], { encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024 });
    assert.ifError(child.error);
    assert.equal(child.status, 0, `${name} failed:\n${child.stdout}${child.stderr}`);
    process.stdout.write(child.stdout);
  };
  spawn('child-mechanism');
  spawn('child-suite');
  spawn('child-direct');
  spawn('child-rethrow');
  spawn('child-finalizer');
  spawn('child-browser');
  console.log('js-actors: TRACE PASS');
}
