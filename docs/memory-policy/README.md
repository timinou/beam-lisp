# Memory policy is compiler output

The BEAM gives a program no say over its memory: one generational garbage
collector per process, triggered by heap-allocation instructions the compiler
emits, no regions, no manual free. What a program *can* choose is a small set
of **per-process flags** and **value representations**:

| choice | knob |
|---|---|
| how big a heap starts, when it is too big | `min_heap_size`, `max_heap_size` |
| where a mailbox lives | `message_queue_data` |
| how often to collect old generations | `fullsweep_after` |
| whether to sleep compactly | `hibernate` |
| whether shared read-only data is copied | `persistent_term` |
| what shape a value takes | tuple · map · binary · iolist · NIF resource |

Every knob is a *guess* when a human sets it. Every knob is a **theorem** when
a proof sets it — and beam-lisp already proves the facts each one needs.

Six documents, one per policy. Each is a `.bl.md`: the prose is the design, the
code blocks are the queries and forms the design runs on.

| # | policy | the proof it rests on | engine |
|---|---|---|---|
| 1 | [heap bound as theorem](01-heap-bound-as-theorem.bl.md) | invariant `count(state.xs) ≤ K` | `system.core` + `system.smt/translate-len` |
| 2 | [leak = monotone footprint](02-leak-is-monotone-footprint.bl.md) | a field only ever appends | `system.footprint` + `system.facts` + `system.knowledge` |
| 3 | [refc-binary retention](03-refc-binary-retention.bl.md) | a state field is a sub-binary of a received message | `codebase` + `typed` |
| 4 | [representation by proof](04-representation-by-proof.bl.md) | a shape is fixed · a value is read-only · a string only appends | `system.core/state-shape` + `system.footprint` + `system.gfp` |
| 5 | [proof-directed native offload](05-proof-directed-native-offload.bl.md) | pure ∧ terminating ∧ scalar-sorted ∧ bounded work | `system.footprint` + `termination` + `typed` + `veritas.property` |
| 6 | [atoms never die](06-atoms-never-die.bl.md) | a dynamic atom is reachable from an untrusted entry | `codebase` reachability |

Read them in order of value ÷ cost: **2, 6, 3, 1, 4, 5**. The first three are
lints with zero annotation cost. The last three change what code is emitted.

The through-line: every policy is a **datalog rule** whose body is a proof and
whose head is a process flag or a representation. `codebase` holds the facts,
`system` supplies the proofs, the compiler consumes the conclusions.
