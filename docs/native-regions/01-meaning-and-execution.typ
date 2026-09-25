#import "_preamble.typ": guide, idea, decision, contrast, term, exercise

#let chapter = [
= 1 · Where the work goes

A computation has a *meaning*. A machine has *representations*. Between
them sits a decision: where to carry the meaning out, and what shape it
wears while it is there. Keeping those three apart is the whole game.
This chapter builds the vocabulary, follows one small BL pipeline from
meaning to machine, and shows why the choice of machine changes cost
without changing meaning.

#idea(title: "The words this guide uses")[
  - A #term[value] is what a program means: the number 200, a byte, a
    sequence of bytes.
  - A #term[representation] is how a machine stores that value — a BEAM
    term on the heap, a packed binary, a machine integer in a register.
  - #term[Semantics] is the contract a value keeps wherever it lives:
    what `+` means, when an exception is raised, what order effects run.
  - An #term[execution plan] binds a meaning to a machine: BEAM,
    compiled machine code, or a process somewhere else.
  - A #term[region] is a piece of a program with one meaning, small
    enough to describe completely.
]

== Meaning and representation are different things

The byte 200 means the same thing in every path in this guide. As a BEAM
term it fits in a tagged immediate integer word. As a packed binary it is
one octet at a known offset. As machine data it is a 64-bit integer in a
register. None of these is more *correct*; they differ in what they make
cheap.

A representation changes which operations are cheap. Reading a packed
byte costs an offset and a load. Turning the whole binary into a list
costs one cons cell per byte; the small integer occupies its head slot —
a conversion that a
loop over the packed bytes never pays. `binary/bin_to_list/1` is exactly
that conversion, and it is a choice, not a law.

== Semantics is the part that must survive the move

Moving meaning across representations is safe only while the contract
survives. BL's integer addition is exact and unbounded. A wrapping
64-bit add computes modulo 2^64. They agree within the chosen range and
can disagree outside it; floating-point addition has a separate contract. An
execution plan must expose a wrapped result only when that is the program's
contract. Exact addition needs a range proof or checks that preserve an exact
fallback. Chapter 2 develops these choices; the principle belongs here:
a representation never gets to change what the program means.

#decision(because: [a wrap that appears because of a layout choice is a
  silent change of meaning, and silent changes of meaning are the
  expensive kind of bug.])[
  Every move between representations either preserves semantics exactly
  or is refused.
]

== A walk through an ordinary pipeline

Here is a plain BL pipeline over one binary: scale each byte, keep the
small ones, sum the survivors. It is written the way a user would write
it, using the runtime's transducers. The input contract here is a byte
binary and an initial integer in the u64 range.

```clojure
(def MASK64 18446744073709551615)

(defn map-filter-sum [bin init]
  (let [bytes  (binary/bin_to_list bin)
        mapper (fn [b] (erlang/rem (erlang/+ (* 3 b) 7) 256))
        keep?  (fn [y] (erlang/< y 128))
        step   (fn ([acc] acc)
                   ([acc y] (erlang/band (+ acc y) MASK64)))
        xf1    (BeamLisp.Ns.Rt/map_xform mapper)
        xf2    (BeamLisp.Ns.Rt/filter_xform keep?)
        rf     (BeamLisp.Ns.Rt/invoke xf1
                 (list (BeamLisp.Ns.Rt/invoke xf2 (list step))))]
    (BeamLisp.Ns.Rt/invoke rf
      (list (BeamLisp.Ns.Rt/reduce rf init bytes)))))
```

Count what the machine does. `bin_to_list` allocates an input cons spine.
The transducers already avoid intermediate output collections: they compose
reducing functions. What remains is per-element callback and invocation
machinery, including temporary argument lists. The step has a one-argument
completion arity as well as its two-argument accumulation arity.

Fusion can preserve this good collection behaviour while going further:
read the packed input directly and put the known operations inside one loop.

== Why fusion removes allocation and dispatch

The same meaning can be carried by one loop over the packed bytes:

```clojure
; A runnable BL reference for the generated loop's shape.
(defn fused-reference [bin init]
  (let [n (erlang/byte_size bin)]
    (loop [i 0 acc init]
      (if (erlang/< i n)
        (let [b   (binary/at bin i)
              y   (erlang/rem (+ (* 3 b) 7) 256)
              sum (erlang/band (+ acc y) MASK64)]
          (recur (erlang/+ i 1)
                 (if (erlang/< y 128) sum acc)))
        acc))))
```

#contrast[Composed transducers][
  No intermediate output collections, but this byte adapter builds an
  input list and each stage invokes a reducing function. Callback cost
  grows with both the number of stages and the number of bytes.
][One fused loop][
  One pass over packed bytes, one accumulator, and known operations
  directly in the loop. BEAM uses its term operations; a native lowering
  can keep the admitted numbers in machine registers.
]

Fusion is not a trick about the `+`. It removes the *shape* the pipeline
did not need: the intermediate collections and the per-element dispatch.
That is why it matters even when every arithmetic operation is
identical.

== Two machines that both run native code

There are two very different things called "native" here.

*Generated BEAM* is a module compiled to BEAM instructions. The BEAM is
a register virtual machine, and OTP's just-in-time compiler turns those
instructions into machine code. This code is already native, but it
keeps BEAM's calling conventions, heap, garbage collector, reduction
accounting and preemption. A fast BEAM loop is still moving BEAM terms.

*Cranelift code* is a C-ABI leaf function: pointer, length, integer in,
integer out. It has none of BEAM's conventions, which is both the point
and the danger. It is not a drop-in replacement for a BEAM function
body; the VM's own rules — stack maps, GC roots, tracing, hot-code
dispatch — are private. The supported ways to reach such a function are
a NIF or a port.

#decision(because: [one meaning, one compiler, many hosts. A second
  native compiler is a second truth about arithmetic.])[
  One region description feeds one native compiler; BEAM and Cranelift
  are two lowerings of it.
]

== Four ways to reach a machine

The same admitted region can be executed through four entries. They
differ in what they cost and in what they protect against:

#table(
  columns: (auto, 1fr, 1fr, 1fr),
  inset: 4pt,
  [*entry*], [*boundary*], [*isolation*], [*preemption*],
  [BEAM], [none], [VM-safe], [preemptible],
  [regular NIF], [in-VM call],
  [none: a fault crashes the VM], [none],
  [dirty NIF], [in-VM, separate pool],
  [none: a fault crashes the VM], [none],
  [port], [OS process, serialized],
  [separate process], [independently killable],
)

Three facts complete the picture.

- The in-VM paths are bounded. The prototype admits at most 4096 bytes
  and a bounded number of body operations on the regular path, and up
  to 1 MiB on the dirty path. A byte cap alone is not enough: a tiny
  kernel with thousands of instructions per byte is not small work.
- `enif_consume_timeslice` *accounts* for time; it does not interrupt
  the function. Preemption is not available for a running native call.
- Killing a process does not cancel native code it is waiting on. The
  kill is delivered; the computation finishes; the memory is freed when
  the last owner releases it. A hard stop needs a separate, killable
  process — a port.

A regular NIF borrows an ordinary byte-aligned binary. A bit-misaligned
view may take a temporary copy during inspection. That difference is a
property of the data, not of the program.

== One authority, not a classifier call per element

Hearing "one semantic authority", it is easy to picture a runtime
service consulted for every byte: ask whether this add is allowed, do
it, ask again. That design would be slower than the generic path, and it
is not this one.

The authority is a *description* — one value stating what the region
means. It is read once, before execution, at admission. Analysis happens
ahead of time; the loop that runs carries no tags, no checks and no
dispatch. Deciding once is what makes the fused loop cheap. Asking per
element is what would make it slower than the code it replaced.

#exercise[
  In the pipeline above, name three representations that differ between
  the transducer path and the fused path. For each, say whether the
  program's meaning changed.

  #v(0.4em)
  *Guidance.* The input cons spine versus the packed binary; temporary
  invocation arguments versus direct arithmetic; the per-element
  closure calls versus one loop. None changes the meaning: same values
  in, same value out. The one place meaning could change is the
  arithmetic — and it does not, because the wrap is written explicitly
  as `band … MASK64` in both. If the fused path had used machine `+`
  with no mask and no range proof, that would be a meaning change, and
  it would be a refusal, not an optimization.
]

Measured comparisons for this exact pipeline live in
`research/rt-selfhost/fusion/RESULTS.md`. This chapter keeps no table of
times: a threshold measured on one host is a fact about that host, not
a law about the language.
]

#guide(
  title: "Where the work goes",
  subtitle: [One meaning, several machines — values, representations,
    and the plan that connects them.],
)[#chapter]
