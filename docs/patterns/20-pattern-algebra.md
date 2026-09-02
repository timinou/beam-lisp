# 20 — Pattern algebra

*Patterns compose: `and`, `or`, `not`, guards, views. Match is a
first-class expression with a first-class failure, and a failed match
explains itself from the pattern value.*

## Today

Patterns appear only in binding positions (`let`, fn heads, `loop`, `for`)
and in `receive`. `case` is a macro over `cond` with `=` tests
(`priv/boot/core.bl:199`) — it does not destructure at all. There is no
`(match v …)`, no way to ask "does this match", no way to combine two
patterns, and a failed destructure gives `nil` bindings (lenient) or a
`function_clause` with no explanation.

## The algebra

Five new pattern kinds, each a value like the rest (capsule 02):

| syntax | value | meaning |
|---|---|---|
| `(?and p q)` | `{:pat :and :pats [p q]}` | both match the same value; bindings union |
| `(?or p q)` | `{:pat :or :pats [p q]}` | first that matches; both must bind the *same names* (else compile error) |
| `(?not p)` | `{:pat :not :pat p}` | matches iff `p` fails; binds nothing |
| `(?guard p test)` | `{:pat :guard :inner p :test test}` | `p` matches and `test` over its bindings is truthy — this is `:when`, made local |
| `(?view f p)` | `{:pat :view :f f :inner p}` | apply `f` to the value, match `p` against the result |

Views are the powerful one (Wadler 1987, F# active patterns). A few derived
forms, all sugar over `?view` + `?guard`:

```clojure
(?some pred)            = (?guard x (pred x))                ; x is the value
(?re #"(\d+)-(\d+)" [a b]) = (?view #(re-find … %) [_ a b])
(?json p)               = (?view Jason/decode! p)
(?parse int-pattern)    = (?view parse-int (?some some?))
(?type T p)             = (?guard p (instance? T x))
```

A view function must be **pure** — `system.footprint` says so — or the
pattern is refused: a match is not a place for effects, and a pure view is
what lets the obligation (capsule 03) and exhaustiveness (capsule 12)
reason about it (as an opaque-but-deterministic function).

### Lowering

- `?and` → the conjunction of both normal forms (they share the path
  root).
- `?or` → two clauses with the same body; in a decision tree, two leaves
  pointing at one body. Core has no or-patterns; the tree makes them free.
- `?not` → a guard-clause pair: `p when … -> match_fail` then `_ -> body`,
  or, when `p` is fully rigid, the *complement* constraint set (finite
  kind lattice ⇒ computable).
- `?guard` → a `:test` constraint; lowers to a clause guard if
  guard-safe (capsule 11), else a body test with fall-through.
- `?view` → `let T = f(V) in case T of p …`; the tree treats `T` as a new
  column.

## First-class match

```clojure
(match v
  [:ok x]            (use x)
  [:error (?some string?) :as e]  (log e)
  (?or [:retry] :retry)           (again)
  _                  (throw (ex-info "unhandled" {:v v})))
```

`match` compiles to the decision tree of capsule 12 over `v`. No `cond`, no
`=` chain: one `case`. The last clause is optional — a `match` with no
catch-all and a non-exhaustive tree gets a **compile-time warning with the
witness** (`uncovered: [:retry] when … `) and a runtime `match_fail` that
carries the pattern list.

Three companions:

```clojure
(matches? p v)          ;; => boolean; p a pattern value or literal syntax
(bindings p v)          ;; => {a 1, b 2} | nil  — the interpreter, exposed
(explain p v)           ;; => a structured mismatch
```

`explain` is generated from the pattern value + the value: walk both, find
the first constraint that fails, render it with the path:

```clojure
(explain '{:keys [name age] :as p} {:name "x"})
;; => nil  (lenient: matches, age = nil)
(explain '^:strict {:keys [name age]} {:name "x"})
;; => {:path [:age] :expected :present :got :absent
;;     :pattern {:keys [name age]} :message "key :age missing at [:age]"}
(explain '[a b c] [1 2])
;; => {:path [2] :expected {:len (:>= 3)} :got {:len 2} …}
```

Diagnostics stop being hand-written strings in each `RT.*` function.
`typed`'s error messages, `veritas`' counterexample reports, `defserver`'s
"unhandled message" — all are `explain` over a pattern.

## `matches?` as spec

A pattern value with `?guard`/`?view` *is* a spec (clojure.spec's `s/keys`,
`s/and`, `s/or`, `s/conformer` map 1:1 onto `:map`, `?and`, `?or`, `?view`).
`(matches? p v)` = `s/valid?`; `(bindings p v)` = `s/conform`; `(explain p
v)` = `s/explain-data`. beam-lisp gets spec without a second vocabulary —
and unlike spec, the same value compiles to a clause head.

## Sketch

- `priv/boot/pattern.bl`: parse the `?`-forms; `match` interpreter extended
  for the five kinds; `explain` as a variant of `match` that returns the
  failing constraint instead of `fail`.
- `priv/boot/compiler.bl`: `match` as a special form (it needs the tree;
  `case` could become `match` with `=` on literals — Clojure's `case`
  semantics are a subset, ✎ keep both names, one implementation).
- `priv/std/match.bl` (capsule 12): the tree handles `?or` as shared
  leaves, `?view` as derived columns.
- Purity of views: `system.footprint` query at compile time; refusal
  message names the effect.
- Gate: `test/bl/match_test.bl` — every algebra law (`(?and p _) ≡ p`,
  `(?or p p) ≡ p`, `(?not (?not p)) ≡ p` for rigid `p`, de Morgan over the
  kind lattice) checked via `pattern/subsumes?` both ways, plus the
  ce1 oracle for evaluation.
