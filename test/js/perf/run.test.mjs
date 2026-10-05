// test/js/perf/run.test.mjs — the single-target runner's judgement, no build.
// Run: node --test test/js/
//
// Every helper takes an injected clock and round count, so the rejection paths
// (missing/extra/non-function benches, bad counts, wrong answers in a later
// round, broken timing, CLI shapes) run in milliseconds — no compiled core, no
// 21x suite, no BEAM.
import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import {
  REQUIRED, EXPECTED, ROUNDS, WARMUPS, DEFAULT_OUT,
  benchNames, sameResult, resultProblems, median,
  measureBench, runAll, parseArgs, resolveOut, modulePath,
} from "./run.mjs";

// A module with every pinned bench; `values` overrides the answer per bench.
const moduleOf = (values = {}) => {
  const mod = {};
  for (const n of REQUIRED) mod[n] = () => (n in values ? values[n] : EXPECTED[n]);
  return mod;
};

// A monotone clock: each read advances by `step`, so a timed call's delta is
// exactly its step — positive and deterministic.
const clock = (step = 1) => {
  let t = 0;
  return () => (t += step);
};

test("the pinned set is exactly the eight perf.bl benches, with pinned answers", () => {
  assert.equal(REQUIRED.length, 8);
  assert.deepEqual(REQUIRED.slice().sort(), Object.keys(EXPECTED).sort());
  assert.equal(WARMUPS, 3);
  assert.equal(ROUNDS, 21);
  assert.equal(DEFAULT_OUT, "test/js/perf/out");
});

test("benchNames: an exact function set passes", () => {
  assert.deepEqual(benchNames(moduleOf(), "module"), REQUIRED);
});

test("benchNames: empty or partially missing exports are rejected", () => {
  assert.throws(() => benchNames({}, "module"), /missing\/non-function/);
  const mod = moduleOf();
  delete mod.d_p_sort;
  assert.throws(() => benchNames(mod, "module"), /d_p_sort/);
});

test("benchNames: a non-function benchmark export is rejected", () => {
  const mod = moduleOf();
  mod.d_p_vec = 5;
  assert.throws(() => benchNames(mod, "module"), /d_p_vec/);
});

test("benchNames: an unexpected extra d_p_ workload is rejected", () => {
  const mod = moduleOf();
  mod.d_p_sneak = () => 0;
  assert.throws(() => benchNames(mod, "module"), /unexpected d_p_ export.*d_p_sneak/);
});

test("benchNames: a non-object module is rejected", () => {
  assert.throws(() => benchNames(null, "module"), /module object/);
  assert.throws(() => benchNames(7, "module"), /module object/);
});

test("sameResult: number and BigInt naming the same integer agree", () => {
  assert.equal(sameResult(5, 5), true);
  assert.equal(sameResult(5n, 5), true);
  assert.equal(sameResult(5, 5n), true);
  assert.equal(sameResult(5n, 6), false);
  assert.equal(sameResult(NaN, NaN), true);
});

test("sameResult: signed zero is not silently accepted as the same answer", () => {
  assert.equal(sameResult(-0, 0), false);
});

test("resultProblems: a wrong answer is reported, a right one is clean", () => {
  assert.deepEqual(resultProblems("d_p_eq", 5000), []);
  assert.deepEqual(resultProblems("d_p_eq", 5000n), []);
  assert.equal(resultProblems("d_p_eq", 4999).length, 1);
  assert.ok(resultProblems("d_p_str", 1)[0].includes("expected"));
});

test("median: middle of the sorted sample", () => {
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([4, 1, 2, 3, 5]), 3);
  assert.throws(() => median([]), /empty/);
});

test("measureBench: warms then measures, validating every round", () => {
  let calls = 0;
  const run = () => { calls++; return EXPECTED.d_p_eq; };
  const m = measureBench({ name: "d_p_eq", run, rounds: 4, warmups: 2, cpuTimer: clock(), wallTimer: clock(2) });
  assert.equal(calls, 6);
  assert.equal(m.cpuTimes.length, 4);
  assert.equal(m.wallTimes.length, 4);
  assert.deepEqual(m.problems, []);
  for (const t of m.cpuTimes) assert.equal(t, 1);
  for (const t of m.wallTimes) assert.equal(t, 2);
});

test("measureBench: a wrong answer in a later round cannot hide behind the first", () => {
  const base = moduleOf();
  const eq = base.d_p_eq;
  let calls = 0;
  const run = () => { const v = eq(); calls++; return calls === 2 ? v - 1 : v; };
  const m = measureBench({ name: "d_p_eq", run, rounds: 3, warmups: 0, cpuTimer: clock(), wallTimer: clock() });
  assert.ok(m.problems.some((p) => p.includes("round 2") && p.includes("d_p_eq")));
  assert.equal(m.problems.length, 1);
});

test("measureBench: a wrong answer during warmup is caught too", () => {
  const base = moduleOf();
  const eq = base.d_p_eq;
  let calls = 0;
  const run = () => { const v = eq(); calls++; return calls === 1 ? v - 1 : v; };
  const m = measureBench({ name: "d_p_eq", run, rounds: 2, warmups: 1, cpuTimer: clock(), wallTimer: clock() });
  assert.ok(m.problems.some((p) => p.includes("warmup 1") && p.includes("d_p_eq")));
});

test("measureBench: invalid sample counts are rejected", () => {
  const run = () => EXPECTED.d_p_eq;
  for (const rounds of [0, -1, 0.5, NaN, Infinity]) {
    assert.throws(() => measureBench({ name: "d_p_eq", run, rounds, cpuTimer: clock(), wallTimer: clock() }), /rounds must/);
  }
  assert.throws(() => measureBench({ name: "d_p_eq", run, warmups: -1, cpuTimer: clock(), wallTimer: clock() }), /warmups/);
  assert.throws(() => measureBench({ name: "d_p_eq", run: 5, rounds: 2, cpuTimer: clock(), wallTimer: clock() }), /not a function/);
});

test("measureBench: a non-finite or non-positive timing is rejected", () => {
  const run = () => EXPECTED.d_p_eq;
  assert.throws(() => measureBench({ name: "d_p_eq", run, rounds: 2, warmups: 0, cpuTimer: () => 0, wallTimer: clock() }),
    /non-positive CPU timing/);
  assert.throws(() => measureBench({ name: "d_p_eq", run, rounds: 2, warmups: 0, cpuTimer: clock(), wallTimer: () => 0 }),
    /non-positive wall timing/);
  let i = 0;
  assert.throws(() => measureBench({ name: "d_p_eq", run, rounds: 2, warmups: 0,
    cpuTimer: () => (i++ === 0 ? 0 : Infinity), wallTimer: clock() }), /non-finite\/non-positive CPU timing/);
});

test("runAll: measures every pinned bench and passes on good answers", () => {
  const r = runAll({ mod: moduleOf(), rounds: 3, warmups: 1, cpuTimer: clock(), wallTimer: clock() });
  assert.equal(r.ok, true);
  assert.deepEqual(r.problems, []);
  assert.deepEqual(r.results.map((b) => b.name), REQUIRED);
  for (const b of r.results) assert.equal(b.problems.length, 0);
});

test("runAll: a wrong-but-consistent answer fails against perf.bl", () => {
  const r = runAll({ mod: moduleOf({ d_p_str: 1 }), rounds: 3, warmups: 1, cpuTimer: clock(), wallTimer: clock() });
  assert.equal(r.ok, false);
  assert.ok(r.problems.some((p) => p.includes("d_p_str")));
  assert.equal(r.results.find((b) => b.name === "d_p_str").answer, 1);
});

test("runAll: subsets and duplicate workload names cannot pass", () => {
  const mod = moduleOf();
  assert.throws(() => runAll({ mod, names: [REQUIRED[0]], cpuTimer: clock(), wallTimer: clock() }), /invalid benchmark set/);
  assert.throws(() => runAll({ mod, names: REQUIRED.map(() => REQUIRED[0]), cpuTimer: clock(), wallTimer: clock() }), /invalid benchmark set/);
  assert.throws(() => runAll({ mod, names: [], cpuTimer: clock(), wallTimer: clock() }), /invalid benchmark set/);
});

test("parseArgs: default output, a relative positional output, and options", () => {
  assert.deepEqual(parseArgs([]), { out: DEFAULT_OUT, json: null, manifest: null });
  assert.deepEqual(parseArgs(["out/perf"]), { out: "out/perf", json: null, manifest: null });
  assert.deepEqual(parseArgs(["out/perf", "--json", "r.json", "--manifest", "m.json"]),
    { out: "out/perf", json: "r.json", manifest: "m.json" });
});

test("parseArgs: unknown options, missing values and extra arguments are rejected", () => {
  assert.throws(() => parseArgs(["--nope"]), /unknown option/);
  assert.throws(() => parseArgs(["--json"]), /--json needs a path/);
  assert.throws(() => parseArgs(["--manifest"]), /--manifest needs a path/);
  assert.throws(() => parseArgs(["a", "b"]), /unexpected argument b/);
});

test("resolveOut/modulePath: a relative OUT resolves against the cwd", () => {
  assert.equal(resolveOut("test/js/perf/out"), path.resolve("test/js/perf/out"));
  assert.equal(modulePath("test/js/perf/out"), path.join(path.resolve("test/js/perf/out"), "ns", "perf.mjs"));
});
