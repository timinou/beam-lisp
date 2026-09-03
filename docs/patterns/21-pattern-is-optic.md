# 21 — A pattern is an optic

*Destructuring is selection plus binding. Specter already has selection.
Unify them: one vocabulary for `let`, fn heads, `case`, `for`, `select`,
`transform`, and datalog `:where`.*

## Two vocabularies for one thing

Today beam-lisp has two ways to say "the `:x` inside the first element":

```clojure
(let [[{:keys [x]}] v] x)                 ; destructuring — bind
(select-first [FIRST :x] v)               ; specter (priv/std/specter) — navigate
```

Both walk the same path; one binds a name at the end, the other returns
the value. They have different syntax, different implementations
(`destructure-*` in the compiler; `reify`'d `RichNavigator`s in
`specter.navs`), and neither can be converted to the other.

## The unification

A pattern's normal form (capsule 02) is a set of **paths** with constraints
and bindings. A specter path is a sequence of **navigators**. They
correspond:

| pattern constraint | navigator |
|---|---|
| `(:key k)` | `k` (keypath) |
| `(:nth i)` | `(nthpath i)` |
| `(:rest i)` | `(srange i …)` |
| `(:struct)` / `(:kind K)` | `(pred K?)` — a filter |
| `?guard` | `(selected? …)` / `(pred f)` |
| `?view f` | `(view f)` |
| `?or` | `(multi-path …)` / `(cond-path …)` |
| `& rest`, `[_ & xs]` | `ALL` restricted |

So **a pattern is a bundle of navigators that also names the leaves**. Three
verbs over the one value:

```clojure
(bind p v)        ;; => bindings map        — destructuring
(select p v)      ;; => leaf values, in pattern order
(transform p f v) ;; => v with each bound leaf replaced by (f leaf)
```

`let` is `bind`. `(select [ALL :x] v)` is `(select (pattern [& {:keys [x]}]) v)`
with `ALL` as the `&`. `transform` is what `update-in` wanted to be:

```clojure
(transform '{:keys [count]} inc state)        ; = (update state :count inc)
(transform '[_ {:keys [x]} & _] inc points)   ; second point's x, in place
(transform '(?and [& _] (?some vector?)) … )  ; every element that is a vector
```

### Walkthrough — one pattern, three verbs

```clojure
(def order '{:keys [id lines] :as o})
(def v {:id 7 :lines [{:sku "a" :qty 2} {:sku "b" :qty 1}]})

(bind order v)          ;; => {id 7, lines [...], o {...}}
(select order v)        ;; => (7 [...] {...})
(transform '{:keys [lines]} (fn [ls] (filter #(> (:qty %) 1) ls)) v)
;; => {:id 7 :lines [{:sku "a" :qty 2}]}
```

Nested with the algebra (capsule 20):

```clojure
(transform '{:keys [lines]} (partial transform '[& {:keys [qty]}] inc) v)
;; every line's qty + 1 — two patterns, composed as functions
```

## Everywhere a path is written

| site | today | unified |
|---|---|---|
| `let` / fn heads / `loop` / `for` | destructure syntax | pattern |
| `case` / `match` | `=` chain / n.a. | pattern (capsule 20) |
| specter `select`/`transform`/`setval` | navigator vectors | pattern (navigators = derived patterns) |
| `get-in` / `assoc-in` / `update-in` | key vectors | `(select p)` / `(transform p)` with `:key` paths — the key vector is the degenerate pattern |
| datom pull | pull syntax `[:id {:lines [:sku]}]` | a pattern: `{:keys [id] :lines [& {:keys [sku]}]}` — it *is* a pattern with all leaves bound |
| datalog `:where` | `[?e :attr ?v]` triples | entity maps destructured: `{:db/id ?e :attr ?v}` — the triple form stays as sugar |
| `system.model` state-shape | its own extractor | the pattern the state is bound with, read directly |
| `optics.bl` lenses | separate impl | a rigid, invertible pattern (capsule 22) |

The datalog row is the reach: **pattern subsumption is query containment**.
If `:where` clauses are patterns over entity maps, then "does query A's
result contain query B's" is `(subsumes? pA pB)` — the same normal-form
check — and the sh12b optimizer's magic-set / join-order decisions become
pattern algebra over the `datom.query` plan.

## Why it stays fast

A specter path today is interpreted: navigators are `reify`'d objects
called through `RichNavigator`. A pattern compiles to a Core clause (or a
tree). When the path is a literal — the overwhelming case — `select`/
`transform` on it are compile-time-known and lower to direct `element`/
`map_get`/`setelement`/`maps:put` sequences: zero navigator objects, zero
protocol dispatch. Dynamic paths (built at runtime) fall back to
`pattern/match` — the interpreter — which is still one function, not a
navigator graph.

This is Specter's own "inline caching" trick, obtained for free because the
pattern *is* code.

## Sketch

- `priv/std/optics.bl` becomes `bind`/`select`/`transform` over pattern
  values; `specter.navs` navigators become constructors of pattern
  fragments (`ALL` → `{:pat :vec :rest {:pat :any}}` etc.), preserving the
  `specter` names as aliases.
- `datom.pull` accepts a pattern; `datom.datalog` `:where` accepts entity
  patterns, translating to triples internally (one truth for the planner).
- Compiler: `select`/`transform` with a literal pattern arg are
  macro-expanded to the lowered accessor sequence (an `inline` rule, the
  same mechanism `^{:inline}` uses today).
- Gate: `test/bl/optics_test.bl` (14 tests, exists) + specter's own tests
  must pass through the unified impl; `bench/` literal-path select vs
  today's navigator path.
