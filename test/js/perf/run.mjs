// test/js/perf/run.mjs — measure the ONE compiled perf core.
//
//   ./bin/bl run test/js/perf/build.bl
//   node test/js/perf/run.mjs [OUT] [--json REPORT.json] [--manifest manifest.json]
//
// Loads the sole compiled module at OUT/ns/perf.mjs (OUT defaults to
// test/js/perf/out, resolved against the current directory), checks it exports
// exactly the eight pinned benches, warms and times each for a median of 21
// rounds on BOTH the CPU and the wall clock, and validates the answer of EVERY
// returned call against the value perf.bl computes.
//
// There is no hand core to compare against and no 1.5x gate any more: the
// deleted hand implementation is gone, so this reports one target's cost, it
// does not judge it. `--json` saves a machine-readable report; when
// `--manifest` names the build manifest the report carries its `source_id`.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// The eight benches pinned by the workload file: perf.bl's `p-*` functions,
// compiled to `d_p_*` ES exports (`d_` + the mangled name). The set is EXACT in
// the compiled module: a missing bench, a non-function export, or an
// unexpected extra `d_p_` workload all fail validation.
export const REQUIRED = [
  "d_p_assoc",
  "d_p_eq",
  "d_p_freq",
  "d_p_get_in",
  "d_p_map_filter",
  "d_p_sort",
  "d_p_str",
  "d_p_vec",
];

// What each bench returns, read from perf.bl. Every measured answer is checked
// against this: a wrong result is a broken workload, not a benchmark number.
export const EXPECTED = {
  d_p_assoc: 5000,
  d_p_eq: 5000,
  d_p_freq: 97,
  d_p_get_in: 20000,
  d_p_map_filter: 100010000,
  d_p_sort: 0,
  d_p_str: 13889,
  d_p_vec: 20000,
};

export const WARMUPS = 3;
export const ROUNDS = 21;
export const DEFAULT_OUT = "test/js/perf/out";

export const isFinitePositive = (x) =>
  typeof x === "number" && Number.isFinite(x) && x > 0;

// A module must export each required bench as a function and no OTHER `d_p_*`
// workload. Returns the (nonempty) pinned name list.
export function benchNames(mod, label) {
  if (mod === null || typeof mod !== "object") {
    throw new Error(`run: ${label} did not load as a module object`);
  }
  const missing = REQUIRED.filter((n) => typeof mod[n] !== "function");
  if (missing.length) {
    throw new Error(`run: ${label} is missing/non-function benchmark export(s): ${missing.join(", ")}`);
  }
  const extra = Object.keys(mod).filter((k) => k.startsWith("d_p_") && !REQUIRED.includes(k));
  if (extra.length) {
    throw new Error(`run: ${label} has unexpected d_p_ export(s): ${extra.join(", ")}`);
  }
  return REQUIRED.slice();
}

// Value equality that spans the runtime's integer model: a Number and a BigInt
// naming the same safe integer are the same answer. Object.is keeps NaN equal
// to NaN and -0 distinct from 0.
export function sameResult(a, b) {
  if (typeof a === typeof b) return Object.is(a, b);
  if (typeof a === "bigint" && typeof b === "number" && Number.isSafeInteger(b)) return a === BigInt(b);
  if (typeof b === "bigint" && typeof a === "number" && Number.isSafeInteger(a)) return b === BigInt(a);
  return false;
}

const fmt = (v) => (typeof v === "bigint" ? `${v}n` : typeof v === "string" ? JSON.stringify(v) : String(v));

// Result check for one bench: the measured answer must equal the value perf.bl
// pins. A bench with no pinned value (never happens in the exact set) has none.
export function resultProblems(name, result, expected = EXPECTED) {
  if (!Object.prototype.hasOwnProperty.call(expected, name)) return [];
  const want = expected[name];
  return sameResult(result, want) ? [] : [`${name}: result ${fmt(result)} != expected ${fmt(want)}`];
}

export const median = (xs) => {
  if (xs.length === 0) throw new Error("run: median of an empty sample");
  const s = xs.slice().sort((a, b) => a - b);
  return s[s.length >> 1];
};

// Process CPU time in milliseconds, not wall time: on a busy host the scheduler
// parks this process between slices, which wall time counts and CPU time does
// not. Both are reported so a reader can see the two apart.
export function defaultCpuTimer() {
  const u = process.cpuUsage();
  return (u.user + u.system) / 1000;
}

export function defaultWallTimer() {
  return performance.now();
}

// Warm `run` `warmups` times, then time `rounds` calls on both clocks,
// validating the answer of EVERY call (warmups included). A non-finite or
// non-positive timing is a broken clock, not a fast bench; a wrong answer is
// reported against its round, so a later wrong result cannot hide behind an
// early right one.
export function measureBench({
  name, run, rounds = ROUNDS, warmups = WARMUPS,
  cpuTimer = defaultCpuTimer, wallTimer = defaultWallTimer,
}) {
  if (!Number.isSafeInteger(rounds) || rounds <= 0 || !Number.isSafeInteger(warmups) || warmups < 0) {
    throw new Error("run: rounds must be positive and warmups non-negative integers");
  }
  if (typeof run !== "function") throw new Error(`run: ${name} is not a function`);
  const problems = [];
  for (let i = 0; i < warmups; i++) {
    problems.push(...resultProblems(name, run()).map((p) => `warmup ${i + 1}: ${p}`));
  }
  const cpuTimes = [], wallTimes = [], answers = [];
  for (let i = 0; i < rounds; i++) {
    const c0 = cpuTimer(), w0 = wallTimer();
    const v = run();
    const cpu = cpuTimer() - c0, wall = wallTimer() - w0;
    if (!isFinitePositive(cpu)) throw new Error(`${name}: non-finite/non-positive CPU timing ${cpu}`);
    if (!isFinitePositive(wall)) throw new Error(`${name}: non-finite/non-positive wall timing ${wall}`);
    problems.push(...resultProblems(name, v).map((p) => `round ${i + 1}: ${p}`));
    cpuTimes.push(cpu); wallTimes.push(wall); answers.push(v);
  }
  return { name, cpuTimes, wallTimes, answers, problems };
}

// Measure every pinned bench on one module. `names` must be exactly the pinned
// set: a subset or duplicate would let an unmeasured workload pass silently.
export function runAll({
  mod, names = REQUIRED, rounds = ROUNDS, warmups = WARMUPS,
  cpuTimer = defaultCpuTimer, wallTimer = defaultWallTimer,
}) {
  if (!Array.isArray(names) || names.length !== REQUIRED.length
      || new Set(names).size !== REQUIRED.length || names.some((n) => !REQUIRED.includes(n))) {
    throw new Error("run: invalid benchmark set");
  }
  benchNames(mod, "module");
  const results = [], problems = [];
  for (const name of names) {
    const m = measureBench({ name, run: mod[name], rounds, warmups, cpuTimer, wallTimer });
    problems.push(...m.problems);
    results.push({
      name,
      cpu: median(m.cpuTimes),
      wall: median(m.wallTimes),
      cpuTimes: m.cpuTimes,
      wallTimes: m.wallTimes,
      answer: m.answers[0],
      problems: m.problems,
    });
  }
  return { results, problems, ok: problems.length === 0, rounds, warmups };
}

// ─── paths + CLI ─────────────────────────────────────────────────────────────

export function resolveOut(out) {
  return path.resolve(out);
}

export function modulePath(out) {
  return path.join(resolveOut(out), "ns", "perf.mjs");
}

export async function loadModule(out) {
  const p = modulePath(out);
  if (!fs.existsSync(p)) {
    throw new Error(`run: no compiled module at ${p} (run ./bin/bl run test/js/perf/build.bl first)`);
  }
  return import(pathToFileURL(p).href);
}

// `[OUT] [--json PATH] [--manifest PATH]`. OUT stays as written (relative paths
// are resolved by the caller); an unknown option or a missing value is an
// error, never silently ignored.
export function parseArgs(argv) {
  let out = DEFAULT_OUT, json = null, manifest = null;
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--json") {
      json = argv[++i];
      if (!json) throw new Error("run: --json needs a path");
    } else if (a === "--manifest") {
      manifest = argv[++i];
      if (!manifest) throw new Error("run: --manifest needs a path");
    } else if (a.startsWith("--")) {
      throw new Error(`run: unknown option ${a}`);
    } else {
      rest.push(a);
    }
  }
  if (rest.length > 1) throw new Error(`run: unexpected argument ${rest[1]}`);
  if (rest.length === 1) out = rest[0];
  return { out, json, manifest };
}

// The build manifest's `source_id`, or null when no manifest was given.
export function readSourceId(manifestPath) {
  if (!manifestPath) return null;
  const m = JSON.parse(fs.readFileSync(path.resolve(manifestPath), "utf8"));
  return typeof m.source_id === "string" ? m.source_id : null;
}

export function makeReport({ out, sourceId = null, res }) {
  return {
    entry: "perf",
    out,
    module: modulePath(out),
    rounds: res.rounds,
    warmups: res.warmups,
    source_id: sourceId,
    ok: res.ok,
    benches: res.results.map((b) => ({
      name: b.name, cpu_ms: b.cpu, wall_ms: b.wall, answer: b.answer,
    })),
    problems: res.problems,
  };
}

export function printTable(rep, log = console.log) {
  log("bench".padEnd(12) + "cpu_ms".padStart(10) + "wall_ms".padStart(10) + "answer".padStart(12));
  for (const b of rep.benches) {
    log(b.name.slice(4).padEnd(12)
      + b.cpu_ms.toFixed(3).padStart(10)
      + b.wall_ms.toFixed(3).padStart(10)
      + fmt(b.answer).padStart(12));
  }
}

async function main(argv = process.argv.slice(2)) {
  const { out, json, manifest } = parseArgs(argv);
  const mod = await loadModule(out);
  const res = runAll({ mod });
  const rep = makeReport({ out, sourceId: readSourceId(manifest), res });
  printTable(rep);
  for (const p of rep.problems) console.log("problem: " + p);
  console.log(`perf: ${rep.benches.length} benches, ${rep.warmups} warmups, ${rep.rounds} rounds`
    + (rep.ok ? " ok" : ` FAIL (${rep.problems.length} problem(s))`)
    + (rep.source_id ? ` source ${rep.source_id}` : ""));
  if (json) {
    const p = path.resolve(json);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, JSON.stringify(rep, null, 2) + "\n");
    console.log("perf: report -> " + p);
  }
  return rep.ok ? 0 : 1;
}

const invokedDirectly = process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
if (invokedDirectly) {
  main().then((code) => process.exit(code))
        .catch((e) => { console.error(e.message); process.exit(2); });
}
