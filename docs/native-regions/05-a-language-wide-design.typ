#import "_preamble.typ": guide, idea, decision, term, recipe, exercise

#let chapter = [
= 5 · A language-wide design

A byte loop gives a small example of a general method: describe a computation,
then choose an execution plan that preserves its observations. The simplest
native leaf regions are *pure*, *total*, *known* and *bounded*, with explicit
representations and numeric rules. Effectful functions can still contain such
regions; the surrounding control and effects remain on BEAM.

A richer region can carry an explicit error or effect protocol, but each
extension adds obligations. Start with a small contract you can check rather
than treating every native-backed operation as the same optimisation.

This chapter is a coverage map. For each family of BL constructs it asks the
two questions that decide an execution plan — does the *meaning* admit a
bounded pure region, and which *host* can run it — then names the artifact
that records the answer and the keys that invalidate it.

#idea(title: "One language, several plans")[
  BL keeps one meaning and many execution plans. #term[Native] is never a
  property of the language; it is a property of a small, proven island
  inside it. The map below separates executable examples from extension recipes.
]

== The coverage map

#table(
  columns: (1.05fr, 1.35fr, 1.1fr),
  stroke: 0.4pt + luma(205),
  inset: (x: 0.5em, y: 0.4em),
  align: left,
  table.header([*Family*], [*What a region needs*], [*Execution direction*]),
  [pure scalar and branch loops],
    [known callees; an explicit numeric rule; a work bound],
    [proven for the admitted byte fragment],
  [immutable closures, partial application],
    [every capture fixed or passed as a parameter],
    [design recipe],
  [pattern matching, records, ADTs],
    [a total match over NIF-safe sorts],
    [mostly stays BEAM],
  [map, filter, reduce, lazy],
    [bounded eager folds; no escaping lazy output],
    [fused recipe; lazy stays BEAM],
  [membership, sorting, hashing],
    [one equality, hash, order and key codec],
    [design recipe: prove the laws, then specialise homogeneous keys],
  [strings, parsers, codecs],
    [byte loops are the proven shape],
    [byte loops proven; streaming parsers stay BEAM],
  [queries and rules],
    [one region IR reused by every engine path],
    [shared-IR recipe; not columnar today],
  [compiler and reader],
    [regions are data the compiler already builds],
    [BL compiles BL; lowering in BL demonstrated],
  [actors, mailboxes, refs, IO, exceptions],
    [effects, preemption, isolation],
    [stay BEAM; local pure islands only],
)

Read the top and bottom rows as deliberate. The top is where the obligations
already hold. The bottom is where the VM's own semantics live: a process
mailbox, a reference cell, an IO write, a raised exception. A leaf region may
*call* a pure function that an actor also calls; the region IR used here has
no mailbox or send operation. Explicit effectful NIF libraries have their own
contracts and are a separate question from pure-region fusion. Machine-code
bodies require cooperative yielding or cancellation, and an in-VM native
fault can take down the VM. Choose BEAM for runtime-managed control and a
port where independent termination or crash containment is required. Keeping the bottom on the BEAM is what
lets the top be fast.

== A region artifact: identity, layout, semantics, compiler

A region is *described*, then lowered. The description is the artifact, and
the shipped prototype admits exactly one:

```clojure
{:pipeline :krt/fused-byte-fold
 :version 1
 :input  {:kind :bytes :max-bytes 1048576}
 :map    {:op :byte-affine :scale 3 :offset 7 :modulus 256}
 :filter {:op :signed-lt :bound 128}
 :reduce {:op :sum-u64-wrap :modulus 18446744073709551615}
 :init   {:kind :u64}
 :emit   {:module :Elixir.Krt.FusedPipeline :function :run :arity 2}
 :native {:kernel-name "fused" :n-params 3
          :ptr-var 0 :len-var 1 :acc-var 2 :counter-var 3
          :counter-init 0 :step 1}}
```

Four things the artifact states, and they must not be confused:

- *Identity.* The whole value is the identity. `fusion.pipeline/admit!` accepts
  it by exact equality and names every departure — a changed constant, a
  missing key, or an unknown key. A gate that silently tolerates an extra knob
  is a gate whose meaning depends on who reads it.
- *Layout.* `:input` fixes the sort and the ceiling; `:native` fixes the
  parameter roles: pointer, length, accumulator, counter. Packed bytes are
  read-only, and the loop never writes its input.
- *Semantics.* The map, filter and reduce contract, including the numeric
  rule: `mod 256` per byte, and an accumulator that wraps `mod 2^64` because
  the program says so.
- *Compiler.* The `:emit` and `:native` sections are two lowerings of one
  value. The BEAM lowering goes through the compiler's `anf` and `lower`
  passes; the native lowering emits the text IR that the one shared compiler
  in `research/j1_probe/src/kernel.rs` parses and lowers. One generator, one
  verifier, no second arithmetic.

CPU keys sit apart from identity: which entry runs the region, and how much
work each admits. The regular entry bounds input size *and* straight-line
work, because a byte cap alone does not bound a kernel with thousands of
instructions per byte; the dirty entry admits larger batches. Those keys
describe the host, not the meaning, and they can change without changing the
artifact.

== Invalidation: fixed captures, not a rebuild of the world

A compiled artifact is valid only for the meaning and machinery that produced
it. Key each one by the region description's hash, a semantic and
representation version, compiler/backend versions, target architecture and
ABI, and CPU features used. Layout facts include word width and byte order. Edit a referenced pure function and the regions that read it —
and only those — become stale.

Two hidden inputs break a region even when the source looks closed:

- A #term[dynamic variable] can change while a loop runs. If the source reads
  it on every iteration, reading it once would change the contract. Pass a
  fixed value only when the program defines a snapshot or analysis proves the
  value stable for the region; otherwise preserve the generic reads.
- A #term[captured closure] carries an environment. An immutable capture can
  become a parameter or a specialised constant. Capturing a reference cell
  fixes the cell's identity, not its contents. A snapshot is an optimisation
  only when the source semantics permit it.

#decision(because: [
  a compiled region and its host have different lifetimes. Handle compatibility
  follows the native resource type's upgrade protocol; purge/recreate need
  not preserve it. A new region resource can coexist with an old resource
  behind the same host ABI, keeping each caller's code version explicit.
])[
  Keep the host module stable and version the compiled resources. An edit
  produces a new version; it does not purge the host.
]

The same rule governs code lifetime: retain an old resource while any caller
or closure still owns it, and release obsolete cache references separately.
Explicitly closing a handle invalidates future uses, so cache eviction and
forced invalidation are different policies — not one "clear everything" path.

Generated BEAM needs the same care. Local recursion or versioned module
identity can keep a fold on one code version; mutable external dispatch can
otherwise switch its implementation between iterations. Code identity belongs
in the execution contract for both backends.

== The cost model includes the boundary

A native call's cost is the whole crossing: validation, encoding the
arguments, transfer, native execution, the reply, and decoding. The kernel
alone is not the number a user feels, and the difference is large enough that
quoting the kernel would hide much of the call.

Two consequences follow.

- *Batching amortizes the boundary.* One bounded batch shares the entry
  cost across many elements. Ports, regular NIFs and dirty NIFs have
  different costs, so each has its own crossover. Measure the full call
  against generated BEAM; input size alone does not choose the winner.
- *Queue pressure is real.* The dirty pool is finite. Contention raises
  request latency while the ordinary scheduler keeps beating, and moving a
  small kernel there buys dispatch cost and nothing else.

The measured crossover sat between a few hundred bytes and a kilobyte on one
host, in one run — a fact about that host and that run. A dispatch floor is
the *next* experiment, not a language constant. The honest rule is to choose
the lane from a measured, conversion-inclusive cost and from what the work
must protect.

== What this chapter does not claim

- No generic fusion of arbitrary user functions. The gate admits an exact
  fragment and refuses every departure by name.
- No automatic backend selection yet. A dispatcher that picks BEAM or native
  from measured cost is the next step, not a shipped feature.
- No typed packed views. A view interface is a design recipe; the shipped
  fragment reads bytes at an index.
- No claim that Datalog is columnar. Aggregates fold over the result set
  today. The `datom.vector` `DVec` is a *different* native fragment — float
  math over packed `f32` — while the shared fragment compiler is
  integer-and-byte only.
- No universal threshold, and no promise that a fast path is a correct one.

== Where the compiler helps

BL already compiles BL. The compiler and the reader are BL programs, and a
region description is data those programs can build, inspect and hash. The
lowering spike took the compiler's *own quoted output* down to native IR in
BL at REPL pace, and checked the result against independent references —
evidence that the lowering itself can be owned by the language rather than
bolted on beside it.

Two ends of one direction are already here. `priv/lib/native/eligible.bl`
computes a whole-function verdict for empty footprint, termination and
NIF-safe return sorts. Input, memory and work bounds are additional facts
that a general region gate must establish.
`fusion.pipeline/admit!` admits one exact fragment and refuses everything
else. The work between them is done one named shape at a time.

#recipe[
  To carry a family onto the map:
  1. state the meaning — pure, total, known, bounded — and the numeric rule;
  2. describe the region as data: sorts, layout, order, bounds, captures;
  3. let one generator lower it through the existing backend;
  4. check both lowerings against an independent reference, edges included;
  5. key the artifact for invalidation, and keep the host stable;
  6. route by measured, conversion-inclusive cost — BEAM when unsure.
]

#exercise[
  Take a pure function you wrote and write its region description: input sort
  and layout, operations, the numeric rule, the evaluation order, and the
  bounds. Then name one obligation it fails.

  #v(0.4em)
  *Guidance.* Most first attempts fail *totality* or *known callees*: a
  `map_get` that raises, an `apply` of a function value, a division whose zero
  case was never decided, or a capture anything can mutate. The repair is to
  restrict the domain and refuse the rest, replace the unknown callee with a
  resolved one, or declare the exception explicitly. A refusal is a routing
  decision, not a bug in your program.
]

Receipts: `research/rt-selfhost/fusion/RESULTS.md` for one descriptor lowered
twice with conversion-inclusive timings; `research/rt-selfhost/invm/RESULTS.md`
for the entry lanes, caps and lifecycle; `research/lowerers_spike/` for
lowering the compiler's own output; `priv/lib/native/eligible.bl` and
`research/rt-selfhost/NATIVE-PLAN.md` for the two ends of the direction.
]

#guide(
  title: "A language-wide design",
  subtitle: [How far one proven loop reaches — one language, many execution
    plans, and an honest map of what is proven today.],
)[#chapter]
