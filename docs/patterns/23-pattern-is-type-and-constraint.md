# 23 — A pattern is a type and a constraint

*A head pattern is the function's domain. A pattern with guards is a
refinement type. A rigid pattern is an SMT datatype. Counterexamples come
back as values that match the negated pattern.*

## `typed` today

`priv/std/typed.bl` is a tag-lattice checker: every expression gets a
tagset (`#{:int}`, `#{:vec}`, `#{:map :nil}`, …), `t-meet`/`t-union` combine
them, mismatches warn (sound-warnings-only). `^{:t …}` annotations give
tags to params. `system.smt/sort-of-tags` maps *scalar* tags to z3 sorts and
answers `:unknown` for compound ones — "Array/Seq/ADT, the next increment".

The compound case is the gap: `typed` knows a param is `:vec` but not
"a 2-vector of ints"; `smt` cannot translate a `:vec` at all. Both need a
*shape*, and the shape is already written — in the head pattern.

## Head pattern = domain

```clojure
(defn area [[^:int w ^:int h]] (* w h))
```

The pattern `[w h]` with tags says: the argument is a sequential of ≥ 2
elements (lenient) whose first two are ints. That *is* the type of the
parameter. `typed` reads it from the pattern's normal form:

```
(:kind [] sequential) (:len [] (:>= 0))
(:bind [(:nth 0)] #w :t #{:int}) (:bind [(:nth 1)] #h :t #{:int})
```

and `check-defn` gets, per param, a **shape** (a normal form) instead of a
tagset. Tagsets become the leaf case of shapes (`(:kind [] int)`).
`t-sub?` becomes `pattern/subsumes?` (capsule 02) — the same relation
used for clause redundancy. One lattice.

Consequences:

- **Callers are checked against shapes.** `(area [1])` warns: literal len 1
  vs `(:>= 2)` needed for `h` to be non-nil… — or, under lenient
  semantics, `h = nil` and `(* w nil)` is the warning. Either way the
  message names the path `[(:nth 1)]`.
- **Return shapes flow.** A body that ends in `[:ok x]` has return shape
  `(:kind vector) (:len (:= 2)) (:eq [(:nth 0)] :ok) …`; a caller
  destructuring `[:ok v]` is checked against it; `[:error e]` on the same
  value is a *reachability* warning (the shape has `:ok` at index 0).
- **`^{:t}` and destructuring converge.** `^{:t [int int]}` on a plain
  param is the same fact as `[^:int a ^:int b]` — one is the annotation
  form, the other the binding form, of one shape. Today they are unrelated.

## Guard = refinement

`(defn safe-div [a b] {:when (not= b 0)} (/ a b))` — the guard refines the
domain: `b ∈ int ∧ b ≠ 0`. In the normal form that is a `:test` constraint,
and with `system.smt` translating `(not= b 0)`, the domain is an SMT
formula. `typed` then answers questions tagsets cannot:

```clojure
(safe-div x (dec y))    ;; where y : int, y > 0 is known from an enclosing guard
;; ⇒ (dec y) ≠ 0 ?   → z3: y > 0 ⊬ y - 1 ≠ 0   (y = 1)  → warn with witness y=1
```

This is liquid/refinement typing (Rondon et al. 2008) with the refinement
language fixed to `system.smt`'s fragment — decidable by construction, and
the fragment already exists.

## Rigid pattern = SMT datatype

`smt/sort-of-tags` returns `:unknown` for `:vec`/`:map`. A rigid-complete
pattern (capsule 22) *is* a datatype declaration:

```
(defrecord Point [x y])         ⇒  (declare-datatype Point ((mk-Point (x Int) (y Int))))
[:ok ^:int v]                    ⇒  (declare-datatype Res ((ok (v Int))))   — one constructor
(?or [:ok ^:int v] [:error ^:string e]) ⇒ two constructors   — a sum type
```

Sum types appear *from* `?or` patterns and from clause lists (capsule 12's
tree over `[:ok _]`/`[:error _]` heads). `system.core`'s invariants then
range over datatypes instead of scalars — `(invariant {:count ?n :when (<=
?n 10)})` translates the state pattern to a datatype and the guard to a
constraint over its accessor. This is the "ADT, the next increment"
`smt.bl` names, obtained as a *read* of patterns rather than a new
annotation language.

Open maps (`{:keys [a]}` without `^:strict`) do not become datatypes: they
are `(Array Kw Any)` in the map theory, with `is_map_key` as `select ≠
absent` — `system.smt` already speaks that. So lenient patterns are still
translatable, just less precisely. The rigid/lenient split (capsule 10) is
the same split as datatype/array here.

## Counterexamples are values

Today an SMT refutation is a z3 model: `(define-fun n () Int 0)`. With
patterns as datatypes, the model *is* an instance of the pattern's
datatype, and `pattern/construct` (capsule 22) turns it back into a bl
value:

```clojure
(veritas/for-all counter-invariant)
;; :refuted
;; witness: (handle-call [:dec] [_ 0])   ← a bl form, printable, re-runnable
;; explain: {:path [(:nth 1)] :expected {:> 0} :got 0 …}   ← capsule 20's explain
```

and because the pattern is a generator, the witness *shrinks* structurally
before it is reported. A counterexample is something you can paste into
the REPL. That closes the loop `veritas` opened: symbolic proof and
sampled property share one witness format — a value matching the
negated pattern.

## Sketch

- `typed`: `sym-type`/`check-defn` operate on shapes (normal forms) with
  tagsets as the scalar leaf; `t-sub?` → `pattern/subsumes?`. Warnings
  carry the failing path. The existing tests in `examples/typing/` are the
  regression set; every current warning must still fire.
- `system.smt`: `sort-of-pattern` alongside `sort-of-tags`; rigid-complete
  → `declare-datatype`; open map → array theory; `?or`/clause-lists → sum
  datatypes. `z3.bl` port unchanged.
- `veritas`: refutation model → `pattern/construct` → shrink → `explain`.
- `codebase`: `(param-shape ?fn ?i ?nf)` and `(return-shape ?fn ?nf)` facts,
  so cross-namespace checks are datalog joins, not re-analysis.
- Gate: `examples/typing/*` unchanged output; `examples/system/*`
  invariants that today are `:untranslatable` because of compound state
  become `:proven`/`:refuted` — list them before, count after.
