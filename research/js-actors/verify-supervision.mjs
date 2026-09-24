// verify-supervision.mjs — focused verifier for the FEAT-051 slice (portable
// SUPERVISION TREES: the `proc.super/defsupervisor` lowering in compiler.bl and
// the supervisor actor in runtime.bl).
//
// The JavaScript here is a TEST RUNNER, a BUNDLE READER and an ORACLE. It
// defines no supervisor policy: it never starts a child, never picks a restart
// set and never inspects the runtime's ledger except through the BL verbs the
// bundle exposes. Five independent checks:
//
//   1. BUDGETS. The shipped acceptance suite runs at the default actor budget,
//      at 17 steps and at 41 steps. Every supervisor decision is made inside one
//      BL turn, and a turn can be sliced; the suite asserts the same tree
//      behaviour on every budget, so an interleaving that only works at the
//      default budget fails here.
//
//   2. THE CHECKS THEMSELVES. Every acceptance check the FEAT-051 section of
//      test.bl declares is READ OFF test.bl by marker and required to have
//      passed, so adding a case to the suite adds it here and removing one
//      cannot quietly shrink the coverage.
//
//   3. THE BUILD. The generated bundle must carry the LOWERED tree
//      constructors as real target globals, and must contain no reference to the
//      native supervisor module: a declaration lowered for this target is
//      compiled BL, not a call into the BEAM.
//
//   4. THE APPLICATION. `out/super-demo.mjs` is driven through the browser input
//      boundary: it reports its tree, a crash produces a NEW child incarnation
//      with a charged restart, the app keeps accepting messages afterwards, and
//      it stops gracefully. Browser page suspension means wall-clock parity is
//      not claimed — the driver enqueues events and reads the BL transcript.
//
//   5. THE NATIVE-BEAM DIFFERENTIAL. For the same rules, real BEAM (OTP) answers
//      the same ten predicates: which children a strategy restarts, which child
//      policies restart on a normal exit or a crash, and whether an exhausted
//      intensity window takes the supervisor down. Only the RULES are compared —
//      this target's escalation reason is a vector, OTP's is `:shutdown` — and
//      the shapes are explicitly not claimed equal.
//
// Run after compiler.bl, next to the generated bundles:
//   node research/js-actors/verify-supervision.mjs
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

assert.equal(tinyRun.checks, defaultRun.checks, 'the 17-step budget ran a different number of checks');
assert.equal(smallRun.checks, defaultRun.checks, 'the 41-step budget ran a different number of checks');
console.log(`PASS supervision suite at the default, 17-step and 41-step budgets: ${defaultRun.checks} BL checks each`);

// ── 2. every declared FEAT-051 check ran and passed ────────────────────────

const testSource = readFileSync(new URL('./test.bl', import.meta.url), 'utf8');
const sectionStart = testSource.indexOf('; ── FEAT-051');
const sectionEnd = testSource.indexOf('(defn run-all');
assert.ok(sectionStart > 0 && sectionEnd > sectionStart, 'the FEAT-051 section of test.bl was not found');
const declared = [...testSource.slice(sectionStart, sectionEnd).matchAll(/\["([a-z0-9][a-z0-9-]*)"/g)]
  .map((m) => m[1]);
assert.ok(declared.length >= 60,
  `only ${declared.length} supervision checks are declared — the slice is smaller than it reads`);
const passed = new Set(defaultRun.stdout.split('\n')
  .filter((line) => line.startsWith('PASS '))
  .map((line) => line.slice(5).trim()));
const missing = declared.filter((name) => !passed.has(name));
assert.deepEqual(missing, [], `declared checks never passed: ${missing.join(', ')}`);
console.log(`PASS every one of ${declared.length} declared supervision checks passed`);

// ── 3. the bundle carries the lowered trees, and no native supervisor call ──

const bundle = readFileSync(new URL('./out/bundle.mjs', import.meta.url), 'utf8');
for (const name of ['sup-tree-one-for-one', 'sup-tree-rest-for-one', 'sup-tree-one-for-all',
  'sup-tree-storm', 'sup-tree-named', 'sup-tree-options', 'sup-worker']) {
  assert.ok(bundle.includes(`H.def(rt, "js/${name}",`),
    `the bundle has no target global for the lowered tree part ${name}`);
}
assert.doesNotMatch(bundle, /BeamLisp\.Supervisor/,
  'the bundle reaches the native supervisor module — the declaration was not lowered for this target');
console.log('PASS the defsupervisor declarations lowered to target globals, with no native supervisor call');

// ── 4. the supervision application, driven through the browser boundary ─────

const demoSource = `
  import * as H from './host.mjs';
  const originalLog = console.log;
  console.log = (...args) => {
    originalLog(...args);
    const line = args.join(' ');
    if (line.startsWith('BL supervisor ready')) setTimeout(() => H.enqueueInput('crash', 'worker'), 10);
    if (line.startsWith('BL supervisor ledger after crash:'))
      setTimeout(() => H.enqueueInput('send', 'after restart'), 10);
    if (line.startsWith('BL supervisor app received #2'))
      setTimeout(() => H.enqueueInput('stop', 'done'), 10);
  };
  H.enqueueInput('send', 'before boot');
  await import('./out/super-demo.mjs');
`;
const demo = spawnSync(process.execPath, ['--input-type=module', '-e', demoSource], {
  cwd, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024,
});
assert.ifError(demo.error);
assert.equal(demo.status, 0, demo.stdout + demo.stderr);
assert.doesNotMatch(demo.stdout, /BL supervisor escalated/,
  'the supervision application escalated, which it must not in this transcript');

const expected = [
  'BL supervisor app received #1: before boot',
  'BL monitor DOWN child',
  'BL supervisor ledger after crash:',
  'BL supervisor app received #2: after restart; named child replied',
  'BL supervisor app stopped after 2 message(s): done',
];
// The app queues `before boot` first, then the ready line, then the crash. The
// transcript must show the crash's ledger AFTER the first receive and BEFORE
// the messages that follow the restart.
const ready = demo.stdout.indexOf('BL supervisor ready');
assert.ok(ready >= 0, `the app never reported its tree:\n${demo.stdout}`);
let previous = ready;
for (const line of expected) {
  const next = demo.stdout.indexOf(line);
  assert.ok(next > previous, `missing/out-of-order ${line}:\n${demo.stdout}`);
  previous = next;
}
const downLines = demo.stdout.split('\n').filter((line) => line.startsWith('BL monitor DOWN child'));
assert.equal(downLines.length, 1, `child death must produce exactly one app monitor DOWN:\n${demo.stdout}`);
assert.match(downLines[0], /reason \[:demo-crash :worker\]/);
assert.match(demo.stdout, /named child replied \[:pong :worker "after restart"\]/,
  'the browser message did not resolve the restarted child by its BL name');
const ledgerLine = demo.stdout.split('\n').find((line) => line.startsWith('BL supervisor ledger after crash:'));
assert.match(ledgerLine, /strategy=:one-for-one/, `the ledger lost the tree's strategy: ${ledgerLine}`);
assert.match(ledgerLine, /window-restarts=1/, `the crash was not charged once: ${ledgerLine}`);
assert.match(ledgerLine, /total=1/, `the crash was not charged once in total: ${ledgerLine}`);
assert.match(ledgerLine, /:worker=running\(pid \[:pid \d+ \d+\], restarts 1\)/,
  `the child was not restarted with a charged restart: ${ledgerLine}`);
const pids = [...demo.stdout.matchAll(/pid \[:pid (\d+) (\d+)\]/g)].map((m) => m[1] + ':' + m[2]);
assert.ok(pids.length >= 2, `the transcript carries fewer than two child incarnations:\n${demo.stdout}`);
assert.notEqual(pids[1], pids[0],
  'the child kept its pid across the crash — the tree did not start a fresh incarnation');
console.log('PASS super-demo.mjs: ledger, fresh incarnation after a crash, continued service and graceful stop');

// ── 5. the same rules, answered by real BEAM ───────────────────────────────

function parseParity(text) {
  const out = {};
  for (const line of text.split('\n')) {
    const m = line.match(/^SUP-PARITY ([a-z-]+) (\S+)$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

const PARITY_KEYS = [
  'one-for-one-others-stable', 'one-for-one-dead-changed', 'one-for-all-all-changed',
  'rest-for-one-first-all-changed', 'rest-for-one-last-only-changed',
  'transient-crash-restarted', 'transient-normal-not-restarted',
  'temporary-crash-not-restarted', 'permanent-normal-restarted', 'max-restarts-escalates',
];

function parseTrace(text) {
  return text.split('\n')
    .map((line) => line.match(/^SUP-TRACE (\d+) (\w+) (\w+) (\w+)$/))
    .filter((m) => m !== null)
    .map((m) => `${m[1]}:${m[2]} ${m[3]} ${m[4]}`);
}

const blTrace = parseTrace(defaultRun.stdout);
assert.deepEqual(blTrace, ['1:changed changed changed', '2:same same changed'],
  `the BL rest-for-one trace is not the expected two steps: ${JSON.stringify(blTrace)}`);

const blParity = parseParity(defaultRun.stdout);
for (const key of PARITY_KEYS) {
  assert.equal(blParity[key], 'true', `the BL run did not report SUP-PARITY ${key} true`);
}
assert.equal(Object.keys(blParity).length, PARITY_KEYS.length,
  `the BL run printed an unexpected parity table: ${JSON.stringify(blParity)}`);

const BEAM_SUPERVISION = `
defmodule SW do
  use GenServer
  def start_link(tag), do: GenServer.start_link(__MODULE__, tag)
  def init(tag), do: {:ok, tag}
  def handle_cast(:crash, _tag), do: exit(:crash)
  def handle_cast(:exit_normal, _tag), do: {:stop, :normal, nil}
end

defmodule SUP do
  def child(id, restart \\\\ :permanent), do: Supervisor.child_spec({SW, id}, id: id, restart: restart)
  def pids(sup), do: Map.new(Supervisor.which_children(sup), fn {id, pid, _, _} -> {id, pid} end)
  def settle, do: Process.sleep(60)
  def running?(p), do: is_pid(p) and Process.alive?(p)
  def cell(x, y), do: (if x == y, do: "same", else: "changed")
end

Process.flag(:trap_exit, true)

{:ok, s} = Supervisor.start_link([SUP.child(:a), SUP.child(:b), SUP.child(:c)], strategy: :one_for_one)
m0 = SUP.pids(s); Process.exit(m0[:b], :kill); SUP.settle(); m1 = SUP.pids(s)
IO.puts("SUP-PARITY one-for-one-others-stable #{m1[:a] == m0[:a] and m1[:c] == m0[:c]}")
IO.puts("SUP-PARITY one-for-one-dead-changed #{m1[:b] != m0[:b]}")

{:ok, f} = Supervisor.start_link([SUP.child(:a), SUP.child(:b), SUP.child(:c)], strategy: :one_for_all)
f0 = SUP.pids(f); Process.exit(f0[:b], :kill); SUP.settle(); f1 = SUP.pids(f)
IO.puts("SUP-PARITY one-for-all-all-changed #{f1[:a] != f0[:a] and f1[:b] != f0[:b] and f1[:c] != f0[:c]}")

{:ok, r} = Supervisor.start_link([SUP.child(:a), SUP.child(:b), SUP.child(:c)], strategy: :rest_for_one)
r0 = SUP.pids(r); Process.exit(r0[:a], :kill); SUP.settle(); r1 = SUP.pids(r)
IO.puts("SUP-PARITY rest-for-one-first-all-changed #{r1[:a] != r0[:a] and r1[:b] != r0[:b] and r1[:c] != r0[:c]}")
Process.exit(r1[:c], :kill); SUP.settle(); r2 = SUP.pids(r)
IO.puts("SUP-PARITY rest-for-one-last-only-changed #{r2[:a] == r1[:a] and r2[:b] == r1[:b] and r2[:c] != r1[:c]}")

{:ok, t} = Supervisor.start_link([SUP.child(:t, :transient)], strategy: :one_for_one)
t0 = SUP.pids(t); Process.exit(t0[:t], :kill); SUP.settle(); t1 = SUP.pids(t)
IO.puts("SUP-PARITY transient-crash-restarted #{SUP.running?(t1[:t]) and t1[:t] != t0[:t]}")
GenServer.cast(t1[:t], :exit_normal); SUP.settle(); t2 = SUP.pids(t)
IO.puts("SUP-PARITY transient-normal-not-restarted #{not SUP.running?(t2[:t])}")

{:ok, x} = Supervisor.start_link([SUP.child(:x, :temporary)], strategy: :one_for_one)
x0 = SUP.pids(x); Process.exit(x0[:x], :kill); SUP.settle(); x1 = SUP.pids(x)
IO.puts("SUP-PARITY temporary-crash-not-restarted #{not SUP.running?(x1[:x])}")

{:ok, p} = Supervisor.start_link([SUP.child(:p, :permanent)], strategy: :one_for_one)
p0 = SUP.pids(p); GenServer.cast(p0[:p], :exit_normal); SUP.settle(); p1 = SUP.pids(p)
IO.puts("SUP-PARITY permanent-normal-restarted #{SUP.running?(p1[:p]) and p1[:p] != p0[:p]}")

{:ok, m} = Supervisor.start_link([SUP.child(:s)], strategy: :one_for_one, max_restarts: 2, max_seconds: 60)
ref = Process.monitor(m)
for _ <- 1..5 do
  if Process.alive?(m) do
    case SUP.pids(m)[:s] do
      q when is_pid(q) -> Process.exit(q, :kill)
      _ -> :ok
    end
  end
  SUP.settle()
end
reason = receive do {:DOWN, ^ref, :process, _, rr} -> rr after 2000 -> :no_down end
IO.puts("SUP-PARITY max-restarts-escalates #{reason != :no_down}")

# The selected TRACE: rest_for_one, crash the first child then the last, and
# report per step which incarnations changed.
{:ok, tt} = Supervisor.start_link([SUP.child(:a), SUP.child(:b), SUP.child(:c)], strategy: :rest_for_one)
q0 = SUP.pids(tt)
Process.exit(q0[:a], :kill); SUP.settle(); q1 = SUP.pids(tt)
IO.puts("SUP-TRACE 1 #{SUP.cell(q0[:a], q1[:a])} #{SUP.cell(q0[:b], q1[:b])} #{SUP.cell(q0[:c], q1[:c])}")
Process.exit(q1[:c], :kill); SUP.settle(); q2 = SUP.pids(tt)
IO.puts("SUP-TRACE 2 #{SUP.cell(q1[:a], q2[:a])} #{SUP.cell(q1[:b], q2[:b])} #{SUP.cell(q1[:c], q2[:c])}")
`;

const oracle = spawnSync('elixir', ['-e', BEAM_SUPERVISION], { encoding: 'utf8', timeout: 180000 });
if (oracle.error && oracle.error.code === 'ENOENT') {
  console.log('SKIP supervision native-BEAM differential: elixir is not on PATH');
} else {
  assert.ifError(oracle.error);
  assert.equal(oracle.status, 0, `elixir supervision oracle failed:\n${oracle.stdout}${oracle.stderr}`);
  const beamParity = parseParity(oracle.stdout);
  assert.deepEqual(beamParity, blParity,
    'the BL supervision rules and native BEAM disagree (met: ' + JSON.stringify(blParity)
    + ', OTP: ' + JSON.stringify(beamParity) + ')');
  const beamTrace = parseTrace(oracle.stdout);
  assert.deepEqual(beamTrace, blTrace,
    'the BL and native-BEAM rest-for-one traces disagree (met: ' + JSON.stringify(blTrace)
    + ', OTP: ' + JSON.stringify(beamTrace) + ')');
  console.log(`PASS native-BEAM differential: ${PARITY_KEYS.length} supervision rules and the `
    + `${beamTrace.length}-step rest-for-one trace match OTP`);
}

console.log('js-actors: SUPERVISION PASS');
