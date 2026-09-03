# 01 — One value model

*What a beam-lisp value is on the BEAM today, every quirk that follows from
having several answers, and the single model that removes them.*

## Why this comes first

A pattern matches a *value*. If the language has two representations for
"vector", a rigid pattern must know both or silently miss one. If `=` says
`[1 2]` equals a lazy `(1 2)` but not a list `(1 2)`, a proof about a
pattern's coverage is a proof about the wrong thing. Everything downstream —
patterns, proofs, lowering — is only as clean as the value model under it. So
the value model is unified first.

## The zoo today

beam-lisp values are BEAM terms. The mapping (from `lib/beam_lisp/rt.ex`,
`vector.ex`, `guards.ex`, `record.ex`, observed 2026-09-02):

| bl value | BEAM term | notes |
|---|---|---|
| nil / bool / number / keyword | atom / number | keywords are atoms |
| string | binary | charlist `(97 98)` is a *list*, not a string |
| symbol | `{:symbol, "name"}` | internal tag |
| list `(1 2)` | Erlang list | |
| vector ≤ 32 | `%Vector{items: {1, 2}, meta}` | struct around a **tuple** |
| vector > 32 | `%Vector{items: {:bl_vec, cnt, shift, root, tail}}` | struct around a **trie** |
| Erlang tuple | tuple | positional collection, unless its head is an internal tag |
| map | map with `hash_key`-normalized keys | plain maps only (`is_bl_map` excludes structs) |
| set / sorted-set / sorted-map | `%Set{}` / `%SortedSet{}` / `%SortedMap{}` | structs |
| lazy seq | `%LazySeq{key, thunk}` | per-instance ref for metadata |
| record | `%Ns.Name{}` — a `defstruct` module | map-like |
| deftype / reify | `{:bl_deftype, mod, fields}` / `{:bl_reify, ref, caps}` | opaque tuples |
| fn | fun · `{:"$blfn", fixed, variadic}` · `{:"$remote", m, f}` · `{:"$macro", f}` | four shapes |
| metadata | `Vector.meta` field · `LazySeq` side table · none elsewhere | |

Nine internal tuple tags (`guards.ex @internal_tuple_tags`) exist so that
"a tuple is positional data" can be true *except* for these.

## The quirks — observed, not inferred

Each line is a `./bl run` result on `main @ 698225c`.

**Equality is not one relation.**
1. `(= [1 2] (list 1 2))` → `false`, but `(= [1 2] (map identity [1 2]))` → `true`. A vector equals a *lazy* seq of the same elements but not a *list* of them. `eqv` checks laziness before vector-ness, so the walk path and the vector path disagree.
2. `(= [] (map identity []))` → `true`, `(= #{} (map identity []))` → `false`, `(= [] ())` → `false`. Three empties, three answers.
3. `(= (vec (range 40)) (range 40))` → `true` (lazy), `(= (vec (range 40)) (apply list (range 40)))` → `false`. Same as 1 for the trie representation — the two vector representations at least agree with each other.
4. `(= (sorted-map :a 1) {:a 1})` → `true` but `(= (->P 1) {:x 1})` → `false` for a record with field `x`. Sortedness is "an index property, not identity"; struct-ness is identity. Both are maps.
5. `(= 1 1.0)` → `true` but `(get {1 :a} 1.0)` → `nil`. `=` is numeric; map keys are structural. Clojure has the same split, but bl's `hash_key` normalizes metadata away and nothing else.

**Vectors have two bodies.**
6. `(erlang/element 1 (Map/get (vec (range 40)) :items))` → `:bl_vec`; for `(vec (range 32))` `:items` is a plain tuple. `conj` on a 32-vector produces a 33-trie; `pop` on a 33-trie produces a 32-tuple. The representation flips at a size boundary, invisibly.
7. A rigid pattern `%Vector{items: {A, B}}` matches only the tuple body. A user tuple `{:bl_vec, 1, 2, 3, 4}` is disambiguated from a trie only by `cnt > 32` — a heuristic on a magic count.
8. `(count (erlang/list_to_tuple (list :bl_vec 1 2)))` → throws. A user tuple whose first element happens to be `:bl_vec` (or `:symbol`, or `:meta`) is not data. The tags are "not spellable as keywords" — `:bl_vec` is spellable.

**Tuples are half a collection.**
9. `(count t)` → 3, `(first t)` → 1 for an Erlang tuple, but `(get t 1)` → `nil` and `(nth t 1)` works. Positional for seq ops, not for `get`.
10. `[p q]` as a *pattern* matches a tuple OR a vector, doubling clause alternatives at every nesting level, with a hard ceiling (`max-pattern-alternatives`) and a compile error past it. The pattern layer pays for the value layer's ambiguity.

**Leniency is uneven.**
11. `(nth [1 2] 5)` → `nil`; `(nth (list 1 2) 5)` → `nil`; `(get (list 1 2 3) 1)` → `nil` (not 2). `nth` is lenient everywhere; `get` refuses lists.
12. `(count nil)` → 0, `(count 5)` → throws, `(count inc)` → throws, `(count deftype-instance)` → throws. Four non-collections, two behaviours.
13. `(seq [])` → `nil`, `(seq #{})` → `nil` — good — but `(rest x)` returns `[]` (a list) for every kind, so `(rest [1])` is `()`, not `[]`. Clojure-correct, but it means "vector-ness" is lost after one `rest`, and a rigid vector pattern on the result fails.

**Strings are not seqs of anything you can spell.**
14. `(seq "ab")` → `("a" "b")` — one-char binaries; `(count "héllo")` → 5 (graphemes). A charlist `(97 98)` has `count` 2 and `string?` false. Three string-like things: binary, seq-of-binaries, charlist.

**Metadata leaks into identity in one direction.**
15. `(= (with-meta [1] {:m 1}) [1])` → `true` and a set of both has one element — correct — but only vectors and lazy seqs carry metadata at all; `(with-meta {:a 1} m)` has nowhere to put it.

**Records are maps with a `__struct__` key.**
16. `(assoc (->P 1) :y 2)` keeps the struct and adds `:y` — a record with an extra field is still "a P". `(seq p)` → `([:x 1])` hides `__struct__`; `Map.keys` shows it. Two views of one map.

**Functions are four shapes.**
17. A fun, a `$blfn` multi-arity table, a `$remote` handle, a `$macro` wrapper. `RT.invoke` dispatches on all four; `(fn? x)` must know all four; a rigid pattern cannot say "any callable".

Seventeen quirks, one cause: **the value model was assembled per-feature, and each feature answered "what is a vector / a seq / equal" locally.** Every quirk is a place where two local answers meet.

## The one model

Design. Not implemented. Marked ✎ where a choice is open.

### Principle

**One kind ⇒ one BEAM shape ⇒ one guard.** Every bl kind is recognizable by a
single guard-safe test, and no two kinds share a shape.

| bl kind | shape | guard |
|---|---|---|
| vector | `%Vector{}` with **one** body (see below) | `is_map_key(v, :__struct__) andalso map_get(:__struct__, v) =:= Vector` |
| tuple | Erlang tuple, **always** positional data | `is_tuple` — no tag exclusions |
| list / seq | Erlang list, or `%LazySeq{}` | `is_list` / struct test |
| map | plain map | `is_map andalso not is_map_key(:__struct__)` |
| record | struct | struct test |
| fn | **one** shape | see below |

Three moves make that table true:

**1. Internal tags leave the tuple space.** Symbols, macros, remote handles,
deftype/reify instances, the vector trie: none of them should be tuples that
happen to start with an atom. Two options, ✎:
  - *(a)* make each a struct: `%Symbol{}`, `%Macro{}`, `%Deftype{mod, fields}`. Guard: struct test. Cost: a map per symbol (reader nodes are symbol-dense; measure).
  - *(b)* keep tuples but use **references**, not atoms, as tags: a tag atom is spellable; a `make_ref()` created at boot is not. `{tag_ref, …}`. Guard: `element(1, t) =:= persistent_term:get(bl_tag)` — guard-safe. Cost: zero allocation change.
  ✎ (b) is cheaper and keeps reader nodes as-is; (a) is more legible. Either way `@internal_tuple_tags` and `is_data_tuple` are deleted: a tuple is a tuple.

**2. The vector has one body.** ✎ Two options:
  - *(a)* **always trie**: `%Vector{cnt, shift, root, tail}` as struct *fields*, never a nested tagged tuple. ≤32 elements = empty root + tail tuple. `nth` is one shape. Rigid patterns on small vectors become `%Vector{cnt: 2, tail: {A, B}}` — still native. Cost: one more map lookup per `nth`; literals `[1 2]` build a 4-field struct instead of a 2-field one (constant).
  - *(b)* **always tuple, trie is a separate kind**: small vectors stay `%Vector{items: tuple}`; large ones become `%BigVector{}` — a different struct, same protocol. Patterns match `%Vector{}` only (rigid on ≤32 is the common case); `%BigVector{}` matches through steps. Cost: `conj` at 32 changes struct; every RT clause doubles.
  (a) is the honest one: one kind, one shape, and the boundary at 32 becomes an internal fact of `nth`, not a fact about the value. The magic `cnt > 32` disambiguation disappears with it.

**3. Functions have one callable shape.** Every fn value is a BEAM fun.
Multi-arity: `fun(Args...)` with a `case` on arity generated at `defn` (the
`$blfn` table becomes the fun's own dispatch); remote: `fun M:F/A` (a real
external fun, guard-safe `is_function`); macro: a fun with a marker in its
*metadata* (`fun_info`) or a struct `%Macro{f}` since macros are never called
at runtime by user code. `RT.invoke` shrinks to `apply`. `(fn? x)` is
`is_function`. A pattern can say "a callable": `(?fn f)`.

### Equality becomes one relation

With one shape per kind, `=` is *structural equality modulo kind*:

```
eqv(a, b) :=
  kind(a) ≠ kind(b)             → false, except the seq family
  seq family (list, lazy, vector, tuple?)  → element-wise      ✎ tuple in or out
  map family (map, record, sorted-map)     → entry-wise, kind-blind   (records ≠ maps? ✎)
  set family (set, sorted-set)             → member-wise
  scalars                                  → ==
```

Two ✎ decisions are Clojure-compat questions, not implementation ones:
- Clojure: vector = list = lazy seq (all *sequential*); tuple has no Clojure
  analogue. Today bl says vector ≠ list but vector = lazy — that is a bug, not
  a policy. Recommend: **sequential family = {list, lazy, vector}**, tuple
  positional-but-not-sequential (so `[1 2] ≠ {1,2}`, which the pattern layer
  already treats as distinct alternatives).
- Clojure: record ≠ map, sorted-map = map. Keep both.

`hash_key` then normalizes exactly the sequential family to one canonical
form (a list) plus metadata stripping, so `(get {[1 2] :v} (list 1 2))` finds
the value — quirk 5 and the `[1 2]`-as-key surprise both close.

### Leniency becomes one policy

`nth`/`get`/`count`/`seq` each become a small total table:

|  | non-collection | absent |
|---|---|---|
| `get` | `default` | `default` |
| `nth` | `default` (nil) | `default` (nil) |
| `count` | **0 for nil, error otherwise** ✎ (Clojure errors) | — |
| `seq` | error for non-seqable | nil for empty |

and `get` on a list/tuple by index is either allowed (positional) or refused
(Clojure refuses lists, allows vectors) — ✎, but decided *once*, in the table,
not per clause.

### Metadata is uniform

`meta` slot on every struct kind (vector, set, sorted-*, record via a
reserved key, lazy via its ref); plain maps and lists carry none (Clojure:
they do — ✎ either wrap or accept the gap, but say so).

## What the unification buys the rest of the capsule set

- **Rigid patterns become expressible.** `[a b]` = `%Vector{cnt: 2, tail: {A, B}}` — one Core clause, no alternatives explosion (quirk 10 dies; the `max-pattern-alternatives` ceiling with it).
- **The obligation (capsule 03) has a finite domain.** "∀ vector v" quantifies over one shape.
- **`typed`'s tags map 1:1 to guards.** `:vector` ⇔ one guard; today `:vector` ⇔ two shapes plus a tuple heuristic.
- **`system.smt` sorts map 1:1 to kinds.** A datatype per kind, no "tuple that might be a vector".
- **The reader is simpler.** Nodes no longer share the tuple space with user data; `reader-node.bl`'s accessors become struct field reads.

## Migration shape

Not a rewrite — a cutover per kind, each behind the existing differential
oracle:

1. Tags → refs or structs (`guards.ex`, `rt.ex invoke/first/rest/count`, `reader-node.bl`). Gate: `mix test` + `bl test`.
2. Vector one-body (`vector.ex`; `compiler.bl` literal + pattern emission — the pattern branch loses its `tuple-pat` alternative). Gate: the same, plus `research/ce1_core_erlang/oracle.bl`.
3. `eqv` rewrite to the family table. Gate: a new `test/bl/equality_test.bl` that pins every row of the table — this file is the spec.
4. Leniency table for `get`/`nth`/`count`/`seq`. Same gate.
5. Fn one-shape. Gate: `bench/` (call overhead must not regress; `$blfn` dispatch is on every multi-arity call).

`feat/fully-self-hosted` carries `CompilerOptions` (VM-wide, no restore) and
`build-plan.bl` (waves); both matter here only in that steps 1–2 rotate the
compiler key and rebuild the prelude — batch them per wave as PLAN-072 says.
