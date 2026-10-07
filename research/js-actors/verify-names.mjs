// verify-names.mjs — focused verifier for the FEAT-050 slice (portable process
// NAMES and the correlated CALL protocol in runtime.bl + the `proc/defserver`
// lowering in compiler.bl).
//
// The JavaScript here is a TEST RUNNER, an ORACLE and a BUNDLE READER. It
// defines no actor policy: it never registers a name, never picks a recipient
// and never inspects a mailbox. Four independent checks:
//
//   1. BUDGETS. The shipped acceptance suite runs at the default actor budget,
//      at 17 steps and at 41 steps. The name table is mutated inside ONE
//      critical section (register/unregister/whereis and the death retraction),
//      so a slice boundary landing inside it would leave a name pointing at a
//      process that no longer exists — and the suite asserts the opposite on
//      every budget. 17/41 is the tightest pair `verify.mjs` established.
//
//   2. THE CHECKS THEMSELVES. Every acceptance check the FEAT-050 section of
//      test.bl declares is READ OFF test.bl by marker and required to have
//      passed — so adding a case to the suite adds it here, and removing one
//      cannot quietly shrink the coverage.
//
//   3. THE BUILD. The generated bundle must carry the LOWERED servers as real
//      target globals (`js/counter`, `js/counter__server_loop`, …) and must
//      contain no reference to the native `BeamLisp.Server`: a declaration
//      lowered for this target is compiled BL, not a call into the BEAM.
//
//   4. THE NATIVE-BEAM DIFFERENTIAL. For the same program, real BEAM answers
//      the same four predicates: a held name resolves; registering a held name
//      is REFUSED; a name is gone once its process is; an unanswered call is
//      BOUNDED. Only the RULES are compared — BEAM exits with a tuple, this
//      target with a vector — and the shapes are explicitly not claimed equal.
//
// Run after compiler.bl, next to the generated bundle:
//   node research/js-actors/verify-names.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const cwd = new URL('.', import.meta.url);

// ── 1. the acceptance suite, at three actor budgets ─────────────────────────

function budgetSource(budget) {
  if (budget === null) return `await import('./out/bundle.mjs');`;
  return `
import * as H from './host.mjs';
const original = H.RT_HOST['run-turn'];
H.RT_HOST['run-turn'] = (rt, frames) => original(rt, frames, ${budget});
await import('./out/bundle.mjs');
`;
}

function runBudget(label, budget) {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', budgetSource(budget)], {
    cwd, encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
  });
  assert.ifError(result.error);
  const out = result.stdout + result.stderr;
  assert.equal(result.status, 0, `${label} failed:\n${out}`);
  assert.match(result.stdout, /js-actors: ALL PASS/, `${label} did not reach ALL PASS:\n${out}`);
  assert.doesNotMatch(result.stdout, /^FAIL /m, `${label} reported a failed check:\n${out}`);
  const checks = result.stdout.split('\n').filter((line) => line.startsWith('PASS ')).length;
  assert.ok(checks > 0, `${label} ran no checks`);
  return { stdout: result.stdout, checks };
}

const defaultRun = runBudget('default actor budget', null);
const tinyRun = runBudget('17-step actor budget', 17);
const smallRun = runBudget('41-step actor budget', 41);

// The suite must run the SAME number of checks at every budget: a budget that
// silently skips cases would hide exactly the interleavings it exists to find.
assert.equal(tinyRun.checks, defaultRun.checks, 'the 17-step budget ran a different number of checks');
assert.equal(smallRun.checks, defaultRun.checks, 'the 41-step budget ran a different number of checks');
console.log(`PASS name/call suite at the default, 17-step and 41-step budgets: ${defaultRun.checks} BL checks each`);

// ── 2. every declared FEAT-050 check ran and passed ────────────────────────

const testSource = readFileSync(new URL('./test.bl', import.meta.url), 'utf8');
const sectionStart = testSource.indexOf('; ── FEAT-050');
const sectionEnd = testSource.indexOf('(defn run-all');
assert.ok(sectionStart > 0 && sectionEnd > sectionStart, 'the FEAT-050 section of test.bl was not found');
const declared = [...testSource.slice(sectionStart, sectionEnd).matchAll(/\["([a-z0-9][a-z0-9-]*)"/g)]
  .map((m) => m[1]);
assert.ok(declared.length >= 40,
  `only ${declared.length} name/call checks are declared — the slice is smaller than it reads`);
const passed = new Set(defaultRun.stdout.split('\n')
  .filter((line) => line.startsWith('PASS '))
  .map((line) => line.slice(5).trim()));
const missing = declared.filter((name) => !passed.has(name));
assert.deepEqual(missing, [], `declared checks never passed: ${missing.join(', ')}`);

// The `terminate` clause of a lowered server runs on stop — the one observable
// a `[:stop …]` arm produces before the process ends with its reason.
assert.match(defaultRun.stdout, /^SRVTRACE terminate :normal$/m,
  'the lowered server never ran its terminate clause');
console.log(`PASS every one of ${declared.length} declared name/call checks passed (and terminate ran on stop)`);

// ── 3. the bundle carries the lowered servers, and no native server call ────

const bundle = readFileSync(new URL('./out/bundle.mjs', import.meta.url), 'utf8');
for (const name of ['counter', 'ping-srv', 'crasher']) {
  assert.ok(bundle.includes(`H.def(rt, "js/${name}"`),
    `the bundle has no entry defn for the lowered server ${name}`);
  assert.ok(bundle.includes(`H.def(rt, "js/${name}__server_loop"`),
    `the bundle has no server loop for the lowered server ${name}`);
}
assert.doesNotMatch(bundle, /BeamLisp\.Server/,
  'the bundle reaches the native server module — the declaration was not lowered for this target');
console.log('PASS the three defserver declarations lowered to target globals, with no native server call');

// ── 4. the same four rules, answered by real BEAM ──────────────────────────

function parseParity(text) {
  const out = {};
  for (const line of text.split('\n')) {
    const m = line.match(/^NAMES-PARITY ([a-z-]+) (\S+)$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

const BEAM_NAMES = `
parent = self()
holder = spawn(fn ->
  Process.register(self(), :parity_srv)
  send(parent, :parity_ready)
  receive do :die -> :ok end
end)
receive do :parity_ready -> :ok after 2000 -> :ok end
mref = Process.monitor(holder)
whereis_live = case Process.whereis(:parity_srv) do nil -> "nil"; _ -> "pid" end
double = try do
    Process.register(self(), :parity_srv)
    "accepted"
  catch
    _, _ -> "refused"
  end
send(holder, :die)
receive do {:DOWN, ^mref, :process, _, _} -> :ok after 2000 -> :ok end
whereis_dead = case Process.whereis(:parity_srv) do nil -> "nil"; _ -> "pid" end
bounded = try do
    GenServer.call(spawn(fn -> receive do :never -> :ok end end), :x, 30)
    "answered"
  catch
    :exit, _ -> "exits"
  end
IO.puts("NAMES-PARITY whereis-live " <> whereis_live)
IO.puts("NAMES-PARITY double-register " <> double)
IO.puts("NAMES-PARITY whereis-dead " <> whereis_dead)
IO.puts("NAMES-PARITY call-bounded " <> bounded)
`;

const blParity = parseParity(defaultRun.stdout);
assert.equal(Object.keys(blParity).length, 4, `the BL run printed an incomplete parity table: ${JSON.stringify(blParity)}`);
assert.equal(blParity['whereis-live'], 'pid');
assert.equal(blParity['double-register'], 'refused');
assert.equal(blParity['whereis-dead'], 'nil');
assert.equal(blParity['call-bounded'], 'exits');

const oracle = spawnSync('elixir', ['-e', BEAM_NAMES], { encoding: 'utf8', timeout: 120000 });
if (oracle.error && oracle.error.code === 'ENOENT') {
  console.log('SKIP names native-BEAM differential: elixir is not on PATH');
} else {
  assert.ifError(oracle.error);
  assert.equal(oracle.status, 0, `elixir names oracle failed:\n${oracle.stdout}${oracle.stderr}`);
  const beamParity = parseParity(oracle.stdout);
  assert.deepEqual(beamParity, blParity,
    'the BL name/call rules and native BEAM disagree (met: ' + JSON.stringify(blParity)
    + ', OTP: ' + JSON.stringify(beamParity) + ')');
  console.log('PASS native-BEAM differential: 4 name/call rules match OTP');
}

console.log('js-actors: NAMES PASS');
