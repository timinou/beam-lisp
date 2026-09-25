# Packed-byte pipeline fusion: measured results

Implemented and measured, 2026-09-21. **The pipeline, generators, orchestration, independent oracle, port driver, assertions, measurements and reporting are all BL.** No Elixir or Python driver is delivered for this experiment. Rust is confined to the existing Cranelift backend and its native unit tests.

## The exact workload

One immutable byte binary, at most 1 MiB, and a supplied u64 initial accumulator:

```text
map:     y = (3 * byte + 7) mod 256
filter:  keep y < 128
reduce:  accumulator = (accumulator + y) mod 2^64
return:  one scalar
```

This is explicitly byte semantics, not the language's grapheme-oriented string sequence semantics. A single BL descriptor in `pipeline.bl` generates both the Core Erlang module and the native IR. Admission deliberately accepts only this exact fragment; this is not automatic fusion of arbitrary user functions.

Three measured paths:

1. **RT/transducers:** the existing RT map/filter transducers, reduce/invoke and completion. The required `binary:bin_to_list` adapter is inside the timed call. Descriptor constants are captured once when constructing the pipeline, not fetched for every element.
2. **Fused BEAM:** generated Core clauses, byte access and one accumulator loop. No intermediate collections or per-element user-function dispatch. The same BL input validation precedes execution.
3. **Fused native:** the same descriptor lowered to the existing Cranelift IR; compiled once in a resident sidecar process. The timed call includes BL validation, encoding the initial accumulator, port send, input transfer/allocation, native execution, reply transfer/decoding and result handling. It does not call back into BEAM per element.

## Results

Medians of five warmed batches; times below are **microseconds per call**. Variant order rotates and reverses. Repetition counts vary with input size to keep small samples measurable. Full distributions and raw counters are retained in `evidence/summary.edn`.

| Bytes | RT/transducers | Fused BEAM | Native including port boundary | Native kernel only |
|---:|---:|---:|---:|---:|
| 0 | 31.997 | **8.904** | 75.162 | 0.174 |
| 64 | 55.096 | **16.666** | 112.795 | 0.681 |
| 256 | 51.557 | **10.222** | 47.733 | 0.988 |
| 1024 | 147.385 | 29.562 | **17.271** | 1.739 |
| 4096 | 551.223 | 147.859 | **30.958** | 7.368 |
| 16384 | 2541.785 | 632.538 | **113.243** | 37.305 |
| 65536 | 8904.427 | 2153.718 | **318.479** | 132.229 |
| 262144 | 38098.191 | 11750.907 | **1510.980** | 583.627 |
| 1048576 | 149209.911 | 50066.246 | **5264.044** | 2535.005 |

At 1 MiB:

- Fusion on BEAM alone: **2.98×** faster than the RT pipeline.
- Native including the actual port boundary: **9.51×** faster than fused BEAM and **28.35×** faster than RT.
- Native kernel alone is 2.535 ms, but the application-visible number is **5.264 ms**. Comparing only the kernel would hide roughly half the total native call time here.

The RT byte-to-list conversion diagnostic at 1 MiB had a 15.068 ms median. It is meaningful but does not explain the whole 149.210 ms baseline; eliminating collection/callback machinery is also important. Conversion measurements are reported, not subtracted from the RT results.

### Crossover and variability

The measured median crossover is between **256 bytes and 1 KiB**, not a universal threshold. At 1 KiB all five native samples (14.687–24.588 us) were below all five fused-BEAM samples (26.057–41.064 us). The margin is narrow there. At 4 KiB the ranges are widely separated: native 27.478–36.943 us versus BEAM 137.406–152.981 us.

A **4 KiB dispatch threshold** would therefore be a conservative next experiment on this host, not a threshold to hard-code into the language from one run. Small-input timings are noisy and non-monotonic; do not extrapolate a smooth cost curve from their medians.

At 1 MiB the sample ranges were native 3.080–6.818 ms versus fused BEAM 40.036–112.947 ms. The advantage survives that variability.

Cold process spawn + JIT compilation + readiness took **3.477, 1.933 and 1.485 ms**. These are separate from resident request timings. A fresh process per small call would be a bad execution strategy; this experiment keeps one sidecar alive for the timing matrix.

### Scheduler accounting

At 1 MiB, median BEAM-process reductions were approximately:

- RT: 15,831,527;
- fused BEAM: 2,097,376;
- native port wrapper: 823.

The native computation still consumes CPU in another process. Its work is **not counted as BEAM reductions**; this is scheduler-load relocation and elimination of dispatch work, not free computation. Memory fields are process snapshots, not peak allocation measurements or native-process memory totals.

## Verification

All gates passed in the complete BL-run experiment:

- **91 BL assertions** covering descriptor admission, invalid inputs, generated code, arithmetic edges and RT/fused-BEAM agreement.
- **9 native unit tests**, including read-only loop validation, framing/bounds, generated-kernel reference checks and malformed IR rejection.
- **22 fixtures × 3 paths = 66 independent-oracle value checks**. Fixtures include empty input, every byte value, all-pass/all-reject, the exact 127/128 filter boundary, initial-u64 wrap, random lengths and a 1 MiB buffer.
- **165 measured batches**, every returned value checked.
- **15 input refusals**: non-binary input, negative/too-large/noninteger initial accumulator and buffer over 1 MiB, across all paths.
- **6 wire cases**: clean EOF, valid empty input preserving u64 MAX, truncated header, truncated payload, missing initial accumulator and oversized frame.

The native arithmetic checks are in the resident driver's fixture matrix, not just the empty-buffer framing tests. The BL oracle has closed-form sanity witnesses: all 256 byte values sum to 8128 after this permutation/filter; boundary bytes 40 and 211 produce 127; the chosen wrap case produces 134.

Source review found and corrected two important measurement defects before the reported run: descriptor traversal inside every RT callback, and use of VM-wide statistics while describing per-process reductions. Neither defect is present in the retained measurements.

## Implementation and native boundary

- `pipeline.bl`: explicit descriptor, exact-fragment admission, RT baseline, generated Core and native IR. Generated Core module: **800 bytes of BEAM code** in this run.
- `build.bl`: optional standalone BL generator entry point.
- `driver.bl`: BL receive/port protocol, startup and resident measurements, correctness/refusal matrices, aggregation.
- `experiment.bl`: BL build orchestration, deterministic LCG fixtures, independent oracle, malformed-frame checks and evidence persistence.
- `report.bl`: BL analysis of saved evidence; no rebuild or benchmark rerun needed.
- `pipeline_test.bl`: normal BL test-runner suite.
- `research/j1_probe/src/fold.rs`: reusable read-only fold sidecar in the existing native backend, reusing its parser/compiler rather than introducing another native compiler.

The native side checks frame size before allocation, owns its input buffer and JIT module, fixes the loop to counter 0..length with step 1, forbids pointer/length/counter rewriting and stores, checks initialized/bounded temporaries, and restricts loads to input[counter]. The generated workload passes that envelope. Shared `Zext8` lowering was also corrected to a byte mask; malformed `subimm i64::MIN` is rejected before the existing parser can overflow in debug mode.

The high-level semantic policy remains BL-owned. The native verifier checks an execution envelope, not that arbitrary admitted native arithmetic implements this particular pipeline. The independently checked BL-generated artifact supplies that connection.

## Reproduce — BL only

From repository root:

```sh
BL_NO_LOCK=1 bin/bl run research/rt-selfhost/fusion/experiment.bl
```

This creates a fresh private `/tmp/rt-fusion.*` directory, runs the BL and native tests, builds the native release executable, executes the full comparison and writes `summary.edn` plus build/test logs and generated artifacts.

Analyze retained results without rerunning:

```sh
FUSION_EVIDENCE=research/rt-selfhost/fusion/evidence/summary.edn \
  BL_NO_LOCK=1 bin/bl run research/rt-selfhost/fusion/report.bl
```

The measured run's original directory is `/tmp/rt-fusion.Km7xF7`. Portable evidence is retained in `evidence/`: full summary, BL/native test logs, generated IR and generated Core.

## What this establishes—and does not

**Established:** for this bounded packed-byte pipeline, fusion helps on BEAM, and native execution remains substantially faster at useful batch sizes even after a real process boundary. BL can own this entire experiment and its generated semantics.

**Not established:** arbitrary map/filter/reduce fusion, effectful callbacks, escaping lazy outputs, floating-point or heterogeneous packed collections, SIMD, an in-VM NIF/JIT host, automatic backend selection, a universal crossover, or production readiness of all native probe modes. The new fold envelope does not retrofit safety into the legacy store interfaces. The raw generated BEAM loop is an internal target; the measured public BL wrapper supplies its input/cap validation.

The practical next step is a BL-owned dispatcher retaining the fused BEAM path for small buffers and reusing the native worker for larger admitted batches—not blanket native lowering of RT.
