#import "_preamble.typ": guide, idea, recipe, exercise, decision

#let chapter = [
= 4 · Boundaries and lifetimes

A fast fragment has to cross from the VM into something the VM does not
supervise. This chapter is about that crossing: which doors the BEAM actually
opens, what each one costs when it goes wrong, and the three lifetimes that
must outlive a single call. The short version first: a native bug can crash
the whole VM, and every decision below exists to earn the right to run native
code anyway.

== One supported boundary, three doors

BEAM's own JIT already turns BEAM instructions into machine code, but a BEAM
function has private calling conventions, process registers, GC roots and
safepoints, tracing prologues, reduction accounting and hot-code dispatch. A
compiler's C-ABI function does not have those properties, and pointing the
dispatch table at a raw address is not a supported interface — OTP warns that
it can crash the emulator. There are three supported doors:

#block(breakable: false)[
  #set text(hyphenate: false)
  #set par(justify: false)
  #table(
    columns: (0.75fr, 0.75fr, 0.95fr, 1.05fr),
    stroke: 0.4pt + luma(205),
    inset: (x: 0.55em, y: 0.45em),
    align: left,
    table.header(
      [*Path*], [*Runs in*], [*Isolation*], [*Choose when*],
    ),
    [generated BEAM], [the process], [the process dies alone],
      [effects, generic values, unproven speedups],
    [NIF], [the VM], [a native fault can kill the VM],
      [a small proven kernel that repays entry],
    [port], [a separate OS process], [the worker dies alone],
      [crash containment or independent kill],
  )
]

The choice is a correctness trade, not a speed knob. A NIF removes the port's
isolation; its reason for existing is the entry cost of a small kernel, not a
throughput promise. The measured entry-cost receipts live with the experiment,
in `research/rt-selfhost/invm/RESULTS.md`.

One compiler and one verifier produce the executable module, and the same
artifact is reached both from a resident process and from the in-VM bridge.
What differs is the *entry*: an isolated worker speaks a protocol, while the
bridge borrows a pointer and calls directly. Keeping one compiler behind both
is what stops the two roads from drifting into two languages.

== Three lifetimes

A native call is short. Three things around it live much longer, and confusing
them is the classic bug:

#block(breakable: false)[
```
input binary    ──borrowed for one call──▶   the kernel
compiled code   ──owned by a resource────▶   every call
shared library  ──pinned while handles───▶   the VM's life
```
]

*1. Input data.* Inspection exposes a pointer into a binary's data. That
pointer is transient: it is tied to the call's environment, and the
environment's roots keep the binary alive only for the duration of the call.
Storing such a pointer in a long-lived resource is a use-after-free waiting
to happen.

*2. Executable memory.* The compiled kernel lives in a resource. A call
clones the resource's strong reference before releasing the lock, so closing
the public handle rejects future acquisitions without freeing code underneath
an in-flight call. The code is freed when the last owner goes — at final
destruction, not at handle close. A second close returns false, and forged
handles, closed handles, wrong types and oversized inputs are refused.

*3. The library.* OTP delays unloading a NIF library while resource objects
with destructor callbacks still depend on it. That pins the bridge code. It
does *not* automatically pin separately generated JIT pages, which is why the
ownership of compiled code is a resource obligation rather than a library
one.

#decision(because: [
  the alternative — purging and recreating the host module — left an existing
  resource handle unusable: refused on call and on close, with its code
  reclaimed only once the handle became unreachable and the GC ran.
])[
  Keep the host module *stable* and version the compiled resources. Retain
  old resources while callers or closures still own them, and release
  obsolete cache references separately.
]

This is the difference between *upgrade* and *purge*. OTP resource takeover
during a designed upgrade is not the same operation as deleting and reloading
a module. The prototype does not claim either works as a shortcut; it
demonstrates what it can prove — two kernels with different arithmetic
coexist, and closing the new one leaves the old one returning its own answer.
Because explicitly closing a handle invalidates future uses, cache eviction
and forced invalidation are different policies.

The host module itself is synthesized in the language: `vm.native/declare`
goes through the ordinary ANF/Core backend, so the loader is a program rather
than a special build step.

== The boundary borrows, it does not copy

For an ordinary byte-aligned binary, inspection exposes a pointer into the
existing data — no copy. A view at a nonzero *byte* offset is still that
pointer plus an offset. It is a nonzero *bit* offset that may take a
temporary-copy path during inspection, and "may copy" is not "always free":
the safe reading is that every bitstring layout is not guaranteed to be
zero-copy.

#idea(title: "Validate before you trust")[
  Establish the assumptions used by each unchecked operation: admitted length,
  layout, alignment and numeric domain. Checks can run at the boundary or in
  generated code. A proof may hoist an invariant check out of a loop; it must
  still cover every access.

  Include decoding and normalisation in the work budget. Even a rejected
  bit-misaligned binary can require a temporary copy during inspection. Cheap
  preflight checks and an appropriate scheduling lane belong in the API.
]

== The scheduler does not stop a native function

The ordinary scheduler preempts BEAM processes. A NIF body is machine code on
that scheduler's thread, and OTP cannot preempt it. So the admitted regular
work is bounded on *two* axes, not one, because a byte limit alone does not
bound a kernel with thousands of instructions per byte.

- *Regular entry* runs on the ordinary scheduler. Its work is capped by both
  an input-size limit and a static work limit. The NIF accounts for consumed
  work with `enif_consume_timeslice` before returning to BEAM. This is a hint
  to the scheduler, not an interrupt; the function still returns cooperatively.
- *Dirty CPU entry* moves larger admitted work to a separate bounded CPU
  pool. It protects ordinary scheduler availability; it does not remove
  queuing. Contention raises request latency. For a small computation, the
  dispatch can cost more than the kernel, so choose it for an explicit work
  and responsiveness requirement.

#recipe[
  `enif_consume_timeslice` is a no-op on a dirty scheduler. A bounded normal
  path must restrict the admitted *work*, not only the input size, and the
  hint is not a preemption mechanism — cooperation still comes from keeping
  the work small enough to finish.
]

== Cancellation is cooperative, or it is a port

Killing a process does not interrupt an executing native function. A dirty
caller's DOWN notification can arrive before native work finishes. The
storage and code needed by that call must remain alive until it returns;
process notification and native completion are separate events.

So there are three honest ways to stop native work: bound it in chunks and
check a flag between chunks; make each piece short enough that waiting is
fine; or put it behind a port, where the worker is a separate OS process that
can be killed independently. A port pays for that containment — serialization
and transport at every crossing, and the native work relocated off the BEAM's
reduction accounting. Relocation is not free computation. A port is the right
answer when containment or independent termination matters more than entry
cost.

#exercise[
  You have two kernels. One is verified to fit a small normal-scheduler work
  budget. The other scans up to a megabyte and can take several milliseconds,
  while allocating nothing the BEAM must manage. Which lane does each want, and what is wrong with
  "just kill the process if it runs too long"?

  *Answer.* The small fixed kernel fits the regular lane, admitted under both
  an input bound and a static work bound, with work accounted before the NIF
  returns to BEAM. The larger scan wants the dirty CPU lane because its work
  exceeds that ordinary-scheduler budget. A bounded dirty call may run to
  completion; faster cancellation calls for chunks or cooperative checks.
  "Kill the process" is insufficient because the BEAM caller can die while
  the native call keeps running. Use a cooperative cancellation protocol or
  an independently terminable worker when interruption is part of the API.
]

== Explore the interfaces

The measurements, refusal cases and exact evidence live with the
experiments, not in this guide. `research/rt-selfhost/invm/RESULTS.md`
holds the entry-cost and scheduler results; `research/rt-selfhost/invm/BEAM-ENTRY.md`
states the API and lifetime contract against OTP's
#link("https://www.erlang.org/doc/apps/erts/erl_nif.html")[NIF reference] and
Rustler's
#link("https://docs.rs/rustler/latest/rustler/types/binary/struct.Binary.html")[binary lifetime];
`research/rt-selfhost/fusion/` shows one descriptor lowered twice, with the
port included in the timed path.

]

#guide(
  title: "Boundaries and lifetimes",
  subtitle: [What the BEAM supports, what a native call borrows, and what must outlive it.],
)[#chapter]
