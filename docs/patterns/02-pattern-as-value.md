# 02 — The pattern as a value

*What a pattern is when it is data: its shape, its identity, how hygiene
works when patterns are built by macros, and the normal form that makes
questions about patterns decidable.*

## Today: a pattern is syntax

`(let [{:keys [a b] :or {b 0} :as m} v] …)` — the `{:keys …}` form is a
reader node (`{:map, [pairs]}`) that `compiler.bl`'s `destructure-map`
consumes directly, emitting binding steps. The pattern exists only for the
duration of `compile-let`. Nothing else can see it: not `typed`, not
`codebase`, not a macro that wants to build one, not a test that wants to
check what it accepts.

## The pattern value

A pattern is a plain bl value — a map with a `:pat` key — built by the
reader-node→pattern parser (`pattern/parse`, the part of `destructure-*`
that *reads* the syntax, split from the part that *emits* steps):

```clojure
;; syntax                         ;; value
_                                 {:pat :any}
x                                 {:pat :bind :name x :id #7}
:k / 42 / "s"                     {:pat :lit :value :k}
[a b]                             {:pat :vec :items [{:pat :bind …} {:pat :bind …}]}
[a & more]                        {:pat :vec :items [{:pat :bind …}] :rest {:pat :bind …}}
[a :as all]                       {:pat :as :name all :inner {:pat :vec …}}
{:keys [a b] :or {b 0}}           {:pat :map :entries [{:key :a :pat {:pat :bind :name a}}
                                                       {:key :b :pat {:pat :bind :name b} :default 0}]}
{x :key}                          {:pat :map :entries [{:key :key :pat {:pat :bind :name x}}]}
{:strs [s]}                       {:pat :map :entries [{:key "s" :pat …}]}
(quote datum)                     {:pat :lit :value datum}
x :when (pos? x)   (head guard)   {:pat :guard :inner {:pat :bind …} :test (pos? x)}
```

Every `:bind` carries `:name` (the symbol as written) and `:id` (a unique
identity, see below). Nested patterns nest as values. Position metadata
(`:line :col :file`) rides along as `:pos` on every node, exactly as reader
nodes carry it today.

That's the whole vocabulary for what the compiler accepts *today*. Capsule
20 adds `:and`/`:or`/`:not`/`:view`; capsule 26 adds `:absent`.

### Walkthrough — it is data

```clojure
(def p (pattern/parse '{:keys [a b] :or {b 0} :as m}))
;; => {:pat :as :name m
;;     :inner {:pat :map :entries [{:key :a :pat {:pat :bind :name a :id #12}}
;;                                 {:key :b :pat {:pat :bind :name b :id #13} :default 0}]}}

(pattern/binds p)        ;; => (a b m)
(pattern/keys-read p)    ;; => (:a :b)
(pattern/lenient? p)     ;; => true   (b has a default; a may be absent → nil)
(pattern/matches? p {:a 1})   ;; => true, binds {a 1, b 0, m {:a 1}}
```

The last one is the point: **a pattern can be run without being compiled**,
because it is a value with an interpreter (`pattern/match`, ~40 lines: the
step semantics of `destructure-*`, as a function instead of an emitter).
That interpreter *is* the spec `D⟦p⟧` in capsule 03.

## Identity

Two patterns with the same shape and the same names are not the same
pattern if they came from different places — a macro that expands twice
must not make its two `x`s collide. So a `:bind` has an `:id`: a fresh
reference (`make_ref`) at parse time, or — for AOT determinism (the branch's
`W2: deterministic emit`) — a hash of `(file, line, col, occurrence)`.

Identity does three jobs:

1. **Lowering names** — `x#12` → the Core variable `_x_12`. Today `fresh-var`
   does this with a counter; the id makes it a property of the pattern, not
   of the compile run.
2. **Equality of patterns** — `(= p q)` compares shapes *ignoring* ids
   (pattern algebra), `(identical? p q)` compares ids. Both needed:
   subsumption is shape; "is this the binding I introduced" is id.
3. **Provenance** — `codebase` facts `(binds ?fn ?name ?id ?pos)` let "where
   is this local bound" and "which clause introduced it" be datalog.

## Hygiene

Hygiene = a macro's names don't capture the caller's, and vice versa.
beam-lisp already does this for syntax-quote: `x#` auto-gensyms to a
template-stable unique name (`compiler.bl resolve-gensym`). Patterns as
values need the same guarantee when a macro *constructs* a pattern:

```clojure
(defmacro with-point [p & body]
  ;; build a pattern value, not pattern syntax
  `(let [~(pattern/vec [(pattern/bind 'x) (pattern/bind 'y)]) ~p] ~@body))
```

Here `x` and `y` are the *caller's* names — intended capture, like Clojure's
`~'x`. If the macro wanted private names it uses `(pattern/bind (gensym "x"))`.
Rule: **a pattern constructor takes a symbol; the symbol's provenance is the
hygiene.** `pattern/bind` with a plain symbol = caller-visible; with a gensym =
private. This is exactly syntax-quote's rule, applied to pattern values, so
there is one hygiene story, not two. The `:id` is orthogonal: it is always
fresh, and never affects which *name* is visible.

What this needs in the compiler: `compile-let`/`compile-fn-clause` accept a
pattern *value* where they accept a pattern node today (`(if (pattern? x) x
(pattern/parse x))`), and `put-local` keys the env on `:id`, not on the
name string — so two locals named `x` with different ids can coexist in
scope and the *later* shadows by name, as now.

## Normal form

Why: to decide "does pattern `p` cover everything `q` covers"
(subsumption), "do these clauses cover the whole domain" (exhaustiveness),
"is this clause unreachable" (redundancy), and "is this lowering equal to
the spec" (obligation), the pattern must be compared structurally. Two
syntaxes for one meaning (`{x :k}` vs `{:keys [k]}` when `x = k`; `[a & _]`
vs `[a & rest]` when `rest` is unused; nested `:as`) must first become one
form.

**The normal form is a conjunction of atomic constraints on paths**, where a
path is a sequence of accessors into the value:

```
path      ::= []  |  path ++ [acc]
acc       ::= (:nth i) | (:key k) | (:rest i) | (:struct)
constraint ::= (:kind path K)          K ∈ {vector map list tuple record …}
             | (:len path (:= n) | (:>= n))
             | (:has path k)           key present
             | (:eq path v)            literal
             | (:bind path id)         binding
             | (:test id form)         guard over bound ids
```

So `{:keys [a b] :or {b 0} :as m}` normalizes to:

```
(:kind [] map)              ; lenient: absent → the default rule below
(:bind [] m)
(:bind [(:key :a)] #12)     ; absent → nil
(:bind [(:key :b)] #13 :default 0)
```

and `[a b]` on the one-body vector (capsule 01) to:

```
(:kind [] vector) (:len [] (:>= 0))    ; lenient today: b may be nil
(:bind [(:nth 0)] #a) (:bind [(:nth 1)] #b)
```

with `^:strict` (capsule 26) tightening `(:len [] (:= 2))`.

Properties of this form:

- **Canonical**: constraints sorted by path then kind; ids renamed
  positionally for shape comparison. Two patterns are equal iff their
  normal forms are.
- **Subsumption is set inclusion**: `p ⊒ q` iff every constraint of `p` is
  implied by some constraint of `q`, where implication is decided per
  constraint kind (`(:len (:>= 1))` ⊒ `(:len (:= 2))`; `(:kind map)` ⊒
  `(:kind record)` if records are maps — the value model decides).
- **Exhaustiveness** of a clause list = the disjunction of their normal forms
  covers `true` over the kind lattice; decidable because the lattice is
  finite (there are ~10 kinds) and lengths are bounded by the max literal
  arity seen.
- **Guards** (`:test`) are opaque *except* when they are in the
  `system.smt` translatable fragment — then they become SMT constraints and
  `z3` decides subsumption/exhaustiveness for them too. That is the same
  split `system.smt` already makes: translatable ⇒ proven; else ⇒ trusted.

This is first-order pattern matching over a finite constructor set plus
decidable guards — the textbook (Maranget's *"Warnings for pattern matching"*,
2007) applies directly, and its usefulness/exhaustiveness algorithm is what
`self.match` (capsule 12) implements over these constraints.

## Where it lives

| piece | file | extends |
|---|---|---|
| `pattern/parse` · `pattern/bind` · `pattern/vec` · … | `priv/boot/pattern.bl` (new; boot tier — the compiler requires it) | the reading half of `destructure-*` in `compiler.bl` |
| `pattern/match` (the interpreter, the spec) | same file | new |
| `pattern/normalize` · `pattern/subsumes?` | `priv/std/pattern-nf.bl` (std tier; not needed to compile, needed to prove) | new |
| `typed` reads `:bind` ids for local shapes | `priv/std/typed.bl` | today it re-walks reader nodes |
| `codebase` emits `(binds …)` facts | `priv/std/codebase.bl` | today locals are not facts |

The compiler change is one seam: `destructure-steps` takes a pattern value
and returns steps; everything that called it with a node now calls
`(pattern/parse node)` first. Same steps out, so the differential oracle
(`priv/self/oracle.bl`, 932/932) is the gate — the pattern value is
invisible until capsule 10 starts lowering it differently.
