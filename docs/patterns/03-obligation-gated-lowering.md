# 03 — Obligation-gated lowering

*Why "the compiler might silently tighten Clojure's lenient semantics" is
not a risk to manage but a theorem to hold: every lowering choice carries
its own equivalence obligation, and a lowering that fails it is never
emitted.*

## The worry, stated precisely

Today `[a b]` binds `b = nil` on a one-element vector. If a faster lowering
compiled `[a b]` to a Core clause `%Vector{tail: {A, B}}` — exact arity — the
one-element case would fall through to `function_clause`. A program that
relied on leniency would break, and nothing would have warned. That is the
worry: a *semantic* change smuggled in as an *optimisation*.

## The frame

Two functions from values to results, for a pattern `p`:

```
D⟦p⟧ : Value → Bindings | fail      the spec: pattern/match, the step semantics
L⟦p⟧ : Value → Bindings | fail      a candidate lowering: what the emitted Core does
```

`D` exists as code (capsule 02's interpreter). `L` is a *description* of the
emitted Core — the same normal-form constraints, but tagged with how each
is checked (native clause · guard · step).

**Obligation:** `Ob(p, L) := ∀ v. L⟦p⟧(v) = D⟦p⟧(v)`.

**Rule:** the compiler emits `L` iff `Ob(p, L)` is discharged; otherwise it
emits the step lowering `S`, for which `Ob(p, S)` holds trivially (`S` *is*
`D`, generated).

That rule is the whole guarantee. A lowering that changes meaning fails its
obligation and is not chosen. There is no path by which the emitted code can
disagree with `pattern/match`.

## Why the obligation is decidable

`∀ v` over all BEAM terms is not finite. But `D` and `L` only *inspect* a
value through a finite set of observations — kind, length, key presence,
element at index, key value — and for each pattern the set of distinct
observation outcomes is finite. So `v` ranges over an **abstract domain**:

```
kind        ∈ {vector map list tuple record nil scalar lazy …}   (~10, from capsule 01)
len         ∈ {0, 1, …, n, >n}      n = largest index the pattern reads
present(k)  ∈ {yes, no}             for each key k the pattern names
```

Two concrete values with the same abstract shape are treated identically
by both `D` and `L` (neither looks at anything else). So `Ob` reduces to a
finite case split — a few dozen cases for typical patterns — and each case
is a direct evaluation of both sides. This is bounded model checking with
an exact abstraction; no approximation, no solver needed for the pattern
structure itself.

Guards (`:test` constraints) add expressions over bound values. Those are
opaque *unless* they are in `system.smt`'s translatable fragment, in which
case `z3` discharges the guard-dependent cases. Untranslatable guards force
the step lowering for the clauses they govern — conservative, never wrong.
`system.smt` already abstracts collections to their length
(`translate-len`); the abstract domain above is the same abstraction made
explicit.

## Walkthrough

**Pattern:** `[a b]`, lenient, on the one-body vector.

`D`: kind must be vector or sequential; `a = nth 0` (nil if absent); `b = nth
1` (nil if absent).

Candidate `L₁`: one clause `%Vector{cnt: 2, tail: {A, B}}`.
Abstract cases: `len ∈ {0, 1, 2, >2}`.
- `len = 2`: both bind `a, b`. ✓
- `len = 1`: `D` binds `a, b=nil`; `L₁` fails. **✗ — obligation fails.** `L₁` rejected.

Candidate `L₂`: three clauses + fallthrough:
```
%Vector{cnt: 0}              → A = nil, B = nil
%Vector{cnt: 1, tail: {A}}   → B = nil
%Vector{cnt: N, tail: T} when N >= 2 → A = element(1,T), B = element(2,T)   ; small vectors
_                            → steps                                          ; lazy, list, trie
```
Every abstract case agrees with `D`. ✓ — `L₂` emitted. Native for the
common shapes, steps for the rest, *provably* the same meaning.

**Pattern:** `{:keys [a b] :or {b 0}}`.

`L`: one clause with guards:
```
M when is_map(M) → A = case is_map_key(a, M) of true → map_get(a, M); false → nil end,
                   B = case is_map_key(b, M) of true → map_get(b, M); false → 0 end
```
Abstract cases: `kind ∈ {map, record, nil, other} × present(a) × present(b)`.
`D` on `nil` binds `a = nil, b = 0` (`RT.get nil k d = d`). `L` must too — so
the clause needs `M when is_map(M) orelse M =:= nil`, or a second clause.
The obligation *finds* that case; a human writing the lowering would
likely miss it. ✓ after the fix.

**Pattern:** `[a b]` on a value that might be a **`LazySeq`**.

`D` realizes two cells. `L₂`'s fallthrough clause runs steps, which call
`RT.nth` — which realizes two cells. Same observable effect. ✓. If instead
someone proposed "realize the whole seq then match a list" the obligation
would pass on *values* but the footprint would differ (infinite seqs);
that is why the obligation is over `D`'s observations, and realization
depth is one of them (capsule 13).

## What the obligation cannot do — honestly

1. **It does not prove `D` is Clojure.** `D` is bl's current semantics. If
   `D` is wrong relative to Clojure (say `nth` on a list past the end returns
   nil where Clojure throws), the obligation preserves the wrongness
   faithfully. Clojure compatibility is a separate, *differential* question
   (`jank-compat`, `test/bl/prelude_test.bl`) and is unchanged by this work.

2. **It is only as complete as the value domain.** If a kind exists that
   neither `D` nor the abstract domain knows — a second vector
   representation, a struct that is secretly a map — `L` may pass the
   obligation on the enumerated kinds and still miss the unenumerated one.
   This is exactly why capsule 01 comes first: the domain must be closed
   before quantifying over it. The two-body vector *would have been* such a
   hole; the obligation frame is what made it visible before any code was
   written.

3. **Effects are observations too.** `D` may throw (a non-collection to
   `count`), realize lazies, or call user code (`:or` default expressions
   are evaluated lazily in Clojure — only when the key is absent). `L` must
   preserve the *when* of each. The obligation includes them by making
   "throws", "realizes k cells", "evaluates default expr" outcomes of the
   abstract evaluation, not just the bindings.

## The pattern of the pattern

This is not specific to destructuring. Every proof-directed choice in the
Core work has the same shape:

| choice | spec `D` | lowering `L` | obligation |
|---|---|---|---|
| destructuring | `pattern/match` | Core clauses + guards + steps | this capsule |
| tuple instead of map for state (Q2.4) | map semantics of `state` | tuple with field index | ∀ ops used on `state` in the server, same result |
| `persistent_term` for a shared value | `Env.fetch!` | `persistent_term:get` | value never written after init (a *lifetime* proof) |
| native offload (Q2.5) | the bl fn | the NIF | `veritas.property` differential over the domain |
| guard from a user predicate | call the fn | inline as guard | fn is pure ∧ total ∧ guard-safe ops only |

One frame: **the proof selects the program**; the spec stays the one the
user wrote; the obligation is regenerated on every compile. That is
stronger than a one-time verification of the compiler, and it is why the
"risk" is not a residual to be accepted but a class of bug that cannot be
constructed.

## Where it lives

- `priv/std/pattern-ob.bl` — abstract domain enumeration + evaluation of
  `D` and `L` per case; SMT hand-off for translatable guards via
  `system.smt`. Output: `:discharged` | `{:failed case}`.
- The compiler (`compile-let`, `compile-fn-clause`, `compile-pattern`) asks
  `pattern-ob/lowering-for p` → `{:native clauses :steps residual}` or
  `{:steps all}`. No other compiler change; the obligation is a pure
  function of the pattern value.
- `codebase` records `(lowered ?pat :native|:steps ?reason)`, so "which
  patterns in this namespace fall back to steps, and why" is a query — the
  list of things to make provable next.
