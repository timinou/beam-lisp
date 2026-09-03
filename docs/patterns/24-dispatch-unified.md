# 24 — Dispatch, unified

*Multimethods, protocols, typed `catch`, `case`, and `match` all choose a
branch by inspecting a value. With patterns as values they are one
mechanism — a decision tree — with several surfaces.*

## Four dispatchers today

| surface | how it chooses | where |
|---|---|---|
| `defmulti`/`defmethod` | a dispatch fn's *result* looked up in a map | `BeamLisp.Multi` (runtime map, `RT.invoke`) |
| `defprotocol`/`extend-type` | the value's type (`__struct__` or kind) looked up in a map | `BeamLisp.Multi.define_protocol` |
| `catch Module.Name e` | `is_struct(e, Mod)` test in a `cond` | `compiler.bl catch-cond-branch` |
| multi-clause `defn` | clause heads + guards, tried in order | `compile-defn*` |
| `case` | `=` chain over literals | `core.bl` macro over `cond` |

Five implementations of "pick a branch by shape". Each has its own error
("No method", "protocol not implemented", `function_clause`, falls off the
`cond`), its own extensibility story (runtime map vs compile-time clauses),
and none can see the others' cases for exhaustiveness.

## One mechanism

Every one of them is: **a list of `(pattern, body)` pairs over a value**.

```clojure
;; multimethod: the dispatch value is a view
(defmulti area :shape)
(defmethod area :circle [{:keys [r]}] (* 3.14 r r))
;; ≡ clause ((?view :shape :circle) {:keys [r]}) → body     ; ?view f p, capsule 20

;; protocol: the dispatch is on kind / struct
(extend-type Point Shape (area [{:keys [x y]}] …))
;; ≡ clause (?and (?type Point) {:keys [x y]}) → body

;; typed catch
(catch ArgumentError e …)
;; ≡ clause {:__struct__ ArgumentError :as e} → body       (already what Core emits)

;; case
(case x 1 :one 2 :two :many)
;; ≡ clauses 1 → … ; 2 → … ; _ → …                          (literal patterns)
```

So each surface becomes syntax that *contributes clauses* to one decision
tree (capsule 12) for a named dispatch point. What differs is only **when
the clause list is closed**:

- `defn`, `case`, `match`, `catch` — closed at compile time; the tree is
  emitted once.
- `defmulti`, `defprotocol` — **open**: `defmethod`/`extend-type` in another
  namespace adds a clause later. The tree must be rebuilt on extension.

The open case is where the unification earns its keep: today an open
dispatch is a runtime map lookup on every call. After: `defmethod` adds a
clause and **recompiles the dispatch fn's tree** (a `defvar` of one fn — the
same hot-reload path every `defn` uses). Calls stay direct; there is no
map. Extension cost is one recompile; call cost is one `case`. This is
what Julia does for multiple dispatch (world-age + recompile) and what
the BEAM's shim/body topology already makes cheap here.

### Walkthrough — a protocol as a tree

```clojure
(defprotocol Shape (area [s]))
(extend-type Point  Shape (area [{:keys [x y]}] (* x y)))
(extend-type Circle Shape (area [{:keys [r]}] (* 3.14 r r)))
(extend-type nil    Shape (area [_] 0))
```

The dispatch fn `area/1` is one Core function:

```
'area'/1 = fun (S) ->
  case S of
    #{'__struct__' := 'Point',  x := X, y := Y} -> X * Y
    #{'__struct__' := 'Circle', r := R}         -> 3.14 * R * R
    nil                                          -> 0
    _ -> erlang:error({protocol_not_implemented, 'Shape', S})
  end
```

`(area p)` is a direct call into a three-clause `case` — the BEAM's own
struct-pattern dispatch, the fastest thing it does. A fourth `extend-type`
rebuilds `area/1` with four clauses; every existing caller's `linked-call`
already points at the namespace shim, which forwards to the new body
(capsule 4 of `research/ce1_core_erlang/` verified this topology in Core).

And the tree knows things a map cannot: the fallthrough is a witness
(`Shape` is not implemented for `%Square{}` — reported at *compile* time
of the caller if `typed` knows the argument is a Square), and two
`extend-type`s for overlapping patterns are a redundancy warning, not a
silent last-wins.

## Multimethod-lite: dispatch by structure

Once `defn` clauses are patterns with guards *and* the tree handles them,
the common multimethod use case needs no `defmulti`:

```clojure
(defn area
  ([{:shape :circle :keys [r]}]     (* 3.14 r r))
  ([{:shape :rect :keys [w h]}]     (* w h))
  ([{:shape :tri  :keys [b h]}]     (/ (* b h) 2)))
```

Statically compiled, exhaustiveness-checked, one `case`. `defmulti` remains
for the *open* case — when clauses come from other namespaces — and is the
same thing with a rebuild-on-extend.

## What this deletes

- `BeamLisp.Multi`'s method/protocol maps → clause lists in `Env` under the
  dispatch var, rebuilt into a tree on change. `satisfies?` = `(matches?
  (protocol-domain Shape) v)`.
- `catch-cond-branch`'s hand-expanded `is_struct` → a struct pattern clause.
- `case` macro → `match` with literal patterns (Clojure semantics preserved:
  literals compared with `=`; the tree uses `=:=` for atoms/ints and falls
  to `=` for the rest, decided per literal kind).
- Five error shapes → one `match_fail` carrying the dispatch name and the
  `explain` of the value against the clause list (capsule 20).

## Sketch

- `priv/std/match.bl` gains *named open trees*: `(match/open! name)`,
  `(match/add-clause! name pat body)` → rebuild + `defvar`.
- `compiler.bl`: `compile-defmulti`/`compile-defmethod`/`compile-defprotocol`/
  `compile-extend-type` emit `add-clause!` calls with pattern values;
  `compile-try`'s catch → clauses; `case` → `match`.
- `Multi` in `lib/` shrinks to whatever interop needs (Elixir-side
  `defimpl` bridging for `Enumerable`/`Inspect` stays — that is role B).
- Gate: every `examples/` and `test/bl/` use of multi/protocol/case/catch
  unchanged in output; `bench/` protocol dispatch (expect: map lookup +
  `RT.invoke` → one `case`); `test/bl/match_test.bl` overlapping-extend
  warning.
