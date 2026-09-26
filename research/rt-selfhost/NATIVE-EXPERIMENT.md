# P3 — live native vs compiled-BEAM byte fold: a bounded experiment

Status: research-only experiment. Measurements 2026-09-21 on a checkout at
`8f30226b`; harness ported to all-BL 2026-09-22.
Scope: `research/j1_probe`, `research/native-offload`, `research/rt-selfhost`.
No production code, no seed, no `krt/kind.bl` / `krt/seq.bl` change.

This document records **one bounded differential**: the standalone Cranelift
probe (`research/j1_probe`, `--run-ir`) and beam-lisp computing the same u64
checksum over the same byte buffers, with process startup measured separately
from each side's reported inner time.

The harness is now beam-lisp: `research/rt-selfhost/native_experiment.bl`. It
replaces the former `native_experiment.py` (deleted) and the Elixir `.exs`
driver that harness wrote. Fixture generation, the independent oracle, process
spawn, output parsing, assertions, timing, reporting and the summary are all
BL; the only non-BL thing the script touches is the `j1_probe` PROCESS it
spawns.

## Current reproduction — all BL

Three columns, per fixture, over identical bytes:

- **native** — `j1_probe --run-ir research/rt-selfhost/native_probe.ir FIXTURE VALUE_FILE`,
  once per fixture. `VALUE_FILE` holds the compiled-BEAM value, so the probe's
  own `rust-ref-match` (JIT vs its Rust twin) and `bl-match` (Rust twin vs that
  file) both apply.
- **BLcompiled** — `native_probe/checksum`, obtained by
  `BeamLisp/run_file "research/rt-selfhost/native_probe.bl"` *inside this VM*.
  `run_file` goes through the self-hosted compiler (`compiler/eval_form` ->
  `lower/eval-anf`), so this is compiled BEAM — not the tree interpreter, and
  not an AOT beam loaded behind an `.exs` wrapper. Evidence recorded in the
  summary: the interned `checksum` is an external fun
  `{module: Elixir.BeamLisp.Ns.NativeProbe, name: :checksum, arity: 2,
  type: :external}`, and `code.which/1` answers the namespace module.
- **oracle** — an independent BL twin in the harness: a `reduce` over the
  buffer's byte list with an explicit `band 2^64-1` per step. `native_probe.bl`
  uses an indexed `loop`; the oracle uses a list `reduce`. Two code paths, one
  pinned u64 contract.

The harness asserts, per fixture: probe `rc = 0`, byte count, `jit == BLcompiled
== oracle`, and both probe flags true. Any mismatch throws.

Probe binary. By default the harness builds `research/j1_probe` into a private
`CARGO_TARGET_DIR` inside the run's scratch directory and uses exactly the
executable that build produced — a cached executable at a predictable path is
never trusted. `NATIVE_PROBE=/abs/path/to/j1_probe` instead runs an already
built binary, after an existence check; that explicit opt-in is the only way a
pre-existing executable is used.

Run (from the repository root):

    BL_NO_LOCK=1 NATIVE_PROBE=/abs/j1_probe bin/bl run research/rt-selfhost/native_experiment.bl
    # or, to build the probe into the private target dir first:
    BL_NO_LOCK=1 bin/bl run research/rt-selfhost/native_experiment.bl

Raw logs (`native_<fixture>.log`, `beam_<fixture>.log`, and `cargo_build.log`
when it builds) plus `summary.edn` go under a fresh `mktemp -d` directory; the
script prints `SUMMARY <dir>/summary.edn` last. `bl_value_<fixture>.txt` are the
expected-value files handed to the probe.

### Result (fresh run, `8f30226b`)

    BL_NO_LOCK=1 NATIVE_PROBE=/tmp/rt-invm.5CIEZw/cargo-target/release/j1_probe \
      bin/bl run research/rt-selfhost/native_experiment.bl

work dir `/tmp/rt-native-experiment.o8qj7V`; summary copied to
`evidence/native-summary-bl.edn`.

| fixture | bytes | expected | native jit | BLcompiled | agree | rust-ref | bl-match | native inner | native wall ns | BL best ns |
|---|---:|---:|---:|---:|:--:|:--:|:--:|---:|---:|---:|
| `empty` | 0 | 0 | 0 | 0 | ✓ | ✓ | ✓ | 161 ns | 2 213 423 | 260 |
| `one` | 1 | 170 | 170 | 170 | ✓ | ✓ | ✓ | 150 ns | 2 155 374 | 60 |
| `small` | 64 | 9742576119638844960 | 9742576119638844960 | 9742576119638844960 | ✓ | ✓ | ✓ | 912 ns | 5 577 529 | 12 133 |
| `ff13` | 13 | 4634958717477794239 | 4634958717477794239 | 4634958717477794239 | ✓ | ✓ | ✓ | 741 ns | 6 008 741 | 901 |
| `large` | 1048576 | 8383099488808122916 | 8383099488808122916 | 8383099488808122916 | ✓ | ✓ | ✓ | 1.829911 ms | 6 712 223 | 85 157 022 |

`all-agree=true`. The values reproduce the historical dataset below exactly;
the inner/wall times are host-load dependent and are not a speedup claim.

Both probe paths were exercised: the run above with `NATIVE_PROBE` set, and a
default-build run with it unset (`cargo build --release` into the private
target dir took 47.6 s and produced
`/tmp/rt-native-experiment.NQfvSP/cargo-target/release/j1_probe`).


## 0. Non-claims (read first)

- **No safety certificate.** Agreement on five fixtures is a differential test,
  not universal equivalence, not a proof, and not a licence to execute native
  code in-VM.
- **No integrated host.** There is no JIT NIF, no Rustler cdylib, no in-VM
  dispatch, no resource-lifetime or concurrency validation here. The probe is a
  **standalone process**; the harness shells out to it exactly as
  `research/native-offload/offload.bl` does.
- **The eligibility gate is not exercised.** The harness runs the probe
  directly. It does not consume `native.eligible`, and it adds none of the
  input-sort / bounds / ownership / work-bound checks NATIVE-PLAN §2 says are
  missing. See §7.
- **Not the production semantic policy.** The u64 wrap in `native_probe.bl` is
  an explicit, pinned contract for this experiment. It is *not* the runtime's
  default numeric behaviour (see §6, finding F2).
- No speedup target was assumed; the point is to publish what was measured and
  what was not.

## 1. What was inspected

| piece | what it does | what this experiment uses |
|---|---|---|
| `research/j1_probe/src/main.rs` | Cranelift JIT over a small counted-loop IR; kernels authored in Rust and parsed from IR text | `--run-ir IR_FILE BUF_FILE [BL_VALUE_FILE]` — compiles the IR, runs it once over the file's bytes, prints inner `dt`, `jit=`, `rust-ref-match=`, `bl-match=` |
| `research/native-offload/offload.bl` | shell-to-probe pipeline: gate → lower → JIT → differential oracle | inspected and run once to produce the canonical lowered IR; not modified |
| `research/lowerers_spike/lower2.bl` | defn → j1 IR text via the shipped proof engines | its output (`/tmp/offload_kernel.j1`) is the IR fixture |
| `research/lowerers_spike/beam_baseline.bl` | the earlier "bl-on-BEAM" baseline | found to wrap at 2^59, i.e. **not** the native kernel's semantics (§6 F2) |
| `lib/beam_lisp/aot.ex` | AOT emits `BeamLisp.Ns.Body.<Ns>` (real functions) + `BeamLisp.Ns.<Ns>` (shim + `__bl_init__/0`) | historic harness: the compiled BEAM baseline called the **body module** of the AOT artifact directly |
| `lib/beam_lisp.ex:run_file/1` | `Compiler.eval_string` calls `compiler/eval_form` → `lower/eval-anf`; source execution also compiles to BEAM | current harness: `run_file` compiles `native_probe.bl` in-process; the interned `checksum` is an external BEAM fun. The AOT body module the historic harness called is no longer part of the live path |

## 2. Artifacts

| file | role |
|---|---|
| `research/rt-selfhost/native_probe.bl` | the compiled-BEAM subject: `checksum [bin n]` with explicit `(… band 18446744073709551615)`, plus `run-file`/`main` emit the checksum and best-of-3 inner time |
| `research/rt-selfhost/native_probe.ir` | the canonical 9-line IR lowered from the same kernel by `lower2` (produced by the `native-offload` pipeline) |
| `research/rt-selfhost/native_experiment.bl` | the current all-BL harness: fixtures, oracle, `run_file` of the subject, probe runs, agreement checks, assertions, scratch-dir logs + `summary.edn` |
| `research/rt-selfhost/NATIVE-EXPERIMENT.md` | this report |

Raw outputs per run (fresh `mktemp -d`, printed as `SUMMARY <dir>/summary.edn`):

```
<dir>/
  native_<fixture>.log         probe process: full command, rc, wall_ns, report line
  beam_<fixture>.log           compiled-BEAM samples: warm pass + 3 monotonic ns samples, value
  cargo_build.log (if built)   private-target-dir cargo build of j1_probe
  fixtures/*.bin               the generated buffers
  bl_value_*.txt               the compiled-BEAM value handed to the probe as its oracle
  summary.edn                  machine-readable result of the run
```

Historic Python/AOT outputs (`/tmp/rt-native-experiment/`), preserved for
reference: `probe_main.txt`, `offload_pipeline.txt`, `aot_build.log`,
`native_<fixture>.log`, `beam_<fixture>.log`, `beam_startup_0..2.log`,
`fixtures/*.bin`, `bl_value_*.txt`, `summary.json` — and
`evidence/native-summary.json`.

## 3. Reproduction

The current path is the all-BL command in "Current reproduction — all BL"
above. The historic Python entry point
(`BL_NO_LOCK=1 python3 research/rt-selfhost/native_experiment.py`) and the
`.exs` driver it wrote are gone from the tree, so they are not reproduced here.

For the record, the historic harness: (0) built the crate into a private
`CARGO_TARGET_DIR`; (1) produced/kept the canonical lowered IR; (2) AOT-compiled
`native_probe.bl` with `bin/bl build --out <dir>`; (3) loaded the emitted
`BeamLisp.Ns.Body.NativeProbe` from an Elixir `.exs` driver run as
`elixir -pa build -pa <dir> <driver>.exs <fixture>` and compared against it.

The current harness replaces steps (2)–(3) with `BeamLisp/run_file` of
`native_probe.bl` in-process: the subject is compiled into this VM and the
interned `checksum` is called directly. `bl run` is compiled — the self-hosted
`compiler/eval_form` -> `lower/eval-anf` path — not the tree interpreter.

## 4. Fixtures (deterministic)

| fixture | bytes | contents |
|---|---:|---|
| `empty` | 0 | zero-length buffer (the probe's zero-support case) |
| `one` | 1 | single byte `0xAA` |
| `small` | 64 | 64 LCG bytes |
| `ff13` | 13 | `0xFF * 13` — the first length where `acc = acc*31 + b` exceeds 2^64 (all-ones, so it wraps on the 13th step) |
| `large` | 1048576 | 1 MiB LCG stream, byte-identical to `j1_probe`'s own `fill()` (`sha256 16624fd5b84d74e9…`) |

The LCG in the harness is the probe's: `x = x*6364136223846793005 + 1442695040888963407; byte = (x >> 33) & 0xFF`. Verified byte-identical to the probe's dumped `/tmp/j1_buf_1m.bin`.

## Historical dataset (Python/AOT harness, 2026-09-21)

Sections 5–6 are the measured record of the original harness: a Python
orchestrator plus an Elixir `.exs` driver that AOT-loaded a `bin/bl build`
emitted `BeamLisp.Ns.Body.NativeProbe` beam. That harness no longer exists in
the tree; its figures and its raw evidence JSON (`evidence/native-summary.json`)
are preserved as a historic dataset, not as a currently reproducible command
path. Sections 0 and 7–9 are general limits and next-step notes that still
apply.

A later Python-harness rerun (work dir `/tmp/rt-native-experiment-dxk3zzk6`,
summary retained as `evidence/native-summary.json`) measured 1 MiB inner times
of 2.129878 ms native and 145.657 ms compiled BEAM (best of three), with
standalone walls 6.79 ms and 1577.47 ms. That is another run, not a replacement
for the figures below. Tiny BEAM timings rounded to zero microseconds are not
speedup evidence.

## 5. Results (historic run)

Values — **all three independent implementations agree on every fixture**,
including zero-length and u64 overflow:

```
fixture    bytes             expected   native jit(1)  compiled BL(2)  python twin(3)
empty          0                    0               0               0               0
one            1                  170             170             170             170
small         64   9742576119638844960  9742576119638844960  same  same
ff13          13   4634958717477794239  4634958717477794239  same  same
large    1048576   8383099488808122916  8383099488808122916  same  same
```

(1) Cranelift JIT of `native_probe.ir` via `j1_probe --run-ir`; the probe's own
`rust-ref-match=true` and `bl-match=true` are both true for all five (the probe
compares its JIT against its Rust twin *and* against the value file the harness
fills with the compiled-BEAM checksum). (2) `BeamLisp.Ns.Body.NativeProbe.checksum/2`,
AOT-compiled BEAM — the historic harness's compiled subject. (3) `twin_checksum`
in the historic Python harness; the current harness's independent oracle is the
BL `reduce` twin described above.

Timing — inner time is what each side reports about the kernel itself; wall is
the whole standalone process:

| fixture | native inner | native wall (startup+compile+exec) | compiled-BEAM inner (best of 3, after 1 warm) | compiled-BEAM wall (VM boot + load + 4 passes) |
|---|---:|---:|---:|---:|
| `empty` | 160 ns | 2.74 ms | 0 µs | 1031.3 ms |
| `one` | 140 ns | 3.82 ms | 0 µs | 1245.0 ms |
| `small` (64 B) | 621 ns | 5.44 ms | 5 µs | 1157.6 ms |
| `ff13` (13 B) | 221 ns | 2.10 ms | 0 µs | 918.3 ms |
| `large` (1 MiB) | **2.232 ms** | 8.93 ms | **128.394 ms** | 1927.5 ms |

Compiled-BEAM standalone startup (boot + `ensure_loaded`, no kernel), 3 samples:
**913.8 / 980.5 / 970.4 ms** — best 913.8 ms.

Derived, 1 MiB only:

```
native inner    2.232 ms / 1 MiB  =   2.13 ns/byte
compiled inner  128.394 ms / 1 MiB = 122.45 ns/byte
inner ratio                          ≈ 57.5x   (native faster)
wall ratio (1927.5 ms / 8.93 ms)     ≈ 215.8x  (startup-dominated; see §6 F4)
```

Raw report lines (verbatim from the logs):

```
lowered-IR kernel 'checksum' over 0 bytes: 160ns   jit=0  rust-ref-match=true  bl-match=true
lowered-IR kernel 'checksum' over 1 bytes: 140ns   jit=170  rust-ref-match=true  bl-match=true
lowered-IR kernel 'checksum' over 64 bytes: 621ns   jit=9742576119638844960  rust-ref-match=true  bl-match=true
lowered-IR kernel 'checksum' over 13 bytes: 221ns   jit=4634958717477794239  rust-ref-match=true  bl-match=true
lowered-IR kernel 'checksum' over 1048576 bytes: 2.232443ms   jit=8383099488808122916  rust-ref-match=true  bl-match=true

BL-COMPILED path=…/empty.bin n=0 value=0 best_us=0
BL-COMPILED path=…/one.bin n=1 value=170 best_us=0
BL-COMPILED path=…/small.bin n=64 value=9742576119638844960 best_us=5
BL-COMPILED path=…/ff13.bin n=13 value=4634958717477794239 best_us=0
BL-COMPILED path=…/large.bin n=1048576 value=8383099488808122916 best_us=128394
```

### Measurement protocol, stated plainly (it is not symmetric)

- **native inner** is a *single* call inside a freshly launched probe process
  (cold caches, but the kernel is compiled immediately before it).
- **compiled-BEAM inner** is the *best of 3* timed passes after one warm pass.
  This **favours the BEAM side**; the 57.5x is therefore conservative for the
  native kernel.
- The sub-microsecond native numbers are at/near the clock's resolution; do not
  read them as kernel throughput.
- Host was shared with other agents (wall numbers vary; the startup samples
  spread ~7%). Only the 1 MiB row is large enough to be load-insensitive in
  proportion.

## 6. Findings

**F1 — the differential holds exactly, including the edges.**
Zero-length (the probe's `--run-ir` handles a 0-byte file; the kernel's counted
loop never runs) and the first-overflow case (13 x `0xFF`) both agree across
Cranelift-native, compiled BEAM, the probe's Rust twin and a Python twin. No
CLI change or conservative workaround was needed to get generic buffer sizes or
zero support; see §8.

**F2 — the earlier BEAM baseline measured a different function.**
`research/lowerers_spike/beam_baseline.bl` wraps at `576460752303423488` = 2^59
with the comment "*acc bounded to the BEAM smallint range (mod 2^59) so the
baseline measures per-op machinery, not ever-growing bignums*". BEAM arithmetic
promotes to bignums transparently — the bound was unnecessary, and it makes the
baseline **not the native kernel's semantics**. The probe says so itself:

```
$ /tmp/rt-native-experiment/cargo-target/release/j1_probe        # (main, self-check)
rust-checksum-MOD59-of-file 312648956560194084
rust-checksum-of-file 8383099488808122916 (1 MiB)
```

A mod-2^59 baseline cannot license any claim about a wrapping-i64 kernel.
`native_probe.bl` pins the u64 contract with an explicit `erlang/band` mask and
proves it by agreeing with the probe's Rust reference.

**F3 — compiled BEAM is the honest BEAM baseline, and it changes the number.**
The `native-offload` pipeline (log: `offload_pipeline.txt`) reports the
*interpreter* baseline for the same 1 MiB kernel:

```
BEAM interp: 589222 µs   |   lowered-IR kernel 'checksum' over 1048576 bytes: 2.363789ms …
```

589.2 ms (interpreted) vs 128.4 ms (compiled) → **≈ 4.6x**, on this host. The
earlier "440–800x" figure mixed JIT-inner against *interpreted* BEAM. Against
**compiled** BEAM, with matching semantics, the same comparison is **≈ 57.5x**.

**F4 — at 0/1/small sizes the question is startup, not throughput.**
Native inner is 140–621 ns, but the standalone probe process is ~2–5 ms; the
compiled-BEAM process is ~0.9–1.2 s because the historic harness launched a
fresh BEAM VM per measurement, paying a full `BeamLisp.AOT.boot()` + module
load. The 215.8x *wall* ratio at
1 MiB is therefore partly the BEAM's one-time boot, which a long-lived host
would pay once, not per call. The experiment cannot answer "crossover in a warm
host" — it only separates *inner* from *standalone* honestly.

**F5 — what the historic compiled BEAM kernel was.**
`beam_lib:chunks(Body.NativeProbe, [imports])` on the historic AOT artifact
shows the compiled fold
dispatches arithmetic through the numeric tower:

```
{'Elixir.BeamLisp.Num', add, 2}, {'Elixir.BeamLisp.Num', mul, 2},
{'Elixir.BeamLisp.Num', lt, 2},  {'Elixir.BeamLisp.Num', ge, 2},
{binary, at, 2}, {erlang,'*',2}, {erlang,'+',2}, {erlang,'<'/2}, {erlang,band,2}, …
```

`Num.add/2` and `Num.mul/2` are guarded `is_number` fast paths, but they are
still a call per operation. So 122 ns/byte is "BL semantics with the numeric
tower", not a hand-written byte loop — which is the correct baseline for a
claim about lowering *BL*.

## 7. Eligibility incompleteness (explicit)

The pipeline's gate (`research/native-eligible/eligible.bl` →
`priv/lib/system/analyze.bl`, `system.smt`) returned for `checksum`:

```
checksum: ELIGIBLE → lowered (9 IR lines) → JIT
  differential oracle: BEAM=8383099488808122916  JIT=8383099488808122916  ✓ IDENTICAL
```

That verdict is purity ∧ termination ∧ return-sort. It does **not** carry, and
this experiment did **not** add:

1. **Input sorts at the boundary.** The native signature is two raw `i64`s; the
   verdict reasons about the BL value, not the pointer/len pair.
2. **Overflow semantics.** BL integers are arbitrary-precision; the native
   kernel is wrapping i64. They agree here *only because the BL source explicitly
   applies `band 2^64-1`*. The verdict's `:sort Int` is satisfied by both a
   bignum and an i64 — the same sort name denotes different value domains.
   This is exactly the gap F2 exposed; a real offload contract must prove or emit
   the wrap, never assume it.
3. **Buffer length / bounds.** The probe trusts `len == file length`. No proof
   that `len ≤ byte_size(buf)`; no read/write bound certificate.
4. **Aliasing / ownership.** Not modelled; `--run-ir` is a read-only fold so it
   does not exercise the hazard, but the gate has no ownership theorem.
5. **Maximum work / scheduler bound.** `eligible.bl` itself labels its work bound
   "*first-cut*". A 1 MiB fold is ~1M iterations in one dirty call with no
   cancellation or yield policy; the gate does not bound it.
6. **One shared verdict.** NATIVE-PLAN §2 notes `priv/lib/system/prove.bl`'s
   `native-eligible?` and the LSP predicate are weaker parallel predicates.
   Nothing here reconciles them — no production edit was made.
7. **Refusal coverage.** Only the pipeline's existing refusal was observed
   (`dot` → `:not-in-fragment` / `:impure`, from `offload_pipeline.txt`). No
   refusal test for unsafe sorts, out-of-bounds lengths, or work limits was
   added or run.

Consequently: the gate has **not** been shown sufficient for execution safety,
and this experiment does not claim it is.

## 8. Probe CLI limits / refusal report

- `--run-ir IR BUF [BLVALUE]` supports **arbitrary buffer size including 0**
  (verified on the `empty` fixture: `jit=0`, `rust-ref-match=true`). No
  conservative workaround or CLI change was required.
- It supports exactly the fold kernel shape: IR with `ret acc`, signature
  `(i64, i64) -> i64`. The store shape must go through `--run-store`, which
  allocates its own output and accepts 3/4/5 params; the frame server is
  `--serve-store`.
- No SIMD vocabulary, no bounds checks, no length oracle beyond the caller
  passing the right `len`; the harness is the caller and passes
  `byte_size(file)`.
- The shared prebuilt binary at `/home/user/.cache/cargo-target/release/j1_probe`
  predates `src/main.rs`; this experiment rebuilt the crate into its own target
  dir, so its results are from the current source.

## 9. What a next experiment would owe

- A warm-host comparison (one long-lived BEAM process vs one long-lived probe
  process) to replace the standalone-wall column, and a conversion-inclusive
  crossover: buffer copy/pinning + scheduling, not just file read.
- A single eligibility verdict carrying input sorts, explicit overflow
  semantics, bounds, ownership and a real work bound — then refusal tests.
- If in-VM integration is ever attempted: resource lifetime, concurrent calls,
  invalid handles, hot replacement (NATIVE-PLAN §2 gate).
