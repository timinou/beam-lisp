null
null
null
# Final report

**We now have a source-free, self-hosted Beam Lisp implementation with demand-driven loading, selective rebuilding, safer shared lazy values, and more trustworthy analysis tools.**

“Source-free” here means **zero repository-authored `.ex` or `.exs` files**—not “no source code.” The implementation is in Beam Lisp, with Rust for selected native mechanisms. Erlang/OTP still supplies the VM and final bytecode compiler; external Elixir libraries remain usable.

The work is committed in `9a48e5bd` and `59cdb542`.

---

# 1. What changed—and why it matters

## A. Finished the self-hosted implementation

The reader, compiler, build tools and runtime hosts now come from Beam Lisp sources.

The compilation path is:

```text
Beam Lisp text
  → reader forms
  → shared intermediate representation
  → Core Erlang
  → BEAM bytecode
```

A checked-in, verified **seed of compiled bytecode** provides the starting compiler. We use that compiler to rebuild the language from its own sources.

The regenerated floor contains:

- **93 modules**
- **66 pinned host modules**
- **95 seed-directory files**

The host APIs retain their exact names—for example, `BeamLisp.Reader`—so callers do not need a parallel API or compatibility rewrite.

**What this lets us do:** change the language by editing `.bl` files, rebuild its compiler and runtime, and ship that same implementation. We no longer need to maintain an Elixir implementation beside the Lisp one.

---

## B. Changed loading from “initialize the dependency tree” to “initialize what is used”

Previously, a small command could pull in a large dependency tree. The historical startup review also found mismatched compiled generations, causing extensive source interpretation even though compiled files existed.

Now an ordinary aliased or explicitly referred dependency can remain deferred:

```clojure
(ns app
  (:require [reports :as reports]
            [math :refer [square]]))

(square 5)              ; initializes math
(reports/summary data)  ; initializes reports
```

Initialization occurs when a call, var access, macro expansion or protocol extension needs the provider.

There are deliberate exceptions:

- **Bare requires remain eager:** their purpose can be initialization effects.
- **`:refer :all` remains eager:** the public-name snapshot is needed immediately.
- Explicit loader calls initialize immediately.

Deferred dependencies retain the **search roots from their declaration**. Changing the working directory later cannot silently redirect them to another project.

Concurrent first uses share loader ownership; recursive loading retains its cycle guards. Hot reload, live rebinding and per-environment vars remain observable.

**What this lets us do:** make optional features genuinely optional at startup, without changing normal namespace semantics.

### Compiled-cache correctness was repaired too

We also:

- Check a decisive compiler-generation mismatch before expensive dependency hashing.
- Rebuild and publish a coherent generation rather than leaving a mixture.
- Replay cached initialization correctly, including record/protocol initialization.
- Avoid silently executing initialization effects twice after a failure.
- Establish the runtime correctly when a namespace is entered directly in a cold packaged VM.

---

## C. Made ordinary edits rebuild the right units

The build now distinguishes a dependency’s **implementation** from its **interface**.

In the verified fixture:

```text
Nothing changed                 → rebuild 0 units
Provider's ordinary body changed → rebuild 1 unit
Provider's interface changed     → rebuild 2 units
```

Consumers can reuse their compiled artifacts when the interface they depend on remains covered. Macro-provider and helper changes invalidate expansion-dependent consumers conservatively.

Freshness uses content—not merely timestamps or file sizes.

We also separated two build responsibilities:

- **Full build:** owns the complete inventory and can remove obsolete artifacts.
- **Scoped repair:** refreshes selected units without deleting unrelated BEAMs, manifest entries or logs.

Publication uses fresh file inodes so updating an artifact does not corrupt another artifact sharing its cache hardlink.

**What this lets us do:** edit and reload ordinary code without rebuilding the world, while keeping compiler-generation changes and macro changes appropriately conservative.

---

## D. Repaired lazy-memory admission and producer ownership

A lazy value saves realized results so later consumers can replay them. That requires both correct memory accounting and correct ownership of producer effects.

### Atomic admission

An early two-counter reservation design had a race: two publishers could each believe the same space was available.

The accepted implementation uses **one authoritative atomic occupied counter** covering committed storage and in-flight reservations. Admission checks and updates that same counter.

The retained/reserved counters remain useful diagnostics, but are not the authority for native admission decisions.

### Realize-once behavior

A fold takes ownership before running producer effects. Arbitrary reducers use replay-safe memo chunks, so stopping early with `reduced` preserves the realized prefix rather than restarting it.

If production has happened but publication is refused, that cell receives a terminal refusal and wakes its waiters. Reading it again does not rerun those producer effects.

**What this lets us do:** share lazy computations between consumers and apply a meaningful admission policy without duplicating effects or letting concurrent admitted publishers spend the same quota.

**Important limit:** this is not a hard ceiling on total process RSS. Accounting estimates saved terms, and reference-cell mutations retain a separate policy.

---

## E. Removed unnecessary copying and cursor churn

### Small state peek

Previously, asking “is this memo pending or completed?” could export the entire saved value.

There is now a constant-size **tag/version peek**. Code that needs the actual value performs a full read and validates the version.

The public full-state API is preserved.

This removes whole-value copies from tag-only decisions. It does **not** make reading a large saved result free.

### Immutable indexed cursors

A finite-input walk now shares **one native cursor root**, with immutable positions.

Advancing one consumer does not consume another consumer’s position. Replaying a position returns the same chunk.

### Conservative collection

Reference-occurrence accounting was hardened. Where closure/reference evidence is uncertain, collection fails open rather than freeing potentially live data.

**What this lets us do:** replay finite inputs and inspect lazy state with less incidental machinery, while preserving sharing and safety.

---

## F. Added narrowly proven runtime/compiler optimizations

Two optimizations were accepted:

1. **Plain-function invocation checks `is_function` first.**  
   Immutable function values skip the general kind classifier. Non-functions still use the existing callable protocol.

2. **Known own-module identity is lowered directly.**  
   When the descriptor proves a literal closure belongs to the current module, the compiler can emit that module atom instead of discovering it at runtime.

Tests preserve arity errors, failure order, capabilities, live rebinding, foreign functions and malformed-descriptor validation.

We deliberately rejected broader rewrites that could erase observable behavior.

**What this lets us do:** remove proven redundant work from hot paths without pretending reloadable namespace bindings are immutable.

There was **no new tuple optimization** to claim—the backend already performed the tested tuple folding.

---

## G. Made analysis tools understand more of the real program

### Every function clause and guard

Analysis and its consumers now inspect all function clauses, with each clause’s parameters and source guards preserved.

This affects incremental hashing, type checking, linearity checking and LSP analysis. Parameter renaming remains equivalent; changing which parameter a function uses does not.

### Safer SMT translation

SMT helper inlining selects an exact fixed arity. Guarded, variadic, ambiguous, missing or recursive cases are refused rather than translated incorrectly.

Dynamic and already-resolved helper-call forms use the same implementation. Unsupported actual arguments are checked even if a helper ignores them.

### Effects require exact evidence

We replaced blanket “this module is pure” assumptions with exact:

```text
[module, function, arity]
```

evidence.

Process state, indirect calls, callbacks, lazy forcing, native counters and unknown operations stay opaque unless specifically justified.

### Loop context follows local helpers

A potentially expensive call inside a helper can now inherit the loop context of its caller. Known foreign iterator callback positions are recognized too.

Recursion is marked as recursive rather than assigned a fictitious finite cost.

### Property shrinking preserves generator domains

Generator-aware shrinking retains both requirements:

```text
candidate remains in the generator's domain
AND
candidate still fails the property
```

Unsupported generators retain the original witness rather than inventing invalid smaller inputs.

**What this lets us do:** build more reliable editor diagnostics, incremental analysis, property tests and future optimizations. Unknown evidence remains unknown—not permission to optimize.

---

# 2. Benchmarks

These are the recorded measurements, separated by stage.

**They are not a controlled A/B experiment.** Host load and swap contention changed. No new pre-fix baseline was collected during the repair. Final measurements used `+S 8:8 +SDio 8`.

## A. Fresh CLI startup

All times below are **seconds**, including process startup.

| Command | Earlier repaired checkpoint | Final repaired image |
|---|---:|---:|
| `version`, sample 1 | 11.922067 | 9.454097 |
| `version`, sample 2 | 11.232926 | 7.465494 |
| `version`, sample 3 | 12.625752 | 8.072850 |
| `--version` | 11.304472 | 7.065186 |
| `eval` → `3` | 11.181183 | 8.471739 |
| Strict `version` | 13.375518 | 8.720416 |
| Seed check | 12.332878 | 9.866507 |

**Final `version` median: 8.072850 seconds.** All these commands exited successfully.

The historical unchanged `version` runs were:

| Sample | Wall seconds | Child CPU seconds |
|---|---:|---:|
| 1 | 124.793 | 127.999 |
| 2 | 173.873 | 160.086 |
| 3 | 164.673 | 153.939 |

So the recorded experience moved from **roughly two–three minutes to roughly seven–ten seconds**. That is an observed difference, not a controlled “X times faster” claim.

Eight seconds is still noticeable startup latency; this is not an “instant CLI” result.

Recorded final driver-child peak RSS was **161,324–173,500 KB**. That driver reports a cumulative child peak, not independent per-command retained memory.

### Startup diagnosis and structural proof

One historical instrumented boot measured:

| Phase | Seconds |
|---|---:|
| Start application | 9.003 |
| Load `vm.native` | 3.247 |
| Invoke native `build-all!` | 0.0034 |
| Load `bl.cli` | 174.419 |
| Invoke positional `version` | 8.495 |
| Entire launcher boot | 195.922 |

A separate historical trace found:

- **144** AOT-load calls
- **120** closure-hash checks, costing **16.89 s** in aggregate
- **135** reader calls
- **3,118** form evaluations
- Separate `bl.cli` load samples of **144.0 / 161.5 s**

The repaired foundation trace recorded:

- **0** loader source-load calls
- **0** AOT source-compilation calls
- **6** closure checks
- **21** initialized namespaces
- Only **3** form evaluations; application initialization explicitly registers three data readers

That instrumented checkpoint boot took **19.618208 s**, including **18.299770 s** loading `bl.cli`. It is a separate profiled run—not the final unprofiled CLI timing.

Other historical startup costs included host staging **0.45–0.67 s**, a runtime-tag probe **0.53 s**, and host installation **0.16–0.39 s**. I did not establish separate final timings for each of those components.

---

## B. Incremental rebuilding

Times are **milliseconds** for the small verified fixture, not whole-project build times.

| Change | Units rebuilt | Earlier repaired checkpoint | Final |
|---|---:|---:|---:|
| Initial build | 3 | 80.657 | 66.274 |
| Unchanged | 0 | 5.188 | 5.091 |
| Provider body edit | 1 | 38.251 | 27.941 |
| Provider interface edit | 2 | 61.072 | 50.629 |
| Unchanged after edit | 0 | 6.391 | 4.993 |

All error lists were empty.

**The portable result is the rebuild pattern `3 → 0 → 1 → 2 → 0`.** That demonstrates selective invalidation independently of the workstation’s speed.

---

## C. Final sequence-processing benchmarks

The workload maps each index/value pair to their sum, then reduces it. The checked answers were:

- 1,000 elements → **999,000**
- 4,000 → **15,996,000**
- 16,000 → **255,984,000**

All timings are **milliseconds**, with three samples per size.

| Elements | Lazy pipeline | Finite-input pipeline | Raw Erlang fold |
|---:|---|---|---|
| 1,000 | 5.351 / 6.472 / 7.372 | 4.157 / 5.346 / 7.222 | 0.037 / 0.014 / 0.015 |
| 4,000 | 29.339 / 28.947 / 26.776 | 21.089 / 22.409 / 20.329 | 0.204 / 0.076 / 0.102 |
| 16,000 | 69.951 / 82.348 / 79.977 | 56.689 / 65.156 / 67.963 | 0.279 / 0.357 / 0.262 |

“Finite-input” means the pipeline starts from a finite range; it does not mean every subsequent operation has eager semantics.

**Raw Erlang is a diagnostic lower bound.** It does not provide equivalent memo sharing, dynamic callable behavior or general collection support.

The remaining overhead is substantial. At 16,000 elements, the final runs recorded approximately:

- Lazy: **13.79 million BEAM reductions**
- Finite-input: **9.67 million**
- Raw Erlang: **55–56 thousand**

Here “reductions” means VM execution-work counters, not calls to the Lisp `reduce` function.

### Historical equivalent-answer workload

| Elements | Lazy, ms | Finite-input, ms | Raw Erlang, ms |
|---:|---:|---:|---:|
| 1,000 | 7.435 | 10.702 | 0.014 |
| 4,000 | 48.441 | 27.093 | 0.033 |
| 16,000 | 123.323 | 83.432 | 0.170 |

A profiled 16,000-element run took **376.371 ms**; profiling changes the measurement.

A separate historical callback experiment recorded:

- Core arithmetic/reduction: **140.877–159.889 ms**
- Direct BIF arithmetic/reduction: **98.087–180.050 ms**
- Raw list folds: **0.263–0.359 ms**

Those overlapping ranges did **not** establish that changing the arithmetic callback alone solved the overhead.

### Earlier repaired checkpoint—all samples

This checkpoint illustrates how much host contention could vary the timings.

| Elements | Lazy, ms | Finite-input, ms | Raw Erlang, ms |
|---:|---|---|---|
| 1,000 | 6.464 / 12.813 / 8.152 | 5.863 / 5.557 / 10.794 | 0.048 / 0.017 / 0.018 |
| 4,000 | 22.973 / 82.484 / 99.948 | 15.841 / 101.961 / 90.532 | 0.063 / 0.190 / 0.205 |
| 16,000 | 337.222 / 275.779 / 64.950 | 224.801 / 53.015 / 46.581 | 1.253 / 0.337 / 0.218 |

### Earliest integration probes

The integration roster retained these **historical quoted observations** at 2,000 / 4,000 elements:

| Operation | Earlier source-free baseline, ms | Integrated lazy engine, ms |
|---|---|---|
| `map-indexed` | 13,467 / 56,807 | 20 / 36 |
| `keep-indexed` | 7,884 / 26,032 | 10 / 40 |
| `distinct` | 27,075 / 105,426 | 33 / 56 |

The baseline timed out before finishing the remaining cases. These runs were explicitly recorded under changing load/swap, so they are **not valid general speedup factors**. They are also different probes from the map-and-reduce table above.

---

## D. Memo reuse and retained memory

For a held 16,000-element mapped sequence:

| Measurement | Earlier repaired checkpoint | Final |
|---|---:|---:|
| First count | 13.383 ms | 31.248 ms |
| Second count | 0.720 ms | 3.694 ms |
| Completed memo estimate | 256,024 bytes | 256,024 bytes |
| Native retained counter before/after second count | 633,952 bytes, unchanged | 634,928 bytes, unchanged |
| Reserved bytes | 0 | 0 |

The historical review also recorded a second count of **2.624 ms**, with **two dirty reads**.

The repaired measurements recorded **one dirty read, one fast read and one peek** for the second count.

**What this proves:** repeated consumption reused the held computation without increasing its native retained counter.

**What it does not prove:** every repeated count is faster than every historical sample, or that repeated reads allocate nothing. The final second count was slower than both recorded earlier second-count samples.

Final diagnostics recorded **522 live cells**, **one fail-open collector abort**, and **zero collector anomalies**. That is safety evidence, not proof that collection never retains excess data.

---

## E. Historical hot-path counters

One historical 16,000-element profiled pipeline recorded:

| Operation | Calls |
|---|---:|
| Runtime-body `kind-kind` | 776,795 |
| Runtime-body `invoke` | 131,424 |
| `Env.fetch!` | 33,561 |
| `Env.own-module` | 33,565 |
| `tuple_to_list` | 229,118 |
| `setelement` | 228,543 |
| `make_tuple` | 228,074 |
| Memo dependency walk | 62,509 |

These explained why we targeted dispatch, module identity, copying and dependency machinery—not only arithmetic.

The new plain-function tests prove that **that invocation path skips `kind-kind`**. We did not establish a final whole-pipeline count showing every classification disappeared.

---

# 3. What was verified

| Gate | Recorded result |
|---|---|
| Native Rust tests | **29 passed** |
| Analysis/callable/loop/shrink compatibility | **125 tests / 312 assertions**, zero failures/errors |
| Memo/cursor/collector/replay | **107 tests / 1,103 assertions**, zero failures/errors |
| Published bootstrap/cache/generation/loading/emitter ABI | **19 files passed**, zero failed or incoherent |
| Runnable instructional documents | **4 passed** |
| Authored Elixir inventory | **0 `.ex`, 0 `.exs`** |

These bundles overlap; they must not be added into a claimed unique test total.

## Packaged-release proof

The final compound executable:

- Rebuilt the **309 tier sources**
- Included **375 Lisp sources**: 309 tier sources plus 66 hosts
- Was **147,352,288 bytes**, including its bundled runtime/payload
- Matched **all 95 seed files** against the checkout
- Matched the current native lazy-memo library byte-for-byte
- Contained no Elixir sources in `priv`

Outside the repository, these passed:

```text
version
eval (+ 1 2) → 3
lazy count → 65
strict version
```

The audit first caught a stale packaged native library. We rebuilt the package and required the identity audit to pass.

**The CLI benchmark timings above are not separately measured compound-executable startup timings.** The compound has cold/strict execution proof, but I did not record its own latency series.

---

# 4. Documentation and reproducibility

After the runtime work, I updated the original guides in place:

- Self-hosting overview and runnable compiler tour
- Namespace loading
- Interface keys and selective rebuilding
- Lazy realization and shared-memory contracts
- Generator-domain shrinking
- Native plan and original performance reviews

The guides describe current behavior simply. Historical results remain labelled historical rather than being presented as current measurements.

The detailed report is:

[`!tasks/artifacts/performance-postfix-results.md`](!tasks/artifacts/performance-postfix-results.md)

Full measurements and archived raw logs are in:

- `performance-final-measurements.json`
- `performance-postfix-measurements.json`
- `performance-evidence/`

---

# 5. What this now lets us do

### Develop the language in the language

Edit Lisp sources for the reader, compiler, runtime and build system; regenerate a verified seed; ship the resulting implementation.

### Build larger applications without initializing everything

Declare optional dependencies normally and initialize them when needed. Initialization-only dependencies remain explicitly eager.

### Iterate without rebuilding the world

Ordinary body edits can rebuild only their provider. Interface and macro changes invalidate the affected consumers.

### Share lazy work more safely

Multiple consumers can reuse realized values and immutable cursor positions. Admission refusal does not silently replay already-produced effects.

### Trust analysis more—and optimize from evidence

Multi-clause functions, effects, arities and local loop contexts are represented more accurately. That provides a stronger foundation for future optimization without treating unknowns as proofs.

### Produce auditable releases

We can compare packaged seed/native bytes, run outside the checkout, and require strict boot—not merely observe that the development tree works.

---

# 6. What remains unfinished or limited

**The repository-wide suite is not established green.** Its historical failures/timeouts remain a separate follow-up. Focused gates and release proof do not erase that limitation.

Also not supplied by this work:

- Universal or cross-source/dynamic cost inference
- Complete host/NIF type and effect knowledge
- Cached namespace dispatch that bypasses live bindings
- General beta reduction or recursive-scaffold lifting
- Destructive cursors
- A graph-lock shortcut without atomic cycle safety
- A total-process memory ceiling
- Raw-Erlang-equivalent sequence performance

**Bottom line:** we moved from a self-hosted implementation with costly stale/loading paths to a coherent, selectively loaded and rebuilt system—with safer lazy execution, stronger analysis, and an audited release. The measurements show a substantially better recorded experience; the strongest lasting results are the structural guarantees and their tests.
null
