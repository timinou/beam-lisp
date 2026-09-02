# 10 — The rigid / lenient split

*Same meaning, better code: the part of a pattern that Core can match
natively is matched natively; only the lenient remainder becomes steps.*

## Today: everything is steps

`(defn area [[w h]] (* w h))` compiles (via `compile-defn-clause` →
`bind-param` → `destructure-vector`) to:

```
fun (Whole) ->
  let W = 'Elixir.BeamLisp.RT':nth(Whole, 0) in
  let H = 'Elixir.BeamLisp.RT':nth(Whole, 1) in
  erlang:'*'(W, H)
```

Two remote calls, each dispatching on the collection kind at runtime, before
the body starts. The BEAM could have matched `{W, H}` in the clause head
with zero calls — but the head is `fun (Whole)`.

Why steps: the vector might be a list, a lazy seq, a tuple, a trie; it might
have one element (`h = nil`). Steps handle all of that. They are the
*general* lowering — correct everywhere, fast nowhere.

## The split

A pattern's normal form (capsule 02) is a set of constraints. Partition it:

- **rigid** — constraints Core can check in a clause head or guard: kind
  (`is_map`, struct test), fixed length (`tuple_size`, `cnt` field), key
  presence (`is_map_key`), literal equality, `:as`.
- **lenient** — constraints whose *failure* must still succeed with a
  default: "element 1, or nil if absent", "key `:b`, or 0 if absent", any
  access into a lazy seq.

Lower the rigid part as Core clauses; lower the lenient remainder as steps
*inside* the matched clause; add a fallthrough clause running all-steps for
values whose kind the rigid clauses don't cover. Capsule 03's obligation
checks the result equals the step semantics.

### Walkthrough — `[w h]`

Normal form (one-body vector, capsule 01):

```
(:kind [] sequential)           ; vector | list | lazy
(:bind [(:nth 0)] #w)           ; nil if absent
(:bind [(:nth 1)] #h)
```

Split: kind is rigid *per kind*; the binds are lenient (absent → nil).
Emitted:

```
'area'/1 =
fun (P) ->
  case P of
    %Vector{cnt: C, tail: T} when C >= 2 ->       ; rigid: small vector, both present
        let W = element(1, T), H = element(2, T) in erlang:'*'(W, H)
    [W, H | _] ->                                  ; rigid: list with ≥2 elements
        erlang:'*'(W, H)
    _ ->                                           ; everything else: steps
        let W = RT:nth(P, 0), H = RT:nth(P, 1) in erlang:'*'(W, H)
  end
```

The common calls (a 2-vector, a 2-list) match in the head; the rare ones
(short, lazy, trie) take the old path. Obligation: 4 kinds × len ∈ {0,1,2,>2}
— every case agrees with `pattern/match`. ✓

### Walkthrough — `{:keys [name age] :or {age 0} :as person}`

```
(:kind [] map-like)  (:bind [] #person)
(:bind [(:key :name)] #name)            ; nil if absent
(:bind [(:key :age)]  #age :default 0)
```

Rigid: `is_map`. Lenient: both keys. Emitted (capsule 11 shows the guard
form; this is the clause form):

```
case P of
  #{name := Name, age := Age} = Person -> body            ; both present: pure head match
  #{name := Name} = Person             -> let Age = 0 in body
  #{age := Age} = Person               -> let Name = nil in body
  Person when is_map(Person)           -> let Name = nil, Age = 0 in body
  Person                               -> steps           ; nil, records with custom get, …
end
```

Four clauses for two optional keys — 2ⁿ. Capsule 12's decision tree
collapses this to a tree of `is_map_key` tests (n nodes), and capsule 11 to
guarded reads (n guards). The clause form here is the *spec* of what those
must equal.

## Where the split pays

| pattern site | today | after |
|---|---|---|
| `defn` heads (`fn-clause`) | 1 `fun` + n steps | k clauses, steps only in fallthrough |
| `let` with vector/map patterns | applied lambdas + steps | `c_case` over the value |
| `loop` bindings with patterns | re-destructure every iteration | rigid re-match every iteration (a head match, not calls) |
| `for` / `doseq` bindings | steps per element | per-element clause match |
| `receive` clauses | already rigid (message patterns are Erlang patterns) | unchanged — the receive path was always the "good" one |

The `receive` row is the tell: bl already compiles `receive` patterns
rigidly because the compiler *knew* messages are tuples. The split extends
that knowledge to every binding site, gated by proof instead of by the
special form.

## Interaction with `typed`

When `typed` knows the argument's tag — `(defn area [^:vector [w h]] …)` or
inferred from the caller — the fallthrough clause is *unreachable*, and the
rigid clause is the whole function. The obligation then quantifies over the
narrowed domain (`kind = vector` only), which is where "proven-exhaustive
drops `match_fail`" (capsule 13) comes from. Types and patterns are the same
facts read from two sides.

## Sketch

- `pattern-lower/split` : normal form → `{:rigid cs :lenient cs}`, a filter
  on constraint kind + a check that a rigid constraint's *failure* is
  `fail` in `D` (not a default). If a constraint fails-to-default in `D`, it
  is lenient by definition.
- `pattern-lower/clauses` : rigid set → Core clause list per kind in the
  domain; lenient residual → steps inside each clause; fallthrough = all
  steps.
- `pattern-ob/check` (capsule 03) on the result. Fail → all-steps.
- Emission site: `research/ce1_core_erlang/ce1.bl` `lower-fn` /
  `defs->module` already build `c_case` over param tuples; the split slots
  in as "the clause list for this head" instead of one clause.

Gate: `bl test` (values), the ce1 wide oracle (both backends agree), and a
new `bench/pattern_bench.bl` — a 2-vector head called 10⁶ times, steps vs
split. Expect the head match to remove two remote calls per invocation;
measure before claiming.
