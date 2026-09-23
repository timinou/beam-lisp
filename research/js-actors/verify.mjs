// Run after compiler.bl. Node is only the test runner, not a runtime dependency.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import * as H from './host.mjs';

const cwd = new URL('.', import.meta.url);
function run(label, setup, expectedSuccess = true) {
  const source = `import * as H from './host.mjs';\n${setup}\nawait import('./out/bundle.mjs');`;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', source], {
    cwd, encoding: 'utf8', timeout: 120000, maxBuffer: 1024 * 1024,
  });
  assert.ifError(result.error);
  if (expectedSuccess) {
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /js-actors: ALL PASS/);
    assert.doesNotMatch(result.stdout, /^FAIL /m);
    const checks = result.stdout.split('\n').filter(line => line.startsWith('PASS ')).length;
    assert.ok(checks > 0);
    console.log(`PASS ${label}: ${checks} BL checks`);
  } else {
    assert.notEqual(result.status, 0, 'actor crash must fail the process');
    assert.match(result.stdout + result.stderr, /injected actor failure/);
    console.log(`PASS ${label}: nonzero exit`);
  }
}

assert.throws(() => H.arith('add', Number.MAX_SAFE_INTEGER, 1), /overflow/);
assert.equal(H.eq(H.vec([H.kw('x,k:y')]), H.vec([H.kw('x'), H.kw('y')])), false);
assert.notEqual(H.hashKey(H.kw('a')), H.hashKey('a'));
const rt = H.newRuntime();
assert.throws(() => H.hostRef(rt, 'park-release')(), /requires one/);
H.hostRef(rt, 'critical-enter')();
assert.throws(() => H.hostRef(rt, 'park')(), /critical section/);
assert.equal(H.hostRef(rt, 'park-release')().k, 'park');
assert.equal(rt.criticalDepth, 0);
console.log('PASS host numeric, structural-key and atomic-park boundaries');

run('default scheduling budget', '');
run('17-step actor budget', `
  const original = H.RT_HOST['run-turn'];
  H.RT_HOST['run-turn'] = (rt, frames) => original(rt, frames, 17);
`);
run('41-step actor budget', `
  const original = H.RT_HOST['run-turn'];
  H.RT_HOST['run-turn'] = (rt, frames) => original(rt, frames, 41);
`);
run('actor failure propagation', `
  H.RT_HOST['make-frames'] = () => [(function* () { throw new Error('injected actor failure'); })()];
`, false);
// Host wake primitive: an external event interrupts a pending deadline, without
// the JS adapter choosing a BL process or polling the queue.
const wake = H.waitForInput(rt, 2000);
setTimeout(() => H.enqueueInput('send', 'direct host wake'), 20);
await Promise.race([
  wake,
  new Promise((_, reject) => setTimeout(() => reject(new Error('host input failed to wake')), 1000)),
]);
assert.equal(H.hostRef(rt, 'input-size')(), 1);
const batch = H.hostRef(rt, 'take-input')();
assert.equal(H.vecItems(batch).length, 1);
assert.equal(H.vecItems(H.vecItems(batch)[0])[2], 'direct host wake');
assert.equal(H.hostRef(rt, 'input-size')(), 0);
assert.throws(() => H.enqueueInput('send', { unsafe: true }), /requires an allowed topic/);
assert.throws(() => H.enqueueInput('../bad', 'x'), /requires an allowed topic/);
for (let i = 0; i < 1024; i++) H.enqueueInput('send', String(i));
assert.throws(() => H.enqueueInput('send', 'overflow'), /queue is full/);
assert.equal(H.vecItems(H.hostRef(rt, 'take-input')()).length, 1024);
console.log('PASS host inbox wake, bounded FIFO drain and typed input boundary');

// Real BL actor integration: the first event predates runtime creation; the
// second interrupts a timed wait; the third follows the timer into an indefinite
// wait. Only BL demo.bl owns the recipient, mailbox matching and response text.
const demoSource = `
  import * as H from './host.mjs';
  H.enqueueInput('send', 'queued before boot');
  const originalLog = console.log;
  console.log = (...args) => {
    originalLog(...args);
    const line = args.join(' ');
    if (line.startsWith('BL actor ready')) setTimeout(() => H.enqueueInput('send', 'during timed wait'), 20);
    if (line.startsWith('BL timer completed')) setTimeout(() => H.enqueueInput('send', 'after timer'), 20);
    if (line.startsWith('BL actor received #3')) setTimeout(() => H.enqueueInput('stop', 'done'), 20);
  };
  await import('./out/demo.mjs');
`;
const demo = spawnSync(process.execPath, ['--input-type=module', '-e', demoSource], {
  cwd, encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024,
});
assert.ifError(demo.error);
assert.equal(demo.status, 0, demo.stdout + demo.stderr);
const expected = [
  'BL actor received #1: queued before boot',
  'BL actor received #2: during timed wait',
  'BL timer completed; input actor still waiting',
  'BL actor received #3: after timer',
  'BL actor stopped after 3 message(s)',
];
let previous = -1;
for (const line of expected) {
  const next = demo.stdout.indexOf(line);
  assert.ok(next > previous, `missing/out-of-order ${line}: ${demo.stdout}`);
  previous = next;
}
console.log('PASS BL inbox queued-before-boot, timed wake, indefinite wake and stop');

const stoppedEarly = spawnSync(process.execPath, ['--input-type=module', '-e', `
  import * as H from './host.mjs';
  H.enqueueInput('stop', 'before boot');
  await import('./out/demo.mjs');
`], { cwd, encoding: 'utf8', timeout: 3000 });
assert.ifError(stoppedEarly.error);
assert.equal(stoppedEarly.status, 0, stoppedEarly.stdout + stoppedEarly.stderr);
assert.match(stoppedEarly.stdout, /BL actor stopped after 0 message\(s\)/);
assert.doesNotMatch(stoppedEarly.stdout, /BL timer completed|send: no such process/);
console.log('PASS stop before boot cancels BL timer and completes promptly');

const edges = spawnSync(process.execPath, ['verify-inbox-edges.mjs'], {
  cwd, encoding: 'utf8', timeout: 10000,
});
assert.ifError(edges.error);
assert.equal(edges.status, 0, edges.stdout + edges.stderr);
process.stdout.write(edges.stdout);
console.log('js-actors: HARDENING PASS');
