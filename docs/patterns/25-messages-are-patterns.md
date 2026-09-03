# 25 — Messages are patterns

*A process's receive clauses are patterns. The set of them is its protocol.
Send-side shapes are patterns too. Subsumption between the two is a proof
about communication: no dropped messages, every request answered, every
upgrade total.*

## What exists

`system.model` extracts receive clauses, guards and sends from `receive`,
`loop`/`recur`, `defn` clauses and `defserver` into one transition graph.
`system.knowledge` projects it to datom facts — `:clause/proc`,
`:clause/label`, `:clause/guard`, `:send/to`, `:send/label` — and answers
with datalog: `unhandled-sends` (send with no matching clause — an
anti-join), `invariant-bearing-guarded-sends`, and so on.

The join key is `:label` — the message's *head keyword*. `[:inc]` and
`[:inc 5]` have the same label; `[:set {:count 3}]` and `[:set "x"]` too. The
match is on the first element because that is all the model kept.

## Patterns make the label the whole shape

With receive clauses stored as pattern values (capsule 02), the facts
become `(:clause/pattern ?c ?nf)` and `(:send/shape ?s ?nf)` — normal
forms, not labels. `unhandled-sends` is then a **subsumption** anti-join:

```clojure
;; a send is handled iff some clause of the receiver subsumes its shape
(defn unhandled-sends [db]
  (for [s (sends db)
        :when (not-any? (fn [c] (pattern/subsumes? (:pattern c) (:shape s)))
                        (clauses-of db (:to s)))]
    s))
```

`[:set "x"]` sent to a process whose only clause is `[:set {:keys [count]}]`
is now *unhandled* — the shape doesn't fit — where the label join said it
was fine. With guards translatable to SMT, `subsumes?` is exact: a send of
`[:dec]` to the counter whose `[:dec]` clause has `:when (> n 0)` is
"handled only when `n > 0`" — a **conditional** verdict, joined with the
sender's knowledge of `n` (the invariant it holds, if any).

### The protocol of a process

The set of a process's receive patterns, as one `?or` pattern, *is its
protocol*:

```clojure
(protocol-of counter)
;; => (?or [:inc] (?guard [:dec] (> n 0)) [:reset] [:get])
```

Three things fall out of having this as a value:

1. **Send-site checking.** `(gen_server/call counter [:incr])` — `typed`
   checks the literal `[:incr]` against `(protocol-of counter)`: not
   subsumed → warning with `explain` ("no clause matches `[:incr]`; nearest
   `[:inc]`"). A typo in a message becomes a compile-time error. This is
   what session types promise; here it is a subsumption check over a
   pattern the process already wrote.

2. **Mailbox leak = subsumption failure.** A message not subsumed by any
   clause sits in the mailbox forever (a plain `receive` skips it; a
   `gen_server` crashes or logs). The `unhandled-sends` query *is* the
   static leak detector for the memory-policy work (Q2.2).

3. **Protocol evolution is diffable.** Two versions of a process, two
   protocol patterns; `(pattern/diff old new)` lists added/removed/narrowed
   clauses. Narrowed = a message that used to be accepted and no longer is
   — an API break, found before deploy.

## Request / response completeness

A `handle-call` clause replies with a shape. A caller destructures the
reply. Both are patterns; both are in `codebase`:

```
(:clause/reply-shape ?c ?nf)        from the `reply` form's argument
(:call/expects ?site ?nf)           from the destructuring of the call's result
```

**Completeness**: for every `call` site, the receiver's reply shape (the
`?or` over every clause that can match the sent shape) is subsumed by what
the caller destructures. Fail → the caller will `match_fail` on a reply
the server can legitimately send. Today that is found in production; after,
it is a datalog join plus one `subsumes?`.

Erlang's `gen_server` has no such check; Dialyzer's success typing gets
part-way. Here it costs nothing beyond the patterns already written.

## `code_change` totality

`defserver`'s `code_change [old-vsn state extra]` maps old state to new. Old
state's shape is the *previous* version's `state-shape` (a pattern, in the
AOT manifest — `__bl_provenance__` already stamps versions); new state's
is the current one. The upgrade function is total iff its clauses'
patterns, as a tree (capsule 12), cover the old shape with no `match_fail`
witness. Hot upgrades stop being a hope:

```
(veritas/total? counter/code_change :over (state-shape counter :vsn 3))
;; :proven  | :refuted {:witness {:count 5 :log nil}}   ← old states with nil log
```

## Temporal patterns (a reach)

A `receive` pattern matches *one* message. Over an ordered stream — the
datom tx log, `tempo`, a process's message history — a pattern can span
several: `(?seq p₁ p₂)` (p₁ then p₂), `(?within ms p)`, `(?until p q)`.
These lower to a small state machine over the stream, compiled exactly
like `receive` — a `case` per state. Complex-event processing and
"assert this sequence happened" tests share one vocabulary with
destructuring. `system.model` already treats a process as a transition
graph; a temporal pattern is a query over that graph's *runs*, which is
model checking's native question — `system.core`'s `gfp` over `system.facts`
is the same fixpoint.

## Sketch

- `system.model`: store the clause pattern *value* (not just label) in the
  extracted clause; sends carry the argument's pattern (literal → rigid
  pattern; variable → its `typed` shape; unknown → `:any`).
- `system.knowledge`: `:clause/pattern` and `:send/shape` facts; queries
  rewritten with `pattern/subsumes?` as a datalog predicate (the `datom`
  engine supports fn predicates in `:where`).
- `typed`: at `send`/`call`/`cast` sites with a known target, check
  against `(protocol-of target)`.
- `veritas/total?` over `code_change` = capsule 12's tree on the old shape.
- Gate: `examples/system/*` — every existing `unhandled-sends` result is
  preserved, plus the new shape-level misses (list them: they are bugs in
  the examples or in the query, either way worth seeing); a
  `test/bl/protocol_test.bl` with a deliberate `[:set "x"]` send.
