# Refc-binary retention

Binaries larger than 64 bytes do not live on a process heap. They live in a
shared, reference-counted area, and the process heap holds a small handle. A
**sub-binary** — `(subs packet 4 8)`, a pattern match on `<<_:32, rest/binary>>`,
a `binary/part` — is another small handle that points *into the same parent*.

The parent is freed when its last handle dies. So a process that receives a
64 KB packet, keeps 8 bytes of it in its state, and drops the rest keeps all
64 KB alive. Do that a thousand times and the process holds 64 MB it cannot see
in its own heap size, so no heap-based flag notices, and the parent binaries are
freed only when *this* process collects — which, with a small heap of handles,
is almost never.

It is the BEAM's most famous leak. It has a one-word fix: `binary:copy/1`
detaches the 8 bytes into a fresh binary. The problem is knowing where to
write it. beam-lisp can know.

## The facts that exist

`codebase` indexes every function and call site with `:fn/*` and `:call/*`
facts. `typed` tags every position with its type set. `system.facts` projects
clauses. The shape to find is a join across the three:

```
a state field  ←bound from←  a sub-binary op  ←applied to←  a received message
```

## The policy

```clojure
(ns memory.binary
  (:require [codebase] [typed] [system.facts :as facts] [datom]))

;; ops that yield a handle INTO their argument rather than a fresh binary
(def sub-binary-ops #{"subs" "binary/part" "String/slice" "binary-match"})

(def schema
  [{:db/ident :bind/field  :db/valueType :db.type/keyword}   ; state field written
   {:db/ident :bind/from   :db/valueType :db.type/string}    ; op that produced the value
   {:db/ident :bind/source :db/valueType :db.type/keyword}   ; :message | :state | :literal
   {:db/ident :bind/clause :db/valueType :db.type/ref}
   {:db/ident :bind/line   :db/valueType :db.type/long}])

(defn bind-facts
  "For each `(assoc state :f expr)` / `(update state :f …)` in a clause, the
   op at the head of `expr` and where its argument came from — the clause's
   message parameter, the prior state, or a literal."
  [node]
  (for [c (facts/clauses node)
        b (facts/state-binds c)]
    {:bind/field (:field b) :bind/from (:op b)
     :bind/source (:source b) :bind/clause (:db/id c) :bind/line (:line b)}))

(def retained-sub-binary
  '[:find ?proc ?field ?line
    :where [?b :bind/clause ?c] [?c :clause/proc ?proc]
           [?b :bind/field ?field] [?b :bind/from ?op] [?b :bind/line ?line]
           [(contains? memory.binary/sub-binary-ops ?op)]
           [?b :bind/source :message]])
```

The rewrite is a single optics transform on the clause body: wrap the offending
expression in `(binary/copy …)`. beam-lisp's `rewrite` module already applies
path + transform rewrites to source; this is one more rule in it:

```clojure
(rewrite/rule ::detach-sub-binary
  [(assoc ?state ?field (?op ?msg & ?args))]
  {:when (fn [{op :?op}] (contains? sub-binary-ops op))}
  [(assoc ?state ?field (binary/copy (?op ?msg & ?args)))])
```

For a process that holds *many* small sub-binaries and cannot copy each — a
parser that indexes into one large buffer on purpose — the alternative is the
flag: `fullsweep_after 0` makes every collection a full one, so the parents are
released as soon as their last handle dies. The rule emits the flag when the
retained field is a collection of sub-binaries rather than a single one.

## What the author sees

A hover on the `assoc`: *this keeps `packet` (64 KB) alive for 8 bytes;
detached with `binary/copy`*. With the rewrite on, nothing — the copy is
inserted in the emitted code; the source stays as written.

## Speed · quality · provability

**Speed.** One small copy per bind, in exchange for parents freed immediately.
The copy is measured in nanoseconds; the retained parent is measured in
kilobytes per message.

**Quality.** The "memory grows slowly forever" bug that survives every heap
flag, gone at the site that causes it.

**Provability.** Neutral. One precondition on `typed`: it must tell a binary
from a charlist. Today both are `:string`; the tag set gains `:binary`, and
`system.smt/sort-of-tags` maps it to the SMT `String` sort as before — no proof
changes, one tag splits.

## Where it lives

- `codebase` — `:fn/*` and `:call/*` facts, the join substrate.
- `typed` — the `:binary` tag (to add).
- `system.facts/state-binds` (to add) — the projection of state writes.
- `rewrite` — the detach rule.
- `memory.binary` (to build) — the query and the flag decision.
