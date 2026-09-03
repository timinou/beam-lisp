# A leak is a monotone footprint

The two ways a BEAM process leaks memory are both *shapes*, not accidents:

1. **A state field that only ever grows.** Some clause appends to it; no clause
   ever shrinks it. The process is a log that nobody rotates.
2. **A mailbox that only ever fills.** Some process sends a message; the
   receiver has no clause for it. The message sits in the queue forever — and
   every `receive` that *does* match scans past it first, so the leak is also a
   slowdown.

Both are visible before the program runs, because both are facts about
clauses, and beam-lisp already projects clauses into a database.

## The facts that exist

`system.footprint` gives every expression a footprint: a map from resource to
mode, where the modes are

```
:R read   :A append (monotone)   :W write   :S send   :K receive   :X spawn
```

`system.facts/clause-facts` projects a process's clauses into datom —
`:clause/label`, `:clause/guard`, `:clause/order`. `system.knowledge` adds the
wiring between processes: `:send/from`, `:send/to`, `:send/label`, and already
answers `unhandled-sends` — a send with no matching clause at the receiver.

One projection is missing: the **per-field footprint of each clause**.

## The policy

```clojure
(ns memory.leak
  (:require [system.footprint :as fp] [system.facts :as facts]
            [system.knowledge :as k] [datom]))

;; ── the missing projection: which clause touches which field, in which mode ──

(def schema
  [{:db/ident :touch/clause :db/valueType :db.type/ref}
   {:db/ident :touch/field  :db/valueType :db.type/keyword}
   {:db/ident :touch/mode   :db/valueType :db.type/keyword}])   ; :R :A :W

(defn touch-facts
  "For each clause of a process, one fact per state field it touches, with the
   footprint mode. `(update state :log conj x)` is {:log :A}; `(assoc state
   :log [])` is {:log :W}; `(count (:log state))` is {:log :R}."
  [node]
  (for [c   (facts/clauses node)
        [f m] (fp/state-field-footprint (:body c))]
    {:touch/clause (:db/id c) :touch/field f :touch/mode m}))

;; ── shape 1: a field with an :A and no :W is unbounded ─────────────────────

(def unbounded-field
  '[:find ?proc ?field
    :where [?c :clause/proc ?proc]
           [?t :touch/clause ?c] [?t :touch/field ?field] [?t :touch/mode :A]
           [:not-join [?proc ?field]
             [?c2 :clause/proc ?proc]
             [?t2 :touch/clause ?c2] [?t2 :touch/field ?field] [?t2 :touch/mode :W]]])

;; ── shape 2: a send nobody handles is a mailbox leak ───────────────────────
;; already shipped as system.knowledge/unhandled-sends — reused, not rewritten.

(defn report
  [db]
  {:unbounded-fields (datom/q unbounded-field db)
   :orphan-sends     (k/unhandled-sends db)})
```

Two refinements make the rule useful rather than merely sound:

- An `:A` field whose invariant bounds its length (doc 01) is **not** a leak —
  the append is guarded. The rule joins against `:process/invariant` and skips
  fields with a proven bound. Doc 01 and this doc are the same theorem read
  from two sides: *bounded* ⇒ size the heap; *unbounded* ⇒ warn.
- A `:W` that reduces the field is a shrink; a `:W` that replaces it with
  something larger is not. The first cut treats any `:W` as a possible shrink
  (sound: never a false leak report, possibly a missed one). The second cut
  asks `system.smt` whether `count(field') < count(field)` is satisfiable in
  that clause.

## Beyond warning: the mailbox flag

A receiver proven to have *many* senders (`(count (k/senders-of db proc)) > 8`)
and no orphan sends is a hot mailbox. For those, `message_queue_data: off_heap`
moves the queue out of the process heap so a large backlog does not inflate
every collection. The flag is emitted exactly like doc 01's — a theorem in,
a `process_flag` out.

## What the author sees

A lint. Nothing to annotate. The report reads:

```
memory.leak: mailbox.queue — appended in [:enqueue], never reduced, no bound
             in the invariant. Add (<= (count (:queue state)) K) or a
             clause that drains it.
memory.leak: worker ← supervisor sends :rebalance; worker has no clause for it.
```

## Speed · quality · provability

**Speed.** Neutral for the lint. Off-heap mailboxes cut collection pause on
busy servers in proportion to backlog size.

**Quality.** These two shapes are the most common production leaks on the BEAM
and today they are found by `observer` at 3 a.m. Finding them at compile time,
with the clause named, is the whole value.

**Provability.** Sound-warnings-only, in the `typed` tradition: an unreported
leak is possible (a shrink hidden behind a function the footprint cannot see
collapses to `:opaque-world` and is treated as a `:W`); a false report is not.
Every `.bl` process gains the check; none loses a proof.

## Where it lives

- `system.footprint` — the modes.
- `system.facts/clause-facts`, `system.knowledge/unhandled-sends` — the
  projections and the mailbox query, already shipped.
- `memory.leak` (to build) — the `:touch/*` projection and the unbounded-field
  rule.
