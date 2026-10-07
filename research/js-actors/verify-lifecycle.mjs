// verify-lifecycle.mjs — focused verifier for the BL process-lifecycle slice
// (typed pids/refs, links, monitors, exit signals, trap_exit and the one atomic
// death cleanup in runtime.bl).
//
// The JavaScript here is a TEST RUNNER and a SAMPLER of the BL runtime's own
// state. It defines no actor policy: it never picks a recipient, never decides
// what a death means, and never touches a mailbox. What it does do is hostile:
//
//   1. the default actor budget, so the lifecycle actors run as shipped;
//   2. a TINY actor budget, so scheduler slice boundaries fall INSIDE the
//      death cleanup. `rt-terminate!` is one critical section, so the machine
//      must defer those boundaries; if it ever stops doing that, this run sees
//      a runnable entry or an input sink naming a process that no longer
//      exists. That invariant is sampled at EVERY boundary, not just the end
//      state, and the run counts how many processes stopped existing while the
//      scheduler was preempting.
//
//      17 steps is the tightest budget the suite can sustain: the pre-existing
//      fairness check insists that a 60,000-iteration CPU peer finishes inside
//      an 8-second deadline, and that bound is host WAKUPS, not BL — at a
//      single-digit budget the host cannot deliver 20k+ slices in time, so the
//      check misses its deadline for reasons that have nothing to do with the
//      lifecycle. That is a property of the older test, reported rather than
//      papered over: a smaller budget is refused here, not tolerated.
//   3. an UNOBSERVED abnormal death, which must still fail the batch, with the
//      class-tagged reason this target defines;
//   4. a SELF-MONITORED abnormal death, which is still UNOBSERVED: a monitor a
//      process holds on itself dies with its owner, so it must fail the batch
//      exactly like 3;
//   5. the native-BEAM exit-signal differential: the BL runtime's reasons for
//      the exit/2-vs-exit/1 and self-`:normal` cases must equal the ones real
//      BEAM (OTP) gives for the same program;
//   6. the F2 probe: a RUNNING process kills its linked child, so the child's
//      death signal comes back through the link. The probe is run with the
//      per-process slice disabled, so a runtime that deleted the running process
//      mid-turn would keep executing the rest of the turn (it writes a marker);
//      the fixed runtime ends the turn with the link's reason first and records
//      that unobserved :killed death.
//
// Two INVARIANTS are sampled at every boundary, not only at the end:
//
//   * every monitor entry names a LIVE owner and a LIVE target. A dead target's
//     DOWN and the entry's removal happen in ONE critical section, so neither
//     can survive to a turn boundary;
//   * every link endpoint of a live process is a LIVE process that links back.
//     A death that was interrupted mid-cleanup would leave a one-sided or
//     dangling link.
//
// Run after compiler.bl, next to the generated bundle:
//   node research/js-actors/verify-lifecycle.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const cwd = new URL('.', import.meta.url);
const script = fileURLToPath(import.meta.url);
const mode = process.argv[2];

// The child: run the generated bundle with the real host, sampling the BL
// scheduler state at every boundary the machine hands to the host.
function childSource({ budget, inject, entryOverride, bigBudget }) {
  return `
import * as H from './host.mjs';

const samples = { turns: 0, pidKeys: 0, refKeys: 0, badPidKeys: 0, badRefKeys: 0,
                  runnableEntries: 0, badRunnable: 0, sinks: 0, badSink: 0, deaths: 0,
                  monitorsFromDead: 0, monitorsToDead: 0, links: 0, badLinks: 0 };
let live = new Set();

const pidOk = x => H.isVec(x) && H.vecSize(x) === 3 && H.kwName(H.vecEl(x, 0)) === 'pid' &&
                   typeof H.vecEl(x, 1) === 'number' && Number.isInteger(H.vecEl(x, 2));
const refOk = x => H.isVec(x) && H.vecSize(x) === 3 && H.kwName(H.vecEl(x, 0)) === 'ref' &&
                   typeof H.vecEl(x, 1) === 'number' && Number.isInteger(H.vecEl(x, 2));

// One scheduler boundary: the state a slice hands back must be consistent.
function sample(rt) {
  const st = rt.state;
  if (!st) return;
  const procs = H.mapGet(st, H.kw('procs'));
  const monitors = H.mapGet(st, H.kw('monitors'));
  const runnable = H.vecItems(H.mapGet(st, H.kw('runnable')));
  // A turn boundary is entered with no critical section open. Inside one, a
  // dead monitor target or a half-detached link is legal until the section
  // closes, so the target/link half of the invariants is checked only here.
  const boundary = (rt.criticalDepth || 0) === 0;
  samples.turns++;
  for (const k of H.listToArray(H.mapKeys(procs))) {
    samples.pidKeys++;
    if (!pidOk(k)) samples.badPidKeys++;
  }
  // A death that another slice could see half-applied would show up as a
  // process that is gone from the registry while a runnable entry or the sink
  // still names it — both checked below — and the count is the evidence that
  // deaths really were cleaned up while the scheduler was slice-bound.
  const now = new Set(H.listToArray(H.mapKeys(procs)).map(H.hashKey));
  for (const k of live) if (!now.has(k)) samples.deaths++;
  live = now;
  for (const k of H.listToArray(H.mapKeys(monitors))) {
    samples.refKeys++;
    if (!refOk(k)) samples.badRefKeys++;
    // Every entry must name a LIVE owner and a LIVE target: a dead target's
    // DOWN and the entry's removal are one critical section, so neither can be
    // seen at a boundary. A self-owned entry is removed with its owner.
    const entry = H.mapGet(monitors, k);
    if (!H.mapHas(procs, H.mapGet(entry, H.kw('from')))) samples.monitorsFromDead++;
    if (boundary && !H.mapHas(procs, H.mapGet(entry, H.kw('to')))) samples.monitorsToDead++;
  }
  // A link is recorded on BOTH procs and erased by the death that used it, so
  // at a boundary each endpoint of a live proc's link map is a live proc that
  // links back. A one-sided or dangling endpoint is an interrupted cleanup.
  if (boundary) for (const p of H.listToArray(H.mapKeys(procs))) {
    const links = H.mapGet(H.mapGet(procs, p), H.kw('links'));
    for (const k of H.listToArray(H.mapKeys(links))) {
      samples.links++;
      if (!H.mapHas(procs, k)) { samples.badLinks++; continue; }
      if (!H.mapHas(H.mapGet(H.mapGet(procs, k), H.kw('links')), p)) samples.badLinks++;
    }
  }
  for (const p of runnable) {
    samples.runnableEntries++;
    if (!H.mapHas(procs, p)) samples.badRunnable++;
  }
  const sink = H.mapGet(st, H.kw('input-sink'));
  if (sink !== null) {
    samples.sinks++;
    if (!H.mapHas(procs, sink)) samples.badSink++;
  }
}

const originalTurn = H.RT_HOST['run-turn'];
let captured = null;
H.RT_HOST['run-turn'] = (rt, frames, budget) => {
  captured = rt;
  sample(rt);
  return originalTurn(rt, frames, ${bigBudget ? 100000000 : budget});
};
${inject ? `
// An abnormal death NOBODY links to and NOBODY monitors: the entry process
// itself dies before it can run a single BL step.
H.RT_HOST['make-frames'] = () => [(function* () { throw new Error('injected lifecycle failure'); })()];
` : ''}${entryOverride ? `
// The whole program is ONE BL process, named below and run on its real runtime:
// either a self-monitoring abnormal death (a self-monitor is not an observer, so
// it must fail the batch) or the F2 probe (a running process signalled through a
// link). Only the MAIN entry is replaced; anything it spawns is real.
const originalFrames = H.RT_HOST['make-frames'];
H.RT_HOST['make-frames'] = (rt, f, args) => f === H.ref(rt, 'js', 'entry')
  ? [H.resolveCallee(H.ref(rt, 'js', '${entryOverride}'), [])(rt, [])]
  : originalFrames(rt, f, args);
` : ''}
let outcome = 'ok';
try {
  await import('./out/bundle.mjs');
} catch (error) {
  outcome = String(error.message);
}
const st = captured ? captured.state : null;
console.log('LIFECYCLE-RECORD ' + JSON.stringify({
  outcome, samples,
  errorCount: captured ? (captured.errors || 0) : null,
  lastError: captured ? (captured.lastError || null) : null,
  // The runtime's own identity, plus the identity of a SECOND runtime minted in
  // this same process: an id is ALLOCATED (never a clock reading), so the two
  // must be distinct integers even though they were created almost together.
  runtime: st ? H.mapGet(st, H.kw('runtime')) : null,
  runtime2: H.mapGet(H.newRuntime().state, H.kw('runtime')),
  state: st ? {
    procs: H.mapSize(H.mapGet(st, H.kw('procs'))),
    monitors: H.mapSize(H.mapGet(st, H.kw('monitors'))),
    runnable: H.vecItems(H.mapGet(st, H.kw('runnable'))).length,
    sink: H.mapGet(st, H.kw('input-sink')),
  } : null,
}));
`;
}

function runChild(label, { budget = 200, inject = false, selfMonitor = false, f2Probe = false, bigBudget = false, expectSuccess = true }) {
  const entryOverride = f2Probe ? 'life-f2-probe'
    : (selfMonitor ? 'life-self-monitored-crash' : null);
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', childSource({ budget, inject, entryOverride, bigBudget })], {
    cwd, encoding: 'utf8', timeout: 180000, maxBuffer: 8 * 1024 * 1024,
  });
  assert.ifError(result.error);
  const lines = result.stdout.split('\n');
  const recordLine = lines.filter(line => line.startsWith('LIFECYCLE-RECORD ')).pop();
  assert.ok(recordLine, `no lifecycle record from ${label}: ${result.stdout}${result.stderr}`);
  const record = JSON.parse(recordLine.slice('LIFECYCLE-RECORD '.length));
  const checks = lines.filter(line => line.startsWith('PASS '));
  const lifeChecks = checks.filter(line => line.startsWith('PASS life-'));
  if (expectSuccess) {
    assert.equal(result.status, 0, `failures in ${label}: ${result.stdout}${result.stderr}`);
    assert.match(result.stdout, /js-actors: ALL PASS/);
    assert.doesNotMatch(result.stdout, /^FAIL /m);
    assert.ok(lifeChecks.length >= 40, `${label}: only ${lifeChecks.length} lifecycle checks ran`);
  }
  return { record, checks, lifeChecks, result };
}

// `EXIT-PARITY <key> <reason>` lines -> { key: reason }. Both sides print the
// same format: the BL bundle from test.bl, the oracle from BEAM itself.
function parseParity(out) {
  const map = {};
  for (const line of out.split('\n')) {
    if (!line.startsWith('EXIT-PARITY ')) continue;
    const [, key, value] = line.split(' ');
    map[key] = value;
  }
  return map;
}

// The native-BEAM oracle, run under `elixir -e`. It emits exactly the keys of
// test.bl's EXIT-PARITY table, exercising exit/1 vs exit/2 `:kill` and self
// `:normal` on a real BEAM. `inspect/1` renders keywords as BL's `describe` does,
// so the two tables are directly comparable.
const BEAM_PARITY = `
defmodule Parity do
  def mon(fun) do
    pid = spawn(fn -> receive do :go -> nil end; fun.() end)
    m = Process.monitor(pid)
    send(pid, :go)
    receive do {:DOWN, ^m, :process, ^pid, r} -> r after 5000 -> :timeout end
  end

  def explicit_kill do
    pid = spawn(fn -> receive do :never -> nil end end)
    m = Process.monitor(pid)
    :erlang.exit(pid, :kill)
    receive do {:DOWN, ^m, :process, ^pid, r} -> r after 5000 -> :timeout end
  end

  def link_nontrap(child) do
    me = self()
    pid = spawn(fn ->
      _c = spawn_link(child)
      r = receive do :never -> :survived after 400 -> :survived end
      send(me, {:r, r})
    end)
    m = Process.monitor(pid)
    receive do
      {:r, r} -> r
      {:DOWN, ^m, :process, ^pid, r} -> r
    after 5000 -> :timeout end
  end

  def link_trap(child) do
    me = self()
    spawn(fn ->
      Process.flag(:trap_exit, true)
      c = spawn_link(child)
      r = receive do {:EXIT, ^c, reason} -> reason after 3000 -> :no_exit end
      send(me, {:r, r})
    end)
    receive do {:r, r} -> r after 5000 -> :timeout end
  end

  def kill_linked_child_from_other do
    me = self()
    q = spawn(fn ->
      c = spawn_link(fn -> receive do :never -> nil end end)
      send(me, {:child, c})
      receive do :never -> nil end
    end)
    m = Process.monitor(q)
    child = receive do {:child, c} -> c after 3000 -> :no_child end
    :erlang.exit(child, :kill)
    receive do {:DOWN, ^m, :process, ^q, r} -> r after 5000 -> :timeout end
  end

  def self_normal, do: mon(fn -> :erlang.exit(self(), :normal) end)

  def self_normal_trap do
    me = self()
    spawn(fn ->
      Process.flag(:trap_exit, true)
      :erlang.exit(self(), :normal)
      r = receive do {:EXIT, _, reason} -> reason after 300 -> :no_message end
      send(me, {:r, r})
    end)
    receive do {:r, r} -> r after 3000 -> :timeout end
  end

  def other_normal do
    t = spawn(fn -> receive do :never -> :survived after 400 -> :survived end end)
    :erlang.exit(t, :normal)
    alive = Process.alive?(t)
    Process.exit(t, :kill)
    if alive, do: :survived, else: :died
  end

  def running_kill_linked do
    mon(fn ->
      c = spawn_link(fn -> receive do :never -> nil end end)
      :erlang.exit(c, :kill)
      receive do :never -> :survived after 400 -> :survived end
    end)
  end
end

emit = fn k, v -> IO.puts("EXIT-PARITY #{k} #{inspect(v)}") end
emit.("d1-explicit-kill", Parity.explicit_kill())
emit.("d1-exit1-kill", Parity.mon(fn -> exit(:kill) end))
emit.("d1-link-exit1-kill-nontrap", Parity.link_nontrap(fn -> exit(:kill) end))
emit.("d1-link-exit1-kill-trap", Parity.link_trap(fn -> exit(:kill) end))
emit.("d1-link-explicit-kill-nontrap", Parity.kill_linked_child_from_other())
emit.("d2-self-normal", Parity.self_normal())
emit.("d2-self-normal-trap", Parity.self_normal_trap())
emit.("d2-other-normal-nontrap", Parity.other_normal())
emit.("d2-link-normal-nontrap", Parity.link_nontrap(fn -> :ok end))
emit.("d2-link-normal-trap", Parity.link_trap(fn -> :ok end))
emit.("f2-linked-kill", Parity.running_kill_linked())
`;

if (mode === 'child-default') {
  const { record, checks } = runChild('default budget', {});
  const s = record.samples;
  assert.ok(s.turns > 0, 'no scheduler boundary was sampled');
  assert.ok(s.pidKeys > 0, 'no pid was ever observed in the registry');
  assert.ok(s.refKeys > 0, 'no monitor ref was ever observed in the table');
  assert.equal(s.badPidKeys, 0, `${s.badPidKeys} registry keys were not [:pid runtime incarnation]`);
  assert.equal(s.badRefKeys, 0, `${s.badRefKeys} monitor keys were not [:ref runtime incarnation]`);
  assert.equal(s.badRunnable, 0, `${s.badRunnable} of ${s.runnableEntries} runnable entries named a dead process`);
  assert.equal(s.badSink, 0, `${s.badSink} of ${s.sinks} sink registrations named a dead process`);
  assert.equal(s.monitorsFromDead, 0, `${s.monitorsFromDead} monitor entries named a dead owner`);
  assert.equal(s.monitorsToDead, 0, `${s.monitorsToDead} monitor entries named a dead target`);
  assert.ok(s.links > 0, 'no link endpoint was ever observed');
  assert.equal(s.badLinks, 0, `${s.badLinks} of ${s.links} link endpoints were stale or one-sided`);
  assert.ok(Number.isInteger(record.runtime) && record.runtime >= 1,
    `runtime identity was not an allocated integer: ${record.runtime}`);
  assert.ok(Number.isInteger(record.runtime2) && record.runtime2 !== record.runtime,
    `two runtimes in one process shared a runtime identity: ${record.runtime} / ${record.runtime2}`);
  assert.equal(record.state.procs, 0, 'a process survived the end of the run');
  assert.equal(record.state.monitors, 0, 'a monitor survived the end of the run');
  assert.equal(record.state.runnable, 0, 'the run queue is non-empty after the run');
  assert.equal(record.state.sink, null, 'the input sink is still registered after the run');
  assert.equal(record.errorCount, 0, 'the run recorded an error');
  assert.equal(record.outcome, 'ok');
  console.log(`PASS lifecycle default budget: ${checks.length} BL checks, `
    + `${s.turns} boundaries, ${s.pidKeys} pid + ${s.refKeys} ref observations, `
    + `${s.links} live link endpoints, ${s.runnableEntries} runnable entries, final state empty`);
} else if (mode === 'child-tiny') {
  const { record, checks } = runChild('tiny actor budget', { budget: 17 });
  const s = record.samples;
  assert.ok(s.deaths >= 8, `${s.deaths} processes stopped existing during the sliced run — expected the lifecycle actors' kills`);
  assert.equal(s.badRunnable, 0, `${s.badRunnable} runnable entries named a dead process across ${s.turns} sliced boundaries`);
  assert.equal(s.badSink, 0, `${s.badSink} sink registrations named a dead process across ${s.turns} sliced boundaries`);
  assert.equal(s.badPidKeys + s.badRefKeys, 0, 'a handle lost its typed shape under slicing');
  assert.equal(s.badLinks, 0, `${s.badLinks} of ${s.links} link endpoints went stale under slicing`);
  assert.equal(s.monitorsFromDead + s.monitorsToDead, 0, 'a monitor named a dead process under slicing');
  assert.equal(record.state.procs, 0);
  assert.equal(record.state.monitors, 0);
  assert.equal(record.state.sink, null);
  assert.equal(record.errorCount, 0, 'slicing the death cleanup recorded an error');
  console.log(`PASS lifecycle 17-step actor budget: ${checks.length} BL checks, `
    + `${s.turns} boundaries and ${s.deaths} death cleanups, atomic cleanup held`);
} else if (mode === 'child-unobserved') {
  const { record, result } = runChild('unobserved abnormal death', { inject: true, expectSuccess: false });
  assert.notEqual(result.status, 0, 'an unobserved abnormal death must fail the batch');
  assert.match(record.outcome, /recorded 1 error/);
  assert.equal(record.errorCount, 1);
  // The `:message` half is the raw host text; the `:reason` half is the class-tagged
  // reason this target defines, which is what the run-level report carries.
  assert.match(result.stdout, /^process .* failed: Error: injected lifecycle failure$/m);
  assert.match(record.lastError, /^process .* died: \[:error "injected lifecycle failure"\]$/);
  assert.equal(record.state.procs, 0);
  console.log(`PASS lifecycle unobserved death fails the batch with the typed reason: ${record.lastError}`);
} else if (mode === 'child-selfmonitor') {
  const { record, result } = runChild('self-monitored abnormal death', { selfMonitor: true, expectSuccess: false });
  assert.notEqual(result.status, 0, 'a self-monitored abnormal death must still fail the batch');
  assert.match(record.outcome, /recorded 1 error/);
  assert.equal(record.errorCount, 1);
  assert.match(record.lastError, /^process .* died: \[:error .*life-self-monitored/);
  assert.equal(record.state.procs, 0);
  assert.equal(record.state.monitors, 0, 'the self-monitor survived its owner');
  console.log(`PASS lifecycle self-monitored death is unobserved and fails the batch: ${record.lastError}`);
} else if (mode === 'child-f2') {
  const { record, result } = runChild('running process signalled through a link',
    { f2Probe: true, bigBudget: true, expectSuccess: false });
  assert.doesNotMatch(result.stdout, /F2-CONTINUED/,
    'the running process kept executing after its link-signalled death');
  assert.equal(record.errorCount, 1, 'the link-signalled death was not recorded');
  assert.match(record.lastError, /died: :killed/);
  assert.equal(record.state.procs, 0);
  console.log(`PASS lifecycle running process ends on its link signal: ${record.lastError}`);
} else {
  // The parent: isolated child processes, each with its own runtime, plus the
  // native-BEAM exit-signal differential.
  const spawn = name => {
    const child = spawnSync(process.execPath, [script, name], { encoding: 'utf8', timeout: 180000 });
    assert.ifError(child.error);
    assert.equal(child.status, 0, `${name} failed:\n${child.stdout}${child.stderr}`);
    process.stdout.write(child.stdout);
  };
  spawn('child-default');
  spawn('child-tiny');
  spawn('child-unobserved');
  spawn('child-selfmonitor');
  spawn('child-f2');

  // The BL runtime's exit-signal reasons vs the ones real BEAM gives for the
  // same program (the oracle). A missing `elixir` is reported, never silent.
  const bundle = spawnSync(process.execPath,
    ['--input-type=module', '-e', childSource({ budget: 200, inject: false })],
    { cwd, encoding: 'utf8', timeout: 180000, maxBuffer: 8 * 1024 * 1024 });
  assert.ifError(bundle.error);
  assert.equal(bundle.status, 0, `parity bundle run failed:\n${bundle.stdout}${bundle.stderr}`);
  const blParity = parseParity(bundle.stdout);
  assert.ok(Object.keys(blParity).length >= 11, 'the BL run printed no exit-parity table');
  const oracle = spawnSync('elixir', ['-e', BEAM_PARITY], { encoding: 'utf8', timeout: 120000 });
  if (oracle.error && oracle.error.code === 'ENOENT') {
    console.log('SKIP lifecycle native-BEAM exit-signal differential: elixir is not on PATH');
  } else {
    assert.ifError(oracle.error);
    assert.equal(oracle.status, 0, `elixir parity oracle failed:\n${oracle.stdout}${oracle.stderr}`);
    const beamParity = parseParity(oracle.stdout);
    assert.deepEqual(blParity, beamParity,
      'BL exit-signal reasons diverge from native BEAM');
    console.log(`PASS lifecycle native-BEAM differential: ${Object.keys(beamParity).length} `
      + 'exit-signal reasons match OTP');
  }
  console.log('js-actors: LIFECYCLE PASS');
}
