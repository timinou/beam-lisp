// verify-tables.mjs — focused verifier for the FEAT-052 slice (portable TABLES:
// identity, ownership, heir transfer, access modes, names, atomic counter, all
// in runtime.bl, over the host's mutable-store leaves admitted by compiler.bl).
//
// The JavaScript here is a TEST RUNNER, an ORACLE, an ACCOUNTANT and a BUNDLE
// READER. It defines no table policy: it never creates a table for the suite,
// never picks an owner and never writes a row. Six independent checks:
//
//   1. BUDGETS. The shipped acceptance suite runs at the default actor budget,
//      at 17 steps and at 41 steps. Every table operation runs inside ONE
//      critical section, so a slice boundary landing inside a read-modify-write
//      would show up as a lost update, a phantom row or a table that outlived
//      its owner — and the suite asserts the opposite on all three budgets.
//      Each run is required to contain the SAME number of `tbl-*` checks, so a
//      budget that silently skipped cases cannot pass by passing less.
//
//   2. THE CHECKS THEMSELVES. Every acceptance check the FEAT-052 section of
//      test.bl declares is READ OFF test.bl by marker and required to have
//      passed — so adding a case to the suite adds it here, and removing one
//      cannot quietly shrink the coverage.
//
//   3. THE BUILD. The generated bundle must carry the BL table service as real
//      target globals (`js/table-new`, `js/table-lookup`, …), and the
//      fail-closed ABI list in its own header must contain the eight host table
//      leaves — the names compiler.bl admits. There must be NO `core/table-*`
//      alias: the service is reached by its own name, not through a second
//      spelling, and `host/…` stays the only other vocabulary.
//
//   4. THE HOST ACCOUNTING. A host handle is minted by `host/table-new` and
//      released by `host/table-destroy`. The verifier wraps both leaves before
//      the bundle boots and requires that every handle minted during the whole
//      suite was released: no stale handle survives a death, an explicit
//      destroy or a refused creation. This is the host-side half of "no stale
//      metadata/handles after death", which BL cannot see.
//
//   5. THE NATIVE-BEAM DIFFERENTIAL. For the same scenarios, real BEAM/ETS
//      answers the same 25 tokens: owner death disposes, the name is freed, an
//      heir receives the transfer with its data and the rows, `give_away` moves
//      ownership, a duplicate name is refused, `update_counter` accumulates and
//      refuses a missing key, a row HOLDING nil is a row, an absent key answers
//      empty, and the three access modes refuse exactly what this target
//      refuses — including that a `:public` table is writable all the way down,
//      so another process may destroy it. Only the RULES are compared — BEAM
//      raises tuples, this target vectors, and BEAM's `:ets.delete/2` answers
//      `true` where this target answers whether a row went — and the shapes are
//      explicitly not claimed equal.
//
//   6. THE SUBSET / DEVIATION REPORT. The supported table subset and every
//      deliberate deviation from BEAM ETS are PRINTED, so the claim is a
//      readable list rather than an implication.
//
// Run after compiler.bl, next to the generated bundle:
//   node research/js-actors/verify-tables.mjs
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
  const pass = result.stdout.split('\n').filter((line) => line.startsWith('PASS '))
    .map((line) => line.slice(5).trim());
  const fail = result.stdout.split('\n').filter((line) => line.startsWith('FAIL '))
    .map((line) => line.slice(5).trim());
  const tbl = pass.filter((name) => name.startsWith('tbl-'));
  assert.ok(tbl.length > 0, `${label} ran no table checks:\n${out}`);
  // Every FEAT-052 check must have passed. A failure here is THIS slice's.
  const tblFail = fail.filter((name) => name.startsWith('tbl-'));
  assert.deepEqual(tblFail, [], `${label} reported failing table checks:\n${out}`);
  // The bundle is now an integrated suite. A trace/name/lifecycle failure is
  // still a regression of this built target; no prefix-based exemptions.
  assert.deepEqual(fail, [], `${label} reported failing BL checks:\n${out}`);
  return { stdout: result.stdout, passed: pass, failed: fail, tbl };
}

const defaultRun = runBudget('default actor budget', null);
const tinyRun = runBudget('17-step actor budget', 17);
const smallRun = runBudget('41-step actor budget', 41);

assert.deepEqual([...new Set(tinyRun.tbl)].sort(), [...new Set(defaultRun.tbl)].sort(),
  'the 17-step budget ran a different table check set');
assert.deepEqual([...new Set(smallRun.tbl)].sort(), [...new Set(defaultRun.tbl)].sort(),
  'the 41-step budget ran a different table check set');
console.log(`PASS table suite at the default, 17-step and 41-step budgets:`
  + ` ${defaultRun.tbl.length} table checks each`);

// ── 2. every declared FEAT-052 check ran and passed ─────────────────────────

const testSource = readFileSync(new URL('./test.bl', import.meta.url), 'utf8');
const start = testSource.indexOf('; ── FEAT-052');
const end = testSource.indexOf('; ── FEAT-050');
assert.ok(start > 0 && end > start, 'the FEAT-052 section of test.bl was not found');
const declared = [...testSource.slice(start, end).matchAll(/\["(tbl-[a-z0-9-]+)"/g)]
  .map((m) => m[1]);
assert.equal(declared.length, 121,
  `the FEAT-052 declared check count changed; review additions/removals explicitly`);
for (const run of [defaultRun, tinyRun, smallRun]) {
  assert.deepEqual([...new Set(run.tbl)].sort(), [...new Set(declared)].sort(),
    'declared table checks and passed checks differ');
}
console.log(`PASS every one of ${declared.length} declared table checks passed`);

// ── 3. the bundle carries the service, and the ABI header the leaves ────────

const bundle = readFileSync(new URL('./out/bundle.mjs', import.meta.url), 'utf8');
const SERVICE = ['table-new', 'table-whereis', 'table-owner', 'table-lookup',
  'table-insert', 'table-delete', 'table-size', 'table-snapshot', 'table-select',
  'table-update-counter', 'table-give-away', 'table-destroy'];
for (const name of SERVICE) {
  assert.ok(bundle.includes(`H.def(rt, "js/${name}"`),
    `the bundle has no target global js/${name} — the table service was not compiled`);
}
const HOST_LEAVES = ['table-new', 'table-lookup', 'table-insert', 'table-delete',
  'table-size', 'table-destroy', 'table-snapshot', 'is-table'];
for (const name of HOST_LEAVES) {
  assert.ok(bundle.includes(`"${name}"`),
    `the bundle's ABI header does not name the host leaf ${name}`);
}
assert.doesNotMatch(bundle, /defAlias\(rt, "core\/table-/,
  'the table service is aliased into the core namespace — that is the second API this slice refuses');
assert.doesNotMatch(bundle, /BeamLisp\.RT\/table/,
  'a table operation reached the native BEAM runtime module');
console.log(`PASS the bundle carries ${SERVICE.length} service globals, all`
  + ` ${HOST_LEAVES.length} host leaves, and no second spelling`);

// ── 4. host handle accounting: nothing minted is left behind ────────────────

const accounting = spawnSync(process.execPath, ['--input-type=module', '-e', `
import * as H from './host.mjs';
let created = 0, destroyed = 0, runtime;
const newLeaf = H.RT_HOST['table-new'];
H.RT_HOST['table-new'] = (rt) => { const h = newLeaf(rt); runtime = rt; created++; return h; };
const destroyLeaf = H.RT_HOST['table-destroy'];
H.RT_HOST['table-destroy'] = (rt, h) => { const ok = destroyLeaf(rt, h); destroyed++; return ok; };
await import('./out/bundle.mjs');
console.log('TABLE-HANDLES ' + created + ' ' + destroyed + ' ' + (runtime?.tables?.size ?? 0));
`], { cwd, encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024 });
assert.ifError(accounting.error);
assert.equal(accounting.status, 0, accounting.stdout + accounting.stderr);
const m = (accounting.stdout + accounting.stderr).match(/TABLE-HANDLES (\d+) (\d+) (\d+)/);
assert.ok(m, `the accounting run printed no handle count:\n${accounting.stdout}${accounting.stderr}`);
const [, created, destroyed, live] = m.map(Number);
assert.ok(created > 0, 'the suite minted no host handle — the accounting wrapped nothing');
assert.equal(created, destroyed,
  `${created - destroyed} host table handle(s) were minted and never freed`);
assert.equal(live, 0, `${live} live host table handle(s) remain after boot`);
console.log(`PASS host handles: ${created} minted, ${destroyed} freed, 0 left live`);

// ── 5. the same rules, answered by real BEAM/ETS ────────────────────────────

function parseParity(text) {
  const out = {};
  for (const line of text.split('\n')) {
    const hit = line.match(/^TABLE-PARITY ([a-z-]+) (\S+)$/);
    if (hit) out[hit[1]] = hit[2];
  }
  return out;
}

const blParity = parseParity(defaultRun.stdout);
const EXPECTED = {
  'owner-death-destroys': 'destroyed',
  'name-freed-on-destroy': 'free',
  'heir-transfer': 'transferred',
  'heir-data': 'gift',
  'heir-rows': '1',
  'heir-owner': 'heir',
  'give-away': 'reclaimed',
  'duplicate-name': 'refused',
  'update-counter-total': '100',
  'update-counter-missing-key': 'refused',
  'nil-row-present': 'present',
  'absent-row-empty': 'empty',
  'lookup-shape-rows': '1',
  'private-read-other': 'denied',
  'private-write-other': 'denied',
  'private-give-away-other': 'denied',
  'private-destroy-other': 'denied',
  'protected-read-other': 'ok',
  'protected-write-other': 'denied',
  'protected-give-away-other': 'denied',
  'protected-destroy-other': 'denied',
  'public-read-other': 'ok',
  'public-write-other': 'ok',
  'public-give-away-other': 'denied',
  'public-destroy-other': 'ok',
};
assert.deepEqual(blParity, EXPECTED,
  'the BL run printed a different parity table than this verifier expects');

const BEAM_TABLES = `
defmodule EtsParity do
  def heir_loop(parent) do
    receive do
      {:"ETS-TRANSFER", tid, from, data} ->
        send(parent, {:caught, tid, from, data})
        heir_loop(parent)
      {:give, tid, to} ->
        :ets.give_away(tid, to, :gift)
        send(parent, {:gave, tid})
        heir_loop(parent)
      :die -> :ok
    end
  end

  def probe(parent, tid) do
    v = fn f ->
      try do
        f.()
        :ok
      rescue
        _ -> :denied
      end
    end
    send(parent, {:probe, v.(fn -> :ets.lookup(tid, :k) end),
                  v.(fn -> :ets.insert(tid, {:p, 1}) end),
                  v.(fn -> :ets.give_away(tid, parent, :gift) end),
                  v.(fn -> :ets.delete(tid) end)})
  end

  def verdict(parent, mode, tid) do
    p = spawn(fn -> probe(parent, tid) end)
    {r, w, g, d} = receive do {:probe, a, b, c, e} -> {a, b, c, e} after 2000 -> {:none, :none, :none, :none} end
    Process.demonitor(Process.monitor(p), [:flush])
    IO.puts("TABLE-PARITY #{mode}-read-other #{r}")
    IO.puts("TABLE-PARITY #{mode}-write-other #{w}")
    IO.puts("TABLE-PARITY #{mode}-give-away-other #{g}")
    IO.puts("TABLE-PARITY #{mode}-destroy-other #{d}")
  end

  def run do
    parent = self()

    # an unheired owner dies: the table and its name go with it
    owner = spawn(fn ->
      t = :ets.new(:tbl_par_doomed, [:named_table])
      :ets.insert(t, {:k, 1})
      send(parent, {:ready, t})
      receive do :die -> :ok end
    end)
    tid = receive do {:ready, t} -> t after 2000 -> :none end
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    receive do {:DOWN, ^ref, :process, _, _} -> :ok after 2000 -> :ok end
    IO.puts("TABLE-PARITY owner-death-destroys " <>
      (if :ets.info(tid) == :undefined, do: "destroyed", else: "alive"))
    IO.puts("TABLE-PARITY name-freed-on-destroy " <>
      (case :ets.whereis(:tbl_par_doomed) do :undefined -> "free"; _ -> "held" end))

    # an heir catches what a dead owner leaves, then hands it on
    heir = spawn(fn -> heir_loop(parent) end)
    o2 = spawn(fn ->
      t = :ets.new(:tbl_par_heired, [:set, {:heir, heir, :gift}])
      :ets.insert(t, {:k, 1})
      send(parent, {:ready2, t})
      receive do :die -> :ok end
    end)
    tid2 = receive do {:ready2, t} -> t after 2000 -> :none end
    ref2 = Process.monitor(o2)
    Process.exit(o2, :kill)
    receive do {:DOWN, ^ref2, :process, _, _} -> :ok after 2000 -> :ok end
    caught = receive do {:caught, t, from, data} -> {t, from, data} after 2000 -> {:none, :none, :none} end
    IO.puts("TABLE-PARITY heir-transfer " <> (if elem(caught, 0) == tid2, do: "transferred", else: "lost"))
    IO.puts("TABLE-PARITY heir-data #{caught |> elem(2)}")
    IO.puts("TABLE-PARITY heir-rows #{:ets.info(tid2, :size)}")
    IO.puts("TABLE-PARITY heir-owner " <> (if :ets.info(tid2, :owner) == heir, do: "heir", else: "other"))
    send(heir, {:give, tid2, parent})
    receive do {:gave, _} -> :ok after 2000 -> :ok end
    IO.puts("TABLE-PARITY give-away " <> (if :ets.info(tid2, :owner) == parent, do: "reclaimed", else: "other"))
    :ets.delete(tid2)
    send(heir, :die)

    # a duplicate name is refused; the first table stands
    kept = :ets.new(:tbl_par_kept, [:named_table])
    dup = try do
      :ets.new(:tbl_par_kept, [:named_table])
      "accepted"
    rescue
      _ -> "refused"
    end
    IO.puts("TABLE-PARITY duplicate-name #{dup}")
    :ets.delete(kept)

    # the counter (a key must exist there too), and the two answers a read can give
    ct = :ets.new(:tbl_par_ct, [:set, :public])
    :ets.insert(ct, {:n, 0})
    :ets.update_counter(ct, :n, 60)
    :ets.update_counter(ct, :n, 40)
    IO.puts("TABLE-PARITY update-counter-total #{:ets.lookup_element(ct, :n, 2)}")
    missing = try do
      :ets.update_counter(ct, :absent, 1)
      "accepted"
    rescue
      _ -> "refused"
    end
    IO.puts("TABLE-PARITY update-counter-missing-key #{missing}")
    :ets.insert(ct, {:nilrow, nil})
    IO.puts("TABLE-PARITY nil-row-present " <>
      (if :ets.lookup(ct, :nilrow) == [], do: "empty", else: "present"))
    IO.puts("TABLE-PARITY absent-row-empty " <>
      (if :ets.lookup(ct, :nope) == [], do: "empty", else: "present"))
    IO.puts("TABLE-PARITY lookup-shape-rows #{length(:ets.lookup(ct, :n))}")
    :ets.delete(ct)

    # the three access modes, seen from another process. A public table is a
    # WRITE all the way down, so the other process's :ets.delete/1 lands there.
    for mode <- [:private, :protected, :public] do
      t = :ets.new(:tbl_par_mode, [:set, mode])
      :ets.insert(t, {:k, 1})
      verdict(parent, mode, t)
      if :ets.info(t) != :undefined, do: :ets.delete(t)
    end
  end
end
EtsParity.run()
`;

const oracle = spawnSync('elixir', ['-e', BEAM_TABLES], { encoding: 'utf8', timeout: 120000 });
if (oracle.error && oracle.error.code === 'ENOENT') {
  console.log('SKIP tables native-BEAM differential: elixir is not on PATH');
} else {
  assert.ifError(oracle.error);
  assert.equal(oracle.status, 0, `elixir table oracle failed:\n${oracle.stdout}${oracle.stderr}`);
  const beamParity = parseParity(oracle.stdout);
  assert.deepEqual(beamParity, blParity,
    'the BL table rules and native ETS disagree\n  met: ' + JSON.stringify(blParity)
    + '\n  OTP: ' + JSON.stringify(beamParity));
  console.log(`PASS native-BEAM/ETS differential: ${Object.keys(blParity).length} table rules match OTP`);
}

// ── 6. the supported subset, and every deliberate deviation ─────────────────

const SUBSET = [
  'types: :set only (one row per canonical key)',
  'identity: [:table runtime serial], BL-owned; public table verbs return only ids',
  'ownership: the creating process; owner death disposes',
  'heir: a pid named AT CREATION; on owner death the table transfers with',
  '      [:ets-transfer tid former-owner heir-data]; a dead/missing/self heir destroys',
  'access: :private (owner only) | :protected (owner writes, all read) | :public (all)',
  '        give-away is owner-only in every mode; destroy asks for a WRITE, so on',
  '        a :public table any process may destroy it (as :ets.delete/1 allows)',
  'names: unique among live table names, released with the table, separate from',
  '       the process-name space; duplicate creation refused loudly',
  'operations: new, whereis, owner, lookup, insert, delete, size, snapshot,',
  '            select (one literal 2-element pattern with :_ wildcards),',
  '            update-counter (integer delta, atomic, existing integer row),',
  '            give-away, destroy',
  'memory: bounded by the host (rows, key size, tables per runtime), loudly',
];
const DEVIATIONS = [
  'ordered_set / bag / duplicate_bag: REFUSED (no total order over BL values;',
  '  this store is one row per key) — BEAM has all four types',
  'match specs: only one clause of a 2-element pattern with :_ wildcards.',
  '  Guards, bodies, $N variables, several clauses, :all and select/3',
  '  continuations are REFUSED by name; BEAM has the full match specification',
  'lookup: [ {k, v} ] in BEAM vs a one-row LIST of [k v] vectors here — same shape,',
  '  different row container; and a delete answers whether a row went, where',
  '  :ets.delete/2 answers true unconditionally',
  'snapshot order: insertion order here (deterministic); BEAM specifies none',
  'absence: one nil, where BEAM has :undefined (:ets.whereis) and nil elsewhere',
  'cursor/foldl: none; every read is a snapshot (tab2list/select only)',
  'the transfer message is a BL vector [:ets-transfer tid from data], where BEAM',
  '  sends the tuple {:"ETS-TRANSFER", tid, from, data}',
  'access modes govern BL table verbs in a trusted bundle, not hostile BL source: BEAM also uses them as',
  '  read_concurrency/write_concurrency switches, which this target has none of',
  'other ETS operations (member, insert_new, lookup_element, update_element,',
  '  match, match_object, foldl, tab2file) do not exist on this target at all,',
  '  so the closed ABI fails the BUILD that names them rather than the run',
];
console.log('SUBSET (portable table semantics implemented over the host store):');
for (const line of SUBSET) console.log('  ' + line);
console.log('DEVIATIONS from BEAM ETS (deliberate, and refused rather than faked):');
for (const line of DEVIATIONS) console.log('  ' + line);

console.log('js-actors: TABLES PASS');
