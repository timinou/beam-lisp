#import "_preamble.typ": guide, idea, decision, contrast, term, recipe, exercise

#let chapter = [
= 2 · From source to region

Ordinary BL source becomes a machine region in five moves: resolve,
analyze, recognize, admit, lower. Each move answers one question, and
the questions stay separate on purpose — a program can be perfectly well
resolved and still be refused, and a refused program is still good BL.

== Resolved source

The compiler resolves every symbol to a binding, expands every macro, and
emits #term[ANF]: administrative normal form, the backend-neutral IR in
`priv/boot/anf.bl`. In ANF each intermediate value is bound once,
argument evaluation order is fixed, and every call names what it calls:

- `:remote {:mod :erlang :fun :+ :args …}` — a known host call.
- `:arith {:fun :add …}` — a numeric operation, kept as arithmetic
  rather than an integer-or-float choice made too early.
- `:apply {:fn … :args …}` — a call through a function *value*.

Each node also carries an `:ann` map with its source position, the types
known at that point, and the effects the footprint analysis found. ANF
is the right starting point because every later question — is this pure?
is the callee known? what order do these run? — is answered by looking
at the tree, never by running it. `priv/boot/lower.bl` turns the same IR
into Core Erlang and then a BEAM module.

#idea(title: "Pure, total, known, bounded")[
  Four words decide almost every region question.
  #term[Pure] — touches no world: no I/O, no sends, no shared mutation.
  #term[Total] — returns a value for every admitted input; it cannot
  raise or run forever.
  #term[Known] — every callee is resolved, never an unknown function
  value.
  #term[Bounded] — the work is a function of the input size, with a
  stated ceiling.
]

== A region is a sub-expression with a description

A region is not a new syntax. It is an ordinary sub-expression, described
as data: which operations, over what sort and layout, with which
effects, which numeric rules, which bounds, and in which order.

The repository does not ship a general region language yet. The shape
below is a sketch — illustrative, not an interface you can call today:

```clojure
; SCHEMATIC — an illustrative region description
{:input  {:sort :bytes :layout :packed
          :max-byte-count 1048576}
 :ops    [{:op :byte-affine :scale 3 :offset 7 :modulus 256}
          {:op :keep-less :bound 128}]
 :reduce {:op :sum-u64-wrap :modulus 18446744073709551615}
 :effects #{}
 :total  true
 :order  :input-order}
```

Read it as a sentence: *fold a packed byte input, in input order, by
scaling, keeping small values, and summing with explicit 64-bit wrap; no
effects; total.* Everything a planner needs is in one value, and nothing
in it names a backend.

== Recognition, not general fusion

Turning source into a region means matching a small, named family of
shapes — the pure map, the filter, the fold, the counted loop — against
the resolved tree and the effect summaries. It is pattern recognition
over analyses that already exist, not a theorem about arbitrary BL.

The repository holds two honest, partial endpoints:

- `research/rt-selfhost/fusion/pipeline.bl` carries one `descriptor` and
  an `admit!` that accepts exactly that fragment and refuses every
  departure, naming it. Both generators call `admit!` first, so a
  descriptor that is not the proven fragment can never be half-lowered.
- `priv/lib/native/eligible.bl` answers a related question for whole
  functions — empty footprint, termination, and NIF-safe return sorts —
  and returns a reason on refusal. Add input, memory and work-bound facts
  before using such a verdict for scheduler-sensitive native execution.

Neither is a general pass. They are two ends of one direction, and the
distance between them is the work.

#recipe[
  To widen the recognized family, one shape at a time:
  1. resolve and analyze the source, so callees and effects are facts;
  2. write the shape down as a description — operations, sorts, layout,
     order, bounds, numeric rules;
  3. state every boundary it assumes, and refuse anything outside them;
  4. admit the exact fragment, naming each departure on refusal;
  5. generate both lowerings from the admitted description;
  6. check generated BEAM against the generic path on random inputs,
     including the edges of the admitted domain.
]

== One verdict, two capabilities

Two questions look alike and must stay apart.

#contrast[Admission][
  Does the *meaning* permit a machine region? Purity, totality, known
  callees, an explicit numeric rule, preserved order. A verdict here is
  about the program, not the hardware.
][Capability][
  Which *host* can run it, and how much work may it do? Sorts, buffer
  ceilings, worker availability, scheduler choice. A verdict here is
  about this machine on this day.
]

Admission returns a verdict with reasons and admits a region as a whole.
For a transparent optimiser, the dispatcher should route an optimisation
refusal to the generic path. An explicit native-entry API can instead raise:
`fusion.pipeline/admit!` does this with its list of departures. These are
different API contracts. Consult backend capability separately so a valid
region can still run as BEAM when a native worker is unavailable.

#decision(because: [mixing the two lets a busy machine look like an
  invalid program, and lets a clever backend quietly change meaning.])[
  Language meaning has one authority; execution has many hosts.
]

== The six boundaries

#idea(title: "What a region may and may not assume")[
  1. *Immutable input.* The region reads its input and never writes it.
  2. *Captures are fixed.* A closed-over value is constant for the
     region's life, or passed as a parameter. A mutable captured cell is
     hidden state.
  3. *Known callees.* A `:remote` or `:arith` node names its callee; an
     `:apply` of an unknown function value cannot enter a region.
  4. *No effects.* No sends, no I/O, no shared mutation. Effects have an
     order, and a region may not reorder them.
  5. *Totality or declared exceptions.* Code that runs speculatively
     must be total, not merely pure.
  6. *Order preserved.* `if`, `and`, `or` and `case` skip work. A region
     must not evaluate what the original would have skipped.
]

== Worked refusal: pure but may throw

Take a scale step that is pure but can fail:

```clojure
; pure, but not total: raises when b is 3
(defn scale [b] (erlang/div 100 (- b 3)))
```

Now guard the call so the exceptional input is skipped:

```clojure
(defn guarded-scale [b]
  (if (= b 3) 0 (scale b)))
```

A lowerer might try a conditional-select instruction to avoid a branch.
A select still costs work, and its operand values must already exist:

```text
# Schematic data flow, not the textual native-IR syntax.
scaled = scale(b)
result = select(b != 3, scaled, 0)
```

The select chooses between already-computed operands. Hoisting `scale`
out of its guard therefore evaluates it for `b = 3`, where the original
returns zero without calling it. The new exception changes the program's
meaning. The same issue appears when fusing filter-then-map.

This is the trap: *purity is not enough*. Purity says the function
touches no world. It says nothing about whether the function returns.
Aggressive evaluation needs #term[totality]. A branchless form requires
totality, and requires it for every arm that can run, not only for the
one the original would have chosen.

Two honest fixes:

1. Preserve real control flow: evaluate the predicate first and call
   `scale` only in the chosen branch, just as the source does.
2. Admit a speculative fast path only on a domain where `scale` is
   total, such as bytes greater than 3. Outside that domain, retain the
   original guarded program rather than rejecting a valid source input.

#decision(because: [a branchless form is meaning-preserving only when
  every arm it evaluates is total over the admitted domain.])[
  Speculative execution is admitted only when every expression it
  evaluates is total.
]

== Exact arithmetic does not silently wrap

BL's integer addition is exact and unbounded. A wrapping 64-bit add has
a different contract. Two useful ways to connect them are an explicit
wrapping operation and a proof that overflow cannot occur.

*Explicit wrap.* The region states it, and the generated code masks:

```clojure
{:reduce {:op :sum-u64-wrap :modulus 18446744073709551615}}
```

The generated BEAM then performs `band` with that modulus, and the
native lowering emits the same fixed-width operation. The wrap is part
of the program, visible in one place.

*Proven range.* Start from zero, admit at most 2^20 bytes, and keep only
non-negative values below 128. Then the sum is below 2^27, far inside
64 bits. Machine
`+` is exact on that domain, so no mask is needed and none is emitted.

When neither holds, retain an exact-capable path. Another design is checked
arithmetic with a specified overflow fallback; that fallback must preserve
state and effect order. Silent wrapping is a different program.

== One region, both lowerings, an explicit fallback policy

Once a region is admitted, the same description feeds both lowerings. The
BEAM lowering goes through `anf` and `lower.bl` to Core Erlang and a BEAM
module; the native lowering produces the machine IR the Cranelift
compiler accepts. Because both call the same admission, they cannot
disagree about what was admitted.

The generic runtime pipeline supplies the reference meaning. A compiler
dispatcher can also use it as a fallback when proofs, input guards or backend
capacity do not support an optimisation. Preserve the generic path's values,
exceptions and effect order. The explicit prototype entry points raise on
refusal; converting admission into transparent routing is a design recipe.

== What invalidates what

A compiled artifact is valid only for the meaning and the machinery that
produced it. A design that caches such artifacts therefore keys each one
by the region description's hash, a semantic and representation version,
the compiler and backend versions, and the CPU features used. Edit a
referenced pure function and the regions that read it — and only those —
become stale. That is dependency tracking, not a rebuild of the world.

Old compiled code is not thrown away while a caller still owns it; the
last owner releases it. The lifetimes behind that sentence — resources,
references, and when memory is really freed — are the subject of
Chapter 4.

#exercise[
  A region claims `:effects #{}` and `:total true`, and its body calls
  `erlang/map_get` on a map the caller passed in. Is it total? Is it
  pure? What must the region description add to be honest?

  #v(0.4em)
  *Guidance.* `map_get` is pure — it reads and touches nothing — but it
  is not total: it raises when the key is absent. To be honest the
  region must either restrict its domain to a map known to contain the
  key, or declare the exception and the order in which it may occur. And
  the caller's map is an input, so it must stay immutable for the
  region's life; a later mutation by the caller would make replay
  disagree with the original run.
]

Receipts for the prototype described here live in
`research/rt-selfhost/fusion/RESULTS.md` and
`research/rt-selfhost/invm/RESULTS.md`.
]

#guide(
  title: "From source to region",
  subtitle: [How an ordinary BL expression becomes a small, admitted,
    doubly lowered thing — and when it is refused.],
)[#chapter]
