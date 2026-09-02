# 11 — Leniency as guards

*Defaults, absence and "or nil" are not reasons to leave the clause head.
The BEAM's guard-safe BIFs express them without a call and without an
allocation.*

## What a guard is, and why it is free

A clause `fun (X) when is_integer(X) andalso X > 0 -> …` runs the guard
*before* committing to the clause: no stack frame, no heap allocation, no
exception (a failing BIF in a guard just makes the guard false). Only a
whitelist of BIFs is allowed — the ones the VM knows are pure, total, and
cheap. Among them: `is_map_key/2`, `map_get/2`, `tuple_size/1`,
`element/2`, `hd/1`, `tl/1`, `length/1`, comparisons, arithmetic.

Elixir exposes some of these as `Kernel` guard macros, and bl's
`compile-guard` inherits that list. Core exposes the property directly
(`docs/core-erlang/what-simpler-means.md` §3): a guard is any expression of
guard-safe calls, and bl decides which calls those are.

## Leniency, expressed as guards

| lenient construct | step today | guard form |
|---|---|---|
| `{:keys [b] :or {b 0}}` | `RT.get(m, :b, 0)` | clause A: `#{b := B}`; clause B: `_ when is_map(M) → B = 0` |
| `{:keys [a]}` (absent → nil) | `RT.get(m, :a)` | `#{a := A}` else `A = nil` |
| `[a b]` on short vector | `RT.nth(v, 1)` → nil | `when C >= 2 → element(2, T)` else `nil` |
| `(nth xs i)` with bound `i` | call | `when is_tuple(T), i < tuple_size(T)` |
| `{:strs ["k"]}` | `RT.get(m, "k")` | `#{<<"k">> := V}` — binaries are literal patterns |
| `:as` | `let m = whole` | alias `= M` in the head |

The `:or` row is the important one. Clojure evaluates the default
expression **only when the key is absent** (it may be a call with effects).
The guard form preserves that: the default lives in the else-clause body,
evaluated only on that path. A naive "`map_get` with default" BIF would
evaluate it eagerly. The obligation (capsule 03) treats "evaluates default
expr" as an observation, so the eager version fails its obligation. ✓

## Walkthrough — one clause, n optional keys, no 2ⁿ blowup

Capsule 10 showed four clauses for two optional keys. Guards let a
*single* clause read each key conditionally:

```clojure
(defn greet [{:keys [name title] :or {title "Dr."}}] (str title " " name))
```

```
'greet'/1 = fun (M) when is_map(M) ->
  let Name  = case is_map_key(name, M)  of true -> map_get(name, M);  false -> nil   end in
  let Title = case is_map_key(title, M) of true -> map_get(title, M); false -> "Dr." end in
  …
'greet'/1 = fun (M) -> steps   ; nil, records, …
```

Each `case` on a guard-safe test compiles to a branch on a register — no
call, no allocation. n keys ⇒ n small cases, linear. The clause head keeps
only the rigid `is_map`.

This is the same shape `system.smt` already reasons about: `is_map_key`
and `map_get` are exactly the map-theory operations it translates. So the
guard form is not only fast — it is the form the prover reads natively.

## Guard-safety as a property bl owns

Today: "is this predicate allowed in a guard" = "does Elixir have a Kernel
macro for it". After: a table `guard-safe?` in `priv/boot/pattern.bl`,
seeded from the BEAM's list, and **extensible by proof**: a user predicate
`(defn adult? [p] (>= (:age p) 18))` is guard-safe iff its body, after
inlining, is composed only of guard-safe calls — a syntactic check the
compiler can make. `system.footprint` already computes purity; the guard
check is purity ∧ totality ∧ BIF-only ∧ no allocation (no `str`, no `conj`).

So `(defn f [p] {:when (adult? p)} …)` inlines `adult?` into the clause
guard; the call disappears; the guard is one comparison. And because the
inlined form is translatable, `veritas.covers` (already in `veritas.bl`)
can prove clause coverage over it.

## Where the guard form cannot go

- **Anything that allocates**: `str`, `conj`, `assoc`, `map` — not in guards
  by VM rule. Stays in the body.
- **Anything that can throw with meaning**: a guard failure is silent
  `false`; if the program expects the exception (`(nth xs 5)` on a list
  *throws* in Clojure) the guard form changes behaviour → obligation fails
  → step form kept. The obligation catches it, as designed.
- **User functions not proven guard-safe**: called in the body after the
  head, as today.

## Sketch

- `pattern-lower/guard-read` : a lenient `(:bind path id :default d)` → `let
  id = case <guard-test path> of true → <guard-read path>; false → d end`,
  with `<guard-test>` / `<guard-read>` chosen per accessor
  (`:key`→`is_map_key`/`map_get`, `:nth`→`tuple_size`/`element` for the
  vector tail, `hd`/`tl` chains for lists up to a small bound).
- `guard-safe?` table + `inline-guard` in `priv/boot/pattern.bl`.
- Emission: `ce1.bl lower-clauses` already carries guards to `c_clause`;
  the guard-read lets are body prefixes, emitted by `lower` for the
  `:bind`-with-default constraint.
- Gate: obligation per pattern; `bench/pattern_bench.bl` map-destructure
  case (expect: `RT.get` calls → 0 for map inputs).
