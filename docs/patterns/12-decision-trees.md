# 12 — Decision trees

*Multi-clause heads compile to one tree of tests; clause selection happens
in the VM before entry, and the same tree yields exhaustiveness and
redundancy facts.*

## Today: clauses are tried one by one

`(defn f ([[x]] …) ([{:keys [k]}] …) ([_] …))` — `compile-defn*` emits one
`def f(P)` per clause (via `compile-defn-clause`), each with its own
destructuring prelude. The BEAM tries clause 1: runs steps (`RT.nth`); if
the body's own guard fails it moves on. There is no shared test — clause 2
re-inspects the value from scratch.

Erlang's compiler *does* build a decision tree for a clause list — but only
over the parts it can see in the head. Since bl's heads are bare variables
with steps in the body, it sees nothing.

## The tree

Given clauses `c₁ … cₙ`, each with a normal form (capsule 02) and a body,
a **decision tree** is a nested test on the value's observations:

```
test(kind)
├─ vector → test(len)
│           ├─ 1 → [x] matched → body₁
│           └─ _ → test(:keys k)  ; clause 2 can't match a vector, skip
│                   └─ … → body₃
├─ map    → test(has :k)
│           ├─ yes → body₂
│           └─ no  → body₂ (k = nil, lenient) …
└─ _      → body₃
```

Each observation is made **once**. Every path ends in a body (or
`match_fail`). This is Maranget's *compilation to decision trees* (2008);
the input is exactly the constraint normal form.

Core Erlang has nested `case`, so the tree is emitted directly:

```
'f'/1 = fun (P) ->
  case P of
    %Vector{cnt: 1, tail: {X}} -> body₁
    %Vector{} -> body₃
    M when is_map(M) -> let K = … in body₂
    _ -> body₃
  end
```

— which is what the Erlang compiler *would* have produced, had the heads
been visible. Making them visible is the whole trick.

## What the tree knows

Building the tree computes two facts for free:

- **Redundancy**: a clause whose body is never reached by any path is
  unreachable — `typed` today warns on this by re-deriving shapes; the tree
  is the ground truth.
- **Exhaustiveness**: a path ending in `match_fail` is a *witness*: a
  concrete abstract value the function does not handle. If no such path
  exists, the function is total over the domain, and the fallthrough
  (`function_clause`) is deleted (capsule 13).

Both are `codebase` facts: `(unreachable-clause ?fn ?i ?pos)`,
`(uncovered ?fn ?witness)`. `veritas.covers` — already written as "∀ input
∃ clause whose guard accepts it" — becomes a *read* of these facts instead
of a generate-and-test over samples: `:proven` because the tree is exact,
not `:witnessed` because sampling found nothing.

## Walkthrough — a server's handle-call

```clojure
(defserver counter
  (handle-call [:inc]   [_ n] (reply :ok (inc n)))
  (handle-call [:dec]   [_ n] :when (> n 0) (reply :ok (dec n)))
  (handle-call [:reset] [_ n] (reply :ok 0)))
```

Tree over the message:

```
case Msg of
  %Vector{cnt: 1, tail: {inc}}   -> …
  %Vector{cnt: 1, tail: {dec}} when N > 0 -> …
  %Vector{cnt: 1, tail: {reset}} -> …
  _ -> match_fail                         ← witness: [:dec] with n = 0; any other msg
end
```

Two facts fall out. (1) `[:dec]` with `n = 0` is uncovered — the server
crashes on it. `system.core` already proves the invariant `n ≥ 0`; joined
with the tree, the *reachability* of that witness under the invariant is a
SMT query, and `z3` answers "reachable" → a real bug surfaced as a
counterexample. (2) The message vocabulary is `{[:inc] [:dec] [:reset]}` —
the server's *protocol*, extracted (capsule 25).

## Sketch

- `priv/std/match.bl` (`self.match` in the design doc): `clauses → tree`
  (Maranget's algorithm over the normal-form matrix; heuristics: column
  with most rigid constraints first), `tree → cerl` (nested `c_case`),
  `tree → facts` (unreachable, uncovered witnesses).
- Consumers: `compile-defn*` and `compile-fn*` hand the clause list to
  `match/compile` instead of emitting per-clause defs; `defserver` callback
  groups likewise; `receive` already has a clause list — same path.
- Obligation (capsule 03): the tree is a *lowering*; `Ob(clauses, tree)` is
  checked by evaluating both on every abstract path — the tree's own paths
  are the enumeration.
- `typed` and `veritas.covers` consume the facts; their own re-derivations
  are deleted (one truth).
- Gate: ce1 oracle + `bl test`; `bench/pattern_bench.bl` multi-clause
  dispatch case; a `test/bl/match_test.bl` pinning redundancy/exhaustiveness
  on hand-written clause lists including the `[:dec]`/`n=0` witness.
