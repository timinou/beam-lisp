// Adversarial runtime regressions using real compiled BL scheduler functions.
// The JS test harness only replaces the application entry, never the BL policy.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import * as H from './host.mjs';

const mode = process.argv[2];
if (mode) {
  const call = (rt, name, args = []) => new H.Step('call', {
    f: H.ref(rt, 'js', name), args,
  });
  const misses = () => H.kw('nomatch');
  const matches = () => H.vec([H.kw('match'), null]);
  let rt;
  let first = true;
  let waits = 0;
  let taskRan = false;
  let taskRanAtDeadline = false;
  let selected = false;
  const makeFrames = H.RT_HOST['make-frames'];
  const waitUntil = H.RT_HOST['wait-until'];
  H.RT_HOST['wait-until'] = (r, ms, inputs) => {
    waits++;
    if (waits === 1) setTimeout(() => { taskRan = true; }, 0);
    return waitUntil(r, ms, inputs);
  };
  const blocked = H.blFn('blocked', new Map([[0, function* (r) {
    yield call(r, 'rt-receive', [misses, () => null, null]);
  }]]), null);
  H.RT_HOST['make-frames'] = (r, f, args) => {
    rt = r;
    if (!first) return makeFrames(r, f, args);
    first = false;
    return [(function* () {
      if (mode === 'early') {
        const timeout = yield call(r, 'rt-receive', [misses, () => null, 70]);
        taskRanAtDeadline = taskRan;
        assert.equal(H.kwName(H.vecEl(timeout, 0)), 'timeout');
        yield call(r, 'rt-register-input!');
        const hit = yield call(r, 'rt-receive', [matches, () => null, null]);
        selected = H.kwName(H.vecEl(hit, 0)) === 'match';
      } else {
        yield call(r, 'rt-register-input!');
        yield call(r, 'rt-spawn', [blocked, H.vec([])]);
        if (mode === 'crash') throw new Error('injected registered sink crash');
      }
    })()];
  };
  H.enqueueInput('send', mode === 'early' ? 'retained-before-sink' : 'orphan');
  let outcome = 'done';
  try { await import('./out/demo.mjs'); }
  catch (error) { outcome = String(error.message); }
  const sink = H.mapGet(rt.state, H.kw('input-sink'));
  console.log(JSON.stringify({ mode, outcome, waits, taskRanAtDeadline, selected,
    sink, errors: rt.errors, pending: rt.inbox.length }));
  // The stale-sink case intentionally takes the scheduler's error branch.
  if (mode === 'stale' || mode === 'crash') process.exitCode = 0;
} else {
  // A fractional monotonic deadline must never be truncated by setTimeout:
  // that would wake the BL scheduler before expiry and make it sleep twice.
  const originalTimer = globalThis.setTimeout;
  let requestedDelay;
  try {
    globalThis.setTimeout = (fn, ms) => {
      requestedDelay = ms;
      return originalTimer(fn, 0);
    };
    await H.waitForInput(H.newRuntime(), 70.25, false);
    assert.equal(requestedDelay, 71);
  } finally {
    globalThis.setTimeout = originalTimer;
  }
  console.log('PASS fractional host deadline rounds upward');
  const script = fileURLToPath(import.meta.url);
  const run = (name) => {
    const result = spawnSync(process.execPath, [script, name], {
      encoding: 'utf8', timeout: 3000,
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const record = JSON.parse(result.stdout.trim().split('\n').at(-1));
    assert.equal(record.mode, name);
    return { record, stdout: result.stdout + result.stderr };
  };
  const early = run('early').record;
  assert.equal(early.outcome, 'done');
  assert.equal(early.waits, 1, 'unregistered input must not spin an idle deadline');
  assert.equal(early.taskRanAtDeadline, true, 'host tasks must run during BL sleep');
  assert.equal(early.selected, true, 'pre-registration input must remain deliverable');
  assert.equal(early.pending, 0);
  console.log('PASS pre-sink input sleeps, preserves FIFO and wakes after registration');

  const stale = run('stale');
  assert.match(stale.record.outcome, /recorded 1 error/);
  assert.equal(stale.record.sink, null, 'retiring actor must release its sink');
  assert.equal(stale.record.errors, 1, 'blocked peer must not be masked by stale sink');
  assert.equal(stale.record.pending, 1, 'orphan input must not be drained to dead pid');
  assert.doesNotMatch(stale.stdout, /send: no such process/);
  console.log('PASS retired sink cannot swallow input or mask blocked-peer error');

  const crashed = run('crash');
  assert.match(crashed.record.outcome, /recorded 2 error/);
  assert.equal(crashed.record.sink, null, 'crashed actor must release its sink');
  assert.equal(crashed.record.errors, 2, 'crash and blocked peer are both reported');
  assert.equal(crashed.record.pending, 1, 'crashed sink cannot consume orphan input');
  assert.doesNotMatch(crashed.stdout, /send: no such process/);
  console.log('PASS crashed sink releases registration and preserves scheduler errors');
}
