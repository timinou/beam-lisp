# Direct native entry from BL: results and decision

The same compiled byte pipeline runs through generated BEAM, a resident port, a bounded regular NIF, and a dirty-CPU NIF. All loaders, drivers, oracles, lifecycle tests, scheduling tests, analysis and reporting are BL. The native bridge reuses the existing Cranelift compiler and verifier; it is not a second compiler.

**Answer:** yes, the port boundary can be removed using BEAM's supported NIF interface. Doing so materially reduces entry cost. It does not grant native code BEAM's preemption or crash isolation.

## 1. What is implemented

- `research/j1_probe/src/kernel.rs` holds the single compiler/parser shared by the CLI and NIF.
- `fold::CompiledFold` owns finalized executable memory, exposes a typed call, and frees code at final destruction. It is Send + Sync through ordinary Rust ownership/mutex traits, without a new unsafe Send/Sync assertion.
- `research/j1_nif` supplies resource-based compile/call/close operations, regular and dirty no-op baselines, and diagnostic counters. There is no user-visible integer code pointer.
- `invm/host.bl` uses the existing `vm.native/declare` loader through a private scratch OTP app. Production native install directories and the committed seed stay unchanged.
- The ordinary-scheduler entry enforces **4096 bytes and at most 65536 straight-line IR statements × input bytes**. A byte limit alone would not constrain a complex kernel. It accounts measured time with `enif_consume_timeslice` after returning from the bounded computation; this is accounting, not interruption.
- Compilation and the up-to-1-MiB execution entry use dirty CPU schedulers.

The kernel is still the explicit byte-map/filter/wrapping-sum contract in `fusion/pipeline.bl`. These results are not a claim that arbitrary BL functions automatically lower to native code.

## 2. Timings

Final complete run: `/tmp/rt-invm.5CIEZw`. All raw samples are retained under `evidence/`. Five interleaved timing rounds per admitted size/path; every returned value is checked. Measurements include the BL call wrapper and native argument/result handling. Cold compilation is outside the warm-call timer.

Selected medians, **microseconds per call**:

| Bytes | Fused BEAM | Resident port | Regular NIF | Dirty CPU NIF |
|---:|---:|---:|---:|---:|
| 0 | 6.580 | 112.477 | 2.906 | 32.251 |
| 64 | 5.627 | 20.823 | **0.718** | 9.498 |
| 256 | 16.255 | 22.542 | **0.988** | 7.085 |
| 1024 | 45.495 | 29.884 | **2.178** | 14.380 |
| 4096 | 475.656 | 145.190 | **26.397** | 66.189 |
| 16384 | 2532.750 | 413.315 | policy refusal | **226.065** |
| 65536 | 2799.798 | 328.779 | policy refusal | **134.012** |
| 262144 | 12508.274 | 939.117 | policy refusal | **608.134** |
| 1048576 | 64745.300 | 6878.672 | policy refusal | **2896.951** |

At 256 bytes, regular NIF samples ranged **0.763–1.144 us**, versus port **14.849–28.835 us**. This is a clear entry-cost advantage, not a claim inferred from a large-buffer benchmark.

At 1 MiB, the dirty NIF median was **2.897 ms**, versus **6.879 ms** through the port and **64.745 ms** for generated BEAM in the same run. The respective native sample ranges overlap: dirty **1.745–6.569 ms**, port **2.356–18.455 ms**. The median favors in-VM entry, but the run does not establish a universal fixed multiplier over ports.

### What the no-ops tell us

For the 256-byte input, median no-op calls were:

| Path | Median |
|---|---:|
| BL harness floor | 0.136 us |
| Regular NIF, returns initial value | 0.202 us |
| Dirty NIF, returns initial value | 6.904 us |

The dirty dispatch itself is visible without any kernel work. Moving everything to dirty schedulers would reintroduce an avoidable cost for small kernels.

These are wrapper-inclusive numbers, not the cost of one machine-code jump. Repetition counts vary with input size, and fixed batch/timer overhead is amortized differently. Do not infer that binary inspection scales with size merely because large-input no-op rows have larger timings.

### Cold versus warm

Three JIT compilations through the already-loaded NIF took **0.609, 0.139 and 0.105 ms**. A port spawn + JIT + readiness handshake took **1.708 ms**. Initial VM startup and loading the shared library are outside these values.

The original small-buffer native loss is therefore not a language or machine-code necessity: a resident port still pays serialization/transport/scheduling/decoding, while the regular NIF can enter the same native computation directly. Dirty dispatch has its own separate queue/entry cost.

### Variability matters

This workstation produced substantial timing variation and non-monotonic small/medium-size medians. For example, 4 KiB regular NIF samples were 7.651–52.028 us, while 64-byte samples were 0.481–3.101 us. The evidence supports execution tiers and broad cost differences. It does not justify a universal numeric threshold or nanosecond-level claims from one run.

## 3. Scheduler behavior

The stress suite runs in a separate VM with **one normal scheduler, one dirty CPU scheduler and two dirty I/O schedulers**. It records at least 150 ms of activity per worker phase, checks every result, measures a periodic heartbeat and compares one versus four callers. Empty heartbeat samples fail the gate rather than appearing as zero latency.

The no-load heartbeat median was 1.997 ms and p99 2.986 ms (requested timer interval 1 ms; timer resolution and scheduling are observable parts of the result).

| Workload | One-caller request p50 | Four-caller request p50 | Four-caller heartbeat p99 |
|---|---:|---:|---:|
| Generated BEAM, 1 MiB | 83.318 ms | 235.093 ms | 3.316 ms |
| Regular NIF, 4 KiB | 20 us | 32 us | 4.301 ms |
| Dirty CPU NIF, 1 MiB | 2.576 ms | 6.832 ms | 2.104 ms |

The regular and dirty rows use different buffer sizes and safety roles; they are **not** a throughput ranking against each other. Within the dirty row, contention increases request latency while the normal-scheduler heartbeat continues. Dirty execution relocates work to a bounded pool; it does not remove queuing.

Low sample counts make some tail percentiles coarse. `stress.edn` includes counts, wall windows, coverage, min/max and per-phase percentile values so those limitations remain visible.

## 4. Code lifetime and cancellation

The handle contains an optional strong reference to owned compiled code. A call clones that reference before releasing the handle lock. Close removes the handle's reference; an in-flight call keeps its own. Computation is not serialized behind the handle mutex.

Verified:

- Four concurrent callers returned independently checked values.
- Close while active code-owning calls were observed preserved successful calls and rejected later acquisitions.
- A second close returned false.
- Dropping the last worker-owned resource reclaimed its executable code.
- The benchmark ended with all five created kernels actually freed.
- The lifecycle suite ended with all three kernels freed and zero active calls.
- Forged handles, closed handles, wrong types, oversized inputs and disallowed regular work were refused.

The native unit test holds an Arc deterministically across close; the BL test exercises concurrent shutdown. The BL test sustains calls until close rather than trying to sample a single short call that can finish before its observer runs. A missed observation window is not evidence of a runtime defect.

**Kill is not native cancellation.** In the retained lifecycle run, DOWN arrived about **19 us** after killing a dirty caller; native activity drained about **6 ms** later, then the code was reclaimed. OTP can notify process death while native execution continues. A hard-interrupt or crash-containment requirement still favors the port boundary.

## 5. Hot code: one failed expectation, one useful result

Purging/deleting and recreating the NIF host module made the host available again, but an old resource handle returned `badarg` on call and close. After the old handle became unreachable and GC ran, the code was freed (`created=1, freed=1, live=0`).

Thus **old-handle compatibility across purge/recreate did not pass**. That is different from OTP's documented resource takeover during a properly designed upgrade; takeover is not implemented or proven by this probe.

The useful alternative passed: **keep the host module stable and version the compiled resources**. Two kernels coexisted with different arithmetic (old result 138, new result 9); closing the new one left the old one returning 138. This is a resource-level replacement test, not automatic BL source extraction or compiler cache invalidation.

A production design can cache a resource by validated region/version, retain old resources while callers or closures own them, and release obsolete cache references. It should not purge the NIF host for every BL function edit. Explicitly closing a handle invalidates future uses, so cache eviction and forced invalidation need different ownership policies.

## 6. Supported BEAM integration, not private ABI patching

The bridge uses `erlang:load_nif` and standard NIF binary/resource APIs. Ordinary byte-aligned binaries are borrowed; a bit-misaligned view may require an OTP temporary copy during inspection. The benchmark covers aligned buffers, not every possible bitstring layout.

Arbitrary Cranelift C-ABI code is not a drop-in BEAM function body. BEAM's JIT has private calling conventions, GC roots/safepoints, tracing prologues, reduction accounting and hot-code dispatch. The supported choices are generated BEAM, a NIF bridge, or a port—not patching a function table with an unchecked address.

Source-verified details and official links: [BEAM-ENTRY.md](BEAM-ENTRY.md).

A native memory error can still crash the whole VM. Work bounds and tested ownership reduce specific risks; they do not turn a NIF into a sandbox. Cancellation is cooperative, the dirty pool is finite, and code/binary/library lifetimes remain separate obligations.

## 7. Verification receipts

Final full command completed successfully:

```sh
BL_NO_LOCK=1 bin/bl -p research/rt-selfhost run research/rt-selfhost/invm/experiment.bl
```

Receipts include:

- 15 shared compiler/verifier/resource unit tests;
- 14 NIF bridge unit tests, including independent regular-work admission and deterministic close/free ownership;
- 623 BL benchmark assertions over 420 timing batches, plus 16 input-refusal cases and four explicit regular-cap matrix refusals;
- 44 BL lifecycle assertions;
- 49 BL scheduler/worker/heartbeat assertions;
- a passing stable-host, independent-kernel-version probe;
- a separately recorded incompatible-handle purge/recreate outcome, with successful eventual reclamation.

Review preserved evidence without rerunning workloads:

```sh
INVM_EVIDENCE=research/rt-selfhost/invm/evidence \
  BL_NO_LOCK=1 bin/bl run research/rt-selfhost/invm/report.bl
```

The evidence directory contains all samples, test logs, lifecycle/scheduling/reload/version results and the exact native IR. No Elixir/Python wrapper is required. The production runtime and committed bootstrap seed are unchanged.

## 8. Integration recommendation

Use a **stable native host with versioned compiled resources**, owned and selected by BL:

1. Generated BEAM for unproven regions, effects, generic values and computations whose native entry does not repay itself.
2. Regular NIF entry only for small, statically bounded, scheduler-accounted native work.
3. Dirty CPU entry for larger admitted batches, with bounded queueing and explicit cancellation limits.
4. A resident port when independent termination or crash containment is required.

Keep one semantic region description and one native compiler. Choose execution from the region's meaning, layout, work bound and measured cost. The production compiler still needs generalized extraction, shared eligibility, dependency invalidation and policy selection; this experiment supplies the entry and lifetime evidence for those decisions.
