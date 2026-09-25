#import "_preamble.typ": guide, decision, recipe, exercise

#let chapter = [
= 6 · Building and checking

Extending the region family is engineering with proof obligations, not just
code. A compiled artifact is a *claim* that it computes the same meaning as
the generic path. Its checks make the contract concrete and give useful
feedback when an extension changes the result. This chapter works one
small extension end to end, gives the checklist, and states the rules for
measuring and for shipping.

== The artifact you start from

The shipped prototype is one descriptor, admitted by exact equality, lowered
by one generator. Its shape is inspectable without a build:

```clojure
(fusion.pipeline/admitted? fusion.pipeline/descriptor)   ; true
(fusion.pipeline/native-ir fusion.pipeline/descriptor)   ; the IR text
```

The exact prototype gate names departures before lowering. Generalisation
replaces equality to one descriptor with checks over a defined family:
operations, parameter ranges, layouts, effects and work bounds. Widen the
family by adding justified rules, while keeping refusal explicit.

Different constants can belong to one parameterised family; their values
participate in artifact identity. Changing a reduction from sum to minimum
changes the operation's meaning and calls for a distinct contract. Neither
case requires another hand-maintained compiler.

== Worked recipe: from filter-plus-sum to filter-plus-min

The shipped reduce is a wrapping u64 sum. Here is a sibling, written as a
design recipe — it is not shipped.

*1. State the meaning.*

```
for each byte b of one immutable binary:
    y   = (3*b + 7) mod 256
    keep y when y < 128
    acc = min(acc, y) for kept y
return acc
```

A machine loop does not invent the edges, so write them down:

- *Empty.* The loop never runs and the call returns the supplied initial
  accumulator. A minimum over nothing has no value, so the contract is that
  the caller supplies the identity (`2^32 - 1`) and empty returns it. Say
  this; never let `0` appear by accident.
- *Overflow.* `min` cannot overflow, and retained values stay below 128; the
  byte map stays `mod 256`. Contrast the shipped sum, which *must* name
  `mod 2^64`. State the arithmetic contract: exact, checked, saturating or
  wrapping. A machine-word lowering needs a range proof or the matching
  declared overflow behaviour; otherwise use an exact-capable path.
- *Short circuit.* None. A full scan always runs. Returning early when the
  floor is reached would be a different loop shape — outside the read-only,
  single-loop envelope — and would need its own semantics and admission.

*2. Give the fragment a new identity.* New `:pipeline`, new `:version`, and
`:reduce {:op :min-u32 :identity 4294967295}`. The byte map, the filter and
the layout are unchanged. Admit an initial accumulator in the u32 range.
The IR's `lt` is signed: u32 values stay below `2^63`, so this comparison
implements the intended numerical minimum. Refuse an out-of-range initial
value before entering the fragment.

*3. Lower it twice from the one descriptor.* The BEAM loop keeps its shape and
its reduce becomes "the smaller of the accumulator and the retained byte". The
native lowering needs no new opcode: the allowlist already has a signed
compare and a branchless select.

```text
kernel fused-min 3
init 3 0
load 4 0 3
imm 5 3
mul 6 4 5
addimm 7 6 7
udivimm 8 7 256
imm 9 256
mul 10 8 9
sub 11 7 10
imm 12 128
lt 13 11 12
lt 20 11 2
sel 21 20 11 2
sel 2 13 21 2
loop 3 1 1
ret 2
```

The accumulator is var 2, the counter var 3, the limit var 1; the only memory
read is `load` with base 0 and offset the counter.

*4. Check the envelope.* The verifier in `research/j1_probe` admits a
read-only, single-loop, counter-`0..length` kernel and refuses everything else
by name: no `store`, no writes to pointer, length or counter, one pointer with
sequential offsets, a power-of-two divisor. The recipe stays inside it, so the
verifier needs no change. But the verifier checks the *envelope*, not the
arithmetic: it will admit a kernel that computes something else.

*5. Write an independent oracle.* This is the step most often skipped. The
compiled paths are two outputs of one generator, so agreement between them
alone cannot establish the meaning. Write the reference separately. For a
compiler pass, retain a route that evaluates the original program without
re-entering the same optimisation being checked:

- the generic BL path — the transducer pipeline a user would write — is the
  reference semantics;
- add closed forms where they exist. Over a full byte sweep, `y = (3*b + 7)
  mod 256` hits 0 at `b = 83`, so the minimum over all 256 values is 0; byte
  40 maps to 127 (kept) and byte 211 maps to 128 (rejected), which pins the
  filter boundary.

Then check properties over the admitted domain, not one example:

- the result is the identity or one of the retained values;
- the result is at most every retained value;
- permuting the input does not change the result;
- empty input returns the identity exactly.

*6. Make refusal visible.* Every entry validates before it works and refuses
identically, so a refusal is a property of the contract and not of the path
that happened to run. In process, admission throws with the full list of
departures. At a process boundary, a malformed frame is refused with a nonzero
exit code and a diagnostic on stderr — never a plausible value on stdout.

== The checklist

#recipe[
  1. State the meaning: pure, total, known, bounded, with the numeric rule and
     the evaluation order.
  2. Give the fragment an exact identity and version; refuse an unknown key.
  3. Fix every capture; read no dynamic state inside the loop.
  4. Keep the envelope: read-only, one counted loop, the counter/limit/return
     contract, power-of-two divisors.
  5. Write an independent oracle and the edges: empty, all-reject, the exact
     boundary, maximum size.
  6. Check the refusal paths: nonzero exit, stderr diagnostic, no partial
     output.
  7. Freeze a version key: descriptor hash, semantic and representation
     version, compiler and backend version, CPU features.
  8. Keep the host stable; version the resource; free code only when the last
     owner releases it.
]

== Compiled artifacts are claims; the reference is the generic path

Say which side is the reference, and mean it.

The *generic BL implementation* is the reference meaning. It is the path a
user would write, and it is trusted because it is what always runs when a
region is refused. A compiled artifact is a claim that it agrees with that
meaning. When the reference is itself compiled — the shipped runtime, or a
fused module — label it as the trusted implementation to check against, not
as ground truth by construction. Where a closed form exists, use it too; it is
independent of both.

Two lowerings of one descriptor agreeing is evidence that the generator is
deterministic. Keep that check and label it correctly. It is not evidence
about meaning.

#decision(because: [
  a comparison between two artifacts of the same generator can pass while both
  are wrong in the same way; only a separately written reference can catch a
  shared mistake.
])[
  The oracle is written independently of the generator. Agreement between two
  compiled paths is a different, weaker check.
]

== Measuring a region honestly

- *Warm the loop.* Compile once; time steady-state calls separately from the
  cold compile and readiness phase. They answer different questions.
- *Report distributions.* Medians and ranges from a stated number of samples,
  not a single number. Small samples are noisy and non-monotonic.
- *Include the boundary and the output.* Validation, transfer, decode and
  result handling are part of the call; a kernel-only number is not the cost a
  caller pays.
- *Vary the size.* Do not draw a smooth cost curve through noisy small-input
  medians.
- *Stress the scheduler and the lifetime.* Run with one ordinary and one dirty
  scheduler beside a heartbeat; close a handle while calls are active; version
  a resource, then check the old handle still answers.
- *Replay the record.* Once a run is recorded, analyze the record rather than
  rerunning the benchmark.

The entrypoints are real BL programs, not a private harness:

```sh
BL_NO_LOCK=1 bin/bl test research/rt-selfhost/fusion/pipeline_test.bl
BL_NO_LOCK=1 bin/bl run  research/rt-selfhost/fusion/experiment.bl
BL_NO_LOCK=1 bin/bl run  research/rt-selfhost/invm/experiment.bl
CARGO_TARGET_DIR="$(mktemp -d)" cargo test --offline \
  --manifest-path research/j1_probe/Cargo.toml
```

The guide's own checks read the runnable snippets from the Typst sources:

```sh
BL_NO_LOCK=1 bin/bl test docs/native-regions/examples_test.bl
```

Set `NATIVE_PROBE` to a built `j1_probe` executable from an experiment's work
directory to execute the minimum/count IR recipes as well. The test reports
an explicit skip when that executable is not supplied.

Replay retained evidence without rerunning a workload:

```sh
FUSION_EVIDENCE=research/rt-selfhost/fusion/evidence/summary.edn \
  BL_NO_LOCK=1 bin/bl run research/rt-selfhost/fusion/report.bl
```

== Shipping is a cutover, not a second copy

When a region earns production, it *replaces* a path; it does not sit beside a
hand-tuned copy of itself. One implementation per admitted region. The
fallback is the trusted generic BL path, which already exists and already
works — not a second native variant kept "just in case". The prototype stays
in `research/`; production keeps one dispatcher that chooses BEAM or native
from measured, conversion-inclusive cost and from what the work must protect.

A parallel implementation is the failure mode worth naming: two copies of one
meaning drift, and the copy you did not test is the one that runs under load.

#exercise[
  Extend the recipe once more, to *filter plus count*: count the retained
  bytes instead of folding them. Answer three things before writing code —
  what does empty input return, can the count overflow, and is the result
  order-independent?

  #v(0.4em)
  *Answer.* Fix the initial accumulator to `0` in the count contract.
  Empty then returns `0`, and the result cannot exceed the input length.
  A 1 MiB input therefore fits well inside the accumulator. If an API
  accepts another initial value, empty returns that value and the bound is
  on initial-plus-count instead. State both the identity and the range. The result is order-independent, so a
  permuted input gives the same count. The pinning property is
  `0 ≤ count ≤ len` together with "the count equals the number of bytes whose
  mapped value is below 128", checked against the independent reference. No
  new opcode is needed.

  ```text
  lt  13 11 12
  imm 20 1
  imm 21 0
  sel 22 13 20 21
  add 2  2 22
  ```
]

#block(breakable: false)[
== Testing matrix

Tests turn the contract into explicit cases and complement the type, bounds
and ownership arguments. Check each cell against the *independent* reference
and available closed forms, as well as across compiled paths. For this matrix, the minimum starts from
`4294967295` and the count starts from `0`.

#table(
  columns: (1.1fr, 1.05fr, 1.05fr),
  stroke: 0.4pt + luma(205),
  inset: (x: 0.5em, y: 0.4em),
  align: left,
  table.header([*Input class*], [*filter + min*], [*filter + count*]),
  [empty], [returns the identity], [returns `0`],
  [all rejected], [returns the identity], [returns `0`],
  [the 127/128 boundary],
    [keeps `40 -> 127`, drops `211 -> 128`],
    [counts the kept one],
  [all 256 byte values], [`0` (byte 83 maps to 0)], [`128`],
  [one kept value], [equals it], [`1`],
  [seeded random lengths], [agrees with the reference], [agrees with the reference],
  [maximum admitted size],
    [agrees; boundary cost recorded],
    [agrees; boundary cost recorded],
)
]

Explore `research/rt-selfhost/fusion/RESULTS.md` for the descriptor, both
generated lowerings and the independent oracle; `research/rt-selfhost/invm/RESULTS.md`
for the entry lanes, caps, scheduler stress and reload gates;
`research/j1_probe/PROTOCOL.md` for the wire format and the exact verifier
rules; `priv/lib/native/eligible.bl` for the whole-function verdict.
]

#guide(
  title: "Building and checking",
  subtitle: [One worked extension, its proof obligations, and the measurement
    and shipping rules that keep it honest.],
)[#chapter]
