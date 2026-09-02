# The fundamental form under the seven

> `docs/the-maximalist-supervisor.md` laid out seven forms — `server`,
> `supervisor`, `machine`, `bus`, `registry`, `system`, `flow`/`go`. This asks
> the deeper question: are those seven fundamental, or is there ONE thing under
> them? The answer is one thing, and the reason is load-bearing: the guarantees
> are not a property of the `def*` macros. They are a property of the **graph**,
> which every process has whether or not you used a macro to write it.

---

## 1. The claim, and why it is not hand-waving

The seven forms look like seven concepts. They are not. They are seven **named
views of a single underlying object**:

> a process is a **transition relation** — a set of edges
> `(from-state) --[message / guard]--> (to-state)`, plus which states are
> initial and what must stay true across every edge.

That is the whole ontology. `server`, `machine`, `bus`, everything below —
each is that one object with some edges constrained, some fixed, some made
dynamic. The forms are *sugar over a relation*; the relation is the primitive.

**The proof that this is real and not a nice story:** I checked, and
`system/model` extracts the transition graph from a **raw `receive` loop**, not
only from a `def*` form:

```
extract-receive       ← works on a bare (receive …) node
extract-loop-receive  ← works on a bare (loop … (receive …)) node
extract-defn          ← and on a plain multi-clause defn
```

So if you write the most primitive thing the VM offers —

```clojure
(defn account [balance]
  (receive
    [:deposit n from] (do (send from :ok) (account (+ balance n)))
    [:balance from]   (do (send from balance) (account balance))))
```

— `system.model/graph` already sees:

```
states:      {balance}                       ; the loop's carried value
transitions: [:deposit] balance → balance+n
             [:balance] balance → balance
```

No `defserver`. No behaviour module. **The graph was there in the `receive`
loop the whole time.** `defserver` doesn't *create* the graph; it's a nicer way
to write the same edges, and it happens to add an OTP behaviour stamp so `:sys`
recognises it. The guarantee layer reads the graph, so it does not care which
surface you used.

This is the crux: **the seven forms are not seven sources of guarantees. There
is one source — the transition graph — and seven ways to spell it.**

---

## 2. The fundamental form

Call it a **process** in the true sense: a value describing how state evolves
under messages. One shape:

```clojure
(defprocess NAME
  {:state     INITIAL              ; the carried value(s)
   :on        {MESSAGE-PATTERN     ; an edge:
               (fn [state msg] …)  ;   given state + message → next state
               …}
   :invariant (fn [state] …)       ; optional: what must always hold
   :emit      …})                  ; optional: what it sends downstream
```

Every one of the seven is this, specialised:

| form | it is `defprocess` with… |
|---|---|
| **server** | edges that reply to the sender (`call`/`cast` are just "edge that answers" vs "edge that doesn't") |
| **machine** | `:state` restricted to a small enum; edges are the labelled transitions |
| **bus** | one message pattern fanned to N downstream edges; `:emit` carries the events |
| **registry** | `:state` is a map name→pid; edges are put/lookup; lookup is a query over that state |
| **flow / go** | edges gated by *demand* — an edge fires only when downstream asked (the pull rule) |
| **system** | not a process — a **composition** of processes (see §4); the graph is the union |
| **supervisor** | not a process either — a **policy over the failure edges** of its children (see §3) |

Read the table top to bottom and the collapse is visible: five of the seven are
one process-shape with a different constraint on the *same* three fields
(`:state`, `:on`, `:invariant`). The forms are points in the parameter space of
`defprocess`, exactly as `loom`'s `box` makes every layout a point in one box —
the same "one primitive, no ceilings" algebra this codebase already uses for UI,
optics, and relations.

---

## 3. Supervisor is not an eighth thing — it is a fold over failure edges

The one form that resists "it's just a process" is the supervisor, and the
resolution is the sharpest part of the answer.

Every process graph has edges you *wrote* (a message moves state) and one edge
you did **not** write but always exists: the **failure edge** —
`(any-state) --[crash]--> ⊥`. On the BEAM every process can take that edge at
any moment. It is the universal, implicit transition.

A supervisor is precisely: **a policy that adds a return edge from ⊥ back to a
known state.**

```
worker graph:      s0 → s1 → s2
                    \   |   /
                     ↓  ↓  ↓
                      ⊥                 ← the failure edge (implicit, always there)

supervisor adds:   ⊥ --[restart]--> s0  ← the healing edge (the policy)
```

That is the whole of supervision, as graph surgery. The strategy
(`one-for-one` / `one-for-all` / `rest-for-one`) is just *which children's
⊥→s0 edges fire together*. The restart intensity is a *guard on that edge*
(fire at most N times in T, else propagate ⊥ upward). So a supervisor is a
**second-order process**: a process whose state is *the liveness of other
processes* and whose edges are *their failure and healing edges*. It is still
`defprocess` — one level up. There is no eighth primitive; there is the same
primitive applied to the failure edges of the level below.

This is why the tree is "a supervisor is a value you can prove": adding the
healing edge is a graph operation, and `find-lasso` over the resulting graph
answers *"can this thing wedge into an endless restart cycle?"* — a question
about the ⊥→s0 edge, decided by the same engine that decides reachability of any
other edge.

---

## 4. The part that makes it powerful: the WHOLE program is one graph

Here is the point you pushed on, and it is the real prize. The guarantees are
**not** per-form and not per-`def`. `system/step` makes a process's transitions
a **computed relation** (`:~step`), and `:~reachable` is a **fixpoint over
`:~step` on the shipped datom query engine** — the *same* engine that answers
every other datalog query in the language. The docstring is explicit: the
fixpoint engine "cannot tell a computed edge from a stored one."

Sit with that. It means:

- a process's state transitions,
- a supervisor's failure/healing edges,
- a call graph between functions,
- a data dependency in a datom,

are **all edges in one relational space**, queried by **one engine**. The
program — code, processes, supervision, data — is a single graph, and a
guarantee is a query over it. Not a guarantee bolted onto a `defserver`. A
guarantee about *the whole system*, because the whole system is *one readable
relation*.

So the questions stop being per-form and become global:

```clojure
; not "is this server safe?" but "is the bad state reachable ANYWHERE?"
(q '[:find ?s :where [?s :~reachable :bad-state]])

; not "does this machine deadlock?" but "does any process, under any
; supervision policy, have a state with no outgoing edge?"
(q '[:find ?p :where [?p :~state ?s] (not-join [?s] [?s :~step _])])

; "can a crash in THIS worker, under one-for-all, reach a state its
; sibling's invariant forbids?"  — one query across process + supervisor + peer
```

The seven forms gave you seven vocabularies. The **graph** gives you one
question language that spans all of them at once — and that is strictly more
powerful, because the interesting failures are exactly the ones that cross form
boundaries (a supervisor policy that resurrects a worker into a state a sibling
can't tolerate; an emergent livelock spanning three processes). No per-form
checker can see those. A whole-graph query can.

---

## 5. So: fundamental, and therefore powerful

- **The seven are one.** `server`, `machine`, `bus`, `registry`, `flow` are
  `defprocess` with different constraints on `{:state :on :invariant}`.
  `supervisor` and `system` are that same form lifted one order — a fold over
  the failure edges (supervisor) and the union of graphs (system).
- **The one is not a macro.** The transition graph is extracted from raw
  `receive`/`loop`, so the guarantees live under the syntax, at the shape. The
  `def*` forms are ergonomics; the relation is the truth.
- **The one graph is the whole program.** Because `:~step`/`:~reachable` ride
  the same datom fixpoint engine as all other relations, code, processes,
  supervision, and data are *one queryable space*. A guarantee is a query, and
  the most valuable guarantees are the cross-form ones only a whole-graph query
  can express.

The maximalist move, then, is not to ship seven polished `def*` forms. It is to
ship **`defprocess` as the one surface**, let the seven be thin specialisations
of it (the way `core.async` was a thin skin over `flow`), and expose the
**whole-program graph as the query surface** where every guarantee — per
process, per tree, and across the entire system — is one datalog question over
one relation.

That is the simpler, more fundamental, and therefore more powerful
representation: **one form (a process is a transition relation), one space (the
program is one graph), one question language (datalog over `:~step`).** The
seven names remain as convenient dialects; the power is that underneath they
were never seven things at all.

---

## 6. Honesty ledger

> **Superseded, 2026-09-02:** the `defprocess` surface proposed in §2 and §5
> is withdrawn. The reader already makes every `receive` shape a graph
> (`system/model` reads raw loops and `defserver` alike), so a second "spec
> map" dialect adds nothing. The one-primitive *claim* stands; the *syntax*
> is `defserver`'s clause style plus generic verbs. See
> `the-five-bundles.md` §0.

- **Real (verified):** `system.model` extracts graphs from raw
  `receive`/`loop`/`defn` (`extract-receive`, `extract-loop-receive`);
  `:~step`/`:~reachable` run on the shipped `datom.query.fixpoint` engine;
  `system.core` ships `find-lasso`, `simulates?`, `all-senders-guarantee?`,
  `verify-process`. The graph-is-the-source claim is grounded, not asserted.
- **Design (not built):** `defprocess` as a single surface unifying the seven;
  the cross-form global queries in §4 are illustrative of what the one-engine
  design *enables*, not calls that exist verbatim today. Wiring the seven forms
  down to one `defprocess` and exposing the whole-program graph as a stable
  query API is the unbuilt work — but it is refactoring toward a primitive that
  already exists, not inventing a new one.
- **The honest next slice:** define `defprocess`, lower `defserver` to it as the
  first specialisation (proving the skin-over-primitive shape), and expose one
  cross-form reachability query over a two-process + supervisor example — the
  smallest thing that turns "the whole program is one graph" from claim into a
  green query.
