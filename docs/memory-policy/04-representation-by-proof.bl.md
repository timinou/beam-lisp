# Representation by proof

A value has one meaning and many possible shapes in memory. A record with five
fields is a map (`3 + 2·5 = 13` words, hashed lookup) or a tuple (`6` words,
indexed lookup). A shared configuration is copied into every process that reads
it, or it is a `persistent_term` read by pointer. A string built by appending is
flattened on every step, or it is an iolist flattened once at the boundary. A
process waiting for a message that may take an hour holds its full heap, or it
`hibernate`s down to its live data.

Each choice is safe only under a condition. The conditions are theorems
beam-lisp already proves. Owning the lowering (see `docs/core-erlang/`) is what
lets the theorem *choose the shape*.

## Four shapes, four theorems

### Tuple, not map — when the shape is fixed

`system.core/state-shape` reads a server's init and gives the field list with a
sort per field. When every clause preserves that shape — no clause adds or
removes a key, which `verify-process` checks as part of the invariant — the
state is a **fixed record**, and a tuple is strictly smaller and faster.

```clojure
(ns memory.repr
  (:require [system.core :as sys] [system.footprint :as fp] [system.gfp :as gfp]))

(defn fixed-shape?
  "Every clause returns a state with exactly init's keys."
  [node]
  (let [ks (set (keys (sys/state-shape node)))]
    (every? (fn [c] (= ks (sys/clause-result-keys c))) (sys/clauses node))))

;; lowering: field access (:credit state) → (erlang/element 3 state);
;; update (assoc state :credit v) → (erlang/setelement 3 state v).
```

The hazard is reflection: `(map? state)` flips from true to false. The record
abstraction hides it — `BeamLisp.Record` already backs `defrecord` with a
struct and routes `get`/`assoc` through the record protocol — so the tuple form
is invisible through every bl accessor. Interop that pattern-matches on `%{}`
is the one place it shows, and the policy is off for any server whose state
crosses an interop boundary (a `:remote` call with `state` as an argument is a
fact `codebase` already has).

### `persistent_term`, not copies — when a value is read-only forever

Every message send copies its payload; every `ets` read copies. A large value
that every process reads and none writes — a schema, a routing table, a
compiled grammar — is copied thousands of times. `persistent_term:get/1` is a
pointer read: zero copy, outside every process heap, invisible to every
collector.

The condition is stronger than "pure": the value must never be *written after
init*, because a `persistent_term:put` triggers a global collection of every
process that has ever read it. The proof is a **lifetime** proof:

```clojure
(defn write-never-after-init?
  "The var's footprint across the whole program: :W only inside its own
   defining form (init), :R everywhere else. A greatest fixpoint over the
   call graph: no reachable clause carries a :W on this resource."
  [db var]
  (gfp/safe-region db {:resource var :forbidden #{:W :A}} :from :entry-points))
```

`system.gfp/safe-region` is the shipped primitive: the set of states from which
a forbidden mode is unreachable. When the whole program is in it for `var`,
the lowering emits `(persistent_term/get 'var)` at read sites and one
`persistent_term/put` at load.

### Iolist, not string — when a string only appends

A string built as `(str acc piece)` in a loop copies `acc` on every step:
quadratic. An iolist — a nested list of binaries — appends in constant time and
is flattened once, at the `io/write` or `binary/list_to_bin` that consumes it.

The proof is doc 02's footprint read positively: a local whose footprint is
`{s :A}` and whose only consumer is a sink that accepts iolists (every BEAM io
function, `binary/list_to_bin`, a socket send). `typed` tracks the consumer;
the lowering swaps `str` for `list` and inserts the flatten at the sink.

### `hibernate` — when a process is provably idle

A process in `receive` with no timeout, whose next clause cannot fire until an
external message arrives, and whose state is bounded (doc 01), holds a heap it
will not touch for an unknown time. `erlang/hibernate` collects it to its live
data and drops the stack. Waking costs a full heap rebuild — so the condition
is *liveness*: the process is not on a hot path.

```clojure
(defn idle-shape?
  "AF over the phase graph (system.gfp/af): from this phase, every path reaches
   a `receive` with no `after` before any send or spawn."
  [node phase]
  (gfp/af (sys/phase-graph node) phase :until :blocking-receive))
```

The lowering appends `(erlang/hibernate …)` as the tail of clauses that enter
an idle phase, and only for servers whose measured or declared message rate is
low (`^{:rate :low}` — the one annotation in this document, because rate is not
a property of the code).

## What the author sees

Nothing in the source. Hover shows the shape: *state lowered to tuple (6 words,
was 13)*; *`schema` read via persistent_term*; *`out` built as iolist*. Each is
reversible with `^{:repr :map}` and friends when interop needs the plain shape.

## Speed · quality · provability

**Speed.** Solid and local: halved state size and O(1) field access for
records; zero-copy reads for shared config; linear instead of quadratic string
building; idle processes at their minimum footprint. This is where a Core
Erlang backend pays — every one of these is a one-line choice in the lowering
once the proof exists, and none is expressible from outside the compiler.

**Quality.** Good where the abstraction holds; a hazard where it does not. The
tuple lowering is the risky one — reflection and interop see the shape — and
the policy is gated on both `codebase` facts. `persistent_term` misuse is a
node-wide pause, so its gate is a whole-program greatest fixpoint, not a local
check.

**Provability.** Improves. A fixed shape gives `system.smt` a datatype where it
had a map it could not translate, so invariants over record fields that were
`:untranslatable` become provable. A `persistent_term` value has a proven
footprint of `{var :R}` everywhere, which simplifies every caller's frame
rule. Nothing gets harder to prove; several things become possible.

## Where it lives

- `system.core/state-shape`, `verify-process` — the shape and its preservation.
- `system.footprint` — `:R`/`:A`/`:W` per resource.
- `system.gfp/safe-region`, `af` — the whole-program and liveness fixpoints.
- `BeamLisp.Record` — the accessor abstraction that hides the tuple.
- `memory.repr` (to build) — the four decisions.
- `self.cerl` (see `docs/core-erlang/`) — the lowering that consumes them.
