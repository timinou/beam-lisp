# How a state field picks its z3 theory

A verified process has state. Each field of that state has a **type**, and its
type decides which z3 **theory** proves things about it. This is the whole wiring
between the type system and the prover, and it is one function.

## The idea in one line

> A field's tag-lattice tag *is* its z3 sort.

The type system tags every value: `42` is `:int`, `0.05` is `:float`, `true` is
`:bool`, `"hi"` is `:string`. The prover has a matching world for each — a
theory. The checker reads the tag and picks the theory:

```
:int    → Int        (whole-number arithmetic)
:float  → Real       (real-number arithmetic)
:bool   → Bool       (true/false logic)
:string → String     (text: length, prefix, containment, concatenation)
```

That mapping is a plain lookup (`system.smt/sort-of-value`). Nothing else about a
field's theory is decided anywhere.

## Why the type is enough

z3 talks in SMT-LIB text and answers `sat` / `unsat`. It has always understood
every theory at once; the only question is which sort to *declare* a variable
with. The type already answers that. So the same `verify-process` proves a
whole-number counter, a real-valued rate, a boolean latch, and a text log — with
no per-theory branch. The field's tag chooses; the machinery is uniform.

```clojure
(defserver ^{:invariant (>= rate 0.0)} rated
  (init [] (ok {:rate 0.05}))                    ; 0.05 is :float → rate : Real
  (handle-call [:bump amt] [_ {:keys [rate]}] :when (>= amt 0.0)
    (reply :ok {:rate (+ rate amt)})))           ; proven over the reals
```

`rate` starts at `0.05`, so it is a `Real` and the proof runs over real
arithmetic.

## Inputs inherit the sort they flow into

A message carries values whose type isn't written down — `amt` above. Its sort
is fixed by **where it flows**: `amt` is added into `rate`, and the prover will
not add a whole number to a real, so `amt` must be a `Real` too. An input takes
the sort of the field its next-state expression feeds; an input that touches no
field defaults to `Int`. This keeps the common integer case free and lifts a
real or textual argument to its field's theory automatically.

## Text is content, not size

A collection can be reasoned about by its length alone — "at most ten items."
Text goes further: the String theory reasons about the actual characters.

```clojure
(defserver ^{:invariant (str-prefix? "evt:" last)} auditlog
  (init [] (ok {:last "evt:init"}))
  (handle-cast [:append body] [_ {:keys [last]}]
    (noreply {:last (str "evt:" body)})))
```

`(str-prefix? "evt:" last)` becomes z3's `(str.prefixof "evt:" last)`;
`(str a b)` becomes `(str.++ a b)`; `(str-len s)` becomes `(str.len s)`. The
invariant is proven on the real text, not an approximation of it.

## Reachable is not the same as decidable

Some theories can answer "unknown." Real-number and string questions have
fragments where no procedure is guaranteed to terminate, and z3 is allowed to
give up. A field's type makes its theory *reachable*; it does not make every
question in that theory *decidable*. When the prover returns unknown, the result
is filed as an **approximate** guarantee — never as a proof. A proof is only ever
a definite `unsat` of the negation.

## Where it lives

- `system.smt/sort-of-value` — the tag → sort lookup.
- `system.smt/translate` — emits the theory operations (real literals, the
  `str.*` family) alongside the arithmetic that passes straight through.
- `system.core` — reads each field's sort from the init state and infers each
  input's sort by flow.

The reader nodes the checker consumes must come from reading source, because a
proof reports `file:line:col` and needs the position each node carries. A quoted
form has no position, so source strings — not quoted forms — are what the checker
reads.
