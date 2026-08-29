# Sum types are shapes

A process field can be a **sum type** — it holds one of several tagged
alternatives. The checker reads the alternatives from the values in the code and
proves the invariant over a z3 algebraic datatype. There is no type declaration
and no reserved key; the tag is structural.

## How a variant is written

```clojure
:paused        ; a NULLARY arm — the tag is the keyword
{:on 7}        ; a PAYLOAD arm — the single key is the tag, its value the data
{:on {:x 3}}   ; the payload is itself a shape — nesting is ordinary
```

A field that holds any of these across its transitions is a sum type. When every
arm is nullary (`:idle | :open | :closed`) it is an enum — the same mechanism,
degenerate.

## Sum versus product

The field's **shape across its universe** decides which it is:

| the field holds | it is |
|---|---|
| bare keywords only | a sum (an enum) |
| keywords and/or single-key maps | a sum with payloads |
| one multi-key map everywhere | a product (a record) |

A single-key map that is the only shape a field ever holds is a record; the same
shape appearing alongside `:paused` or another tag is a variant arm. The universe
is gathered from the field's assignments, guards, and the invariant, so the set
of arms is complete.

## Discriminate and access with ordinary map operations

Nothing new to learn — a variant is read the way any map is:

```clojure
(= mode :paused)        ; nullary discriminant
(some? (:on mode))      ; "the :on arm is present" — payload discriminant
(is? (:on mode))        ; the same, read as intent (is? aliases some?)
(:on mode)              ; the payload
```

These already mean the right thing in plain bl: `(:on :paused)` is `nil`, so
`(some? (:on mode))` is a real predicate that runs, and `(:on {:on 7})` is `7`.
An invariant written this way **evaluates as ordinary code and verifies as z3** —
the same text, two readings.

## What z3 sees

```clojure
(defserver ^{:invariant (or (not (some? (:on mode))) (>= (:on mode) 0))} dial
  (init [] (ok {:mode :paused}))
  (handle-call [:turn-on lvl] [_ {:keys [mode]}] :when (>= lvl 0)
    (reply :ok {:mode {:on lvl}}))
  (handle-call [:pause] [_ {:keys [mode]}]
    (reply :ok {:mode :paused})))
```

becomes

```smtlib
(declare-datatypes () ((E_mode E_mode-paused (E_mode-on (E_mode-on.val Int)))))
;; (some? (:on mode)) → ((_ is E_mode-on) mode)
;; (:on mode)         → (E_mode-on.val mode)
;; {:on lvl}          → (E_mode-on lvl)
;; :paused            → E_mode-paused
```

Constructors are prefixed with the sort name so two variant fields never clash.
z3's no-junk axiom fences the field to exactly its arms — a value outside the
declared set cannot exist, so there is no stray tag to reason away.

## Where it lives

- `system.smt/variants-map`, `datatype-decl` — build the datatype from the arm
  set `{tag → payload-sort | nil}`.
- `system.smt/translate` — a keyword is a constructor, a single-key map is a
  constructor call, `(:tag x)` is the accessor, `(some? (:tag x))` the
  discriminant.
- `system.core` — reads each field's arms from the code and threads the datatype
  into the proof.
