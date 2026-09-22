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
console.log('js-actors: HARDENING PASS');
