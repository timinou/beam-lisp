# Guarantees compose

Each check a process passes — its dispatch is total, its guard preconditions
hold, its invariant is preserved — answers a question *about that one process*.
The questions that matter across a running system are between processes:

- which message a client sends lands on a guarded handler it must satisfy?
- which message is dropped because the receiver has no clause for it?
- which send could break the *receiver's* invariant?

No single-process check can answer these, because each involves *two* processes'
guarantees at once. The way to ask them is to put every guarantee into one place.

## One relation, many projectors

Every guarantee is already data — a dispatch table, a set of guards, an
invariant, a call graph. Projected into a single datom store under one schema,
they stop being separate function results and become **relations that join**. A
cross-cutting question is then a datalog query, not a new checker.

```
:process/name  :process/invariant          ; the guarantee a receiver relies on
:clause/proc   :clause/label  :clause/guard ; its dispatch and preconditions
:phase/from    :phase/to                    ; its protocol graph
:send/from     :send/to       :send/label   ; the wiring between processes
```

## The cross-cutting questions are joins

```clojure
;; a send that hits a guarded handler — the sender must establish the guard
[:find ?from ?label ?guard
 :where [?s :send/to ?to] [?s :send/label ?label] [?s :send/from ?from]
        [?c :clause/proc ?to] [?c :clause/label ?label]
        [?c :clause/guarded true] [?c :clause/guard ?guard]]
```

Add the receiver's invariant to the same join and the query becomes *which send
could break a downstream guarantee* — the site where a missing precondition on
one process violates another's invariant:

```clojure
[:find ?from ?label ?guard ?inv
 :where … [?c :clause/guard ?guard]
          [?p :process/name ?to] [?p :process/invariant ?inv]]
```

A message a receiver never handles is the same shape with a negation — the
anti-join that finds a dropped send:

```clojure
[:find ?from ?label
 :where [?s :send/to ?to] [?s :send/label ?label] [?s :send/from ?from]
        [:not-join [?to ?label]
          [?c :clause/proc ?to] [?c :clause/label ?label]]]
```

## Why this is the shape

A guarantee that lives inside a function answers only what that function was
written to ask. A guarantee that is a relation answers every question that joins
with it — including the ones nobody has written yet. Each capability projected
composes with all the others: the value is not additive but multiplicative, for
the cost of the projection alone, because the data was already there.

## Where it lives

- `system.knowledge/knowledge` — build the store from process nodes + the sends
  between them.
- `system.knowledge` projectors — `project-process`, `project-clauses`,
  `project-sends`, each turning a shipped capability into facts.
- the queries — `guarded-sends`, `unhandled-sends`, `invariant-bearing-guarded-sends`
  — joins across the projected relations, dependency-injected over datom.
