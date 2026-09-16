# Exact decimals — the number an accountant writes

> This is a **literate program**. Every `beam-lisp` block below runs:
> `bl run docs/exact-decimals.bl.md`. The prose is the narrative; the code is
> the proof.

A binary float cannot hold one tenth. `0.1` is really
`0.1000000000000000055511151231257827…`, and three of them added together are
not `0.3`. Nobody wants that in a ledger, which is why Clojure has `123.45M`
— an arbitrary-precision decimal literal — and why the JVM's accounting code
is written against `java.math.BigDecimal`. beam-lisp reads the same literal,
and every core operator understands the value it produces.

```beam-lisp
(ns guide.decimals
  (:require [decimal :as d]))

(println "float:  " (+ 0.1 0.2))
(println "decimal:" (+ 0.1M 0.2M))
```

## What a decimal is

A decimal is an unbounded integer of digits and a *scale* — how many of those
digits sit after the point. `123.45M` is `12345` at scale 2. This is exactly
`BigDecimal`'s model, and it was chosen because **the scale is information**:
`1.50M` says cents, `1.5M` does not, and an arithmetic that silently dropped
the difference would be rounding money without telling you.

```beam-lisp
(println (d/unscaled 123.45M) (d/scale 123.45M) (d/precision 123.45M))
(println (pr-str 1.50M) (pr-str 1.5M) (pr-str (d/strip-zeros 1.500M)))
```

Exact operations keep the scale honest: a sum takes the larger scale, a
product adds the scales.

```beam-lisp
(println (+ 19.99M 0.01M) (- 100M 0.05M) (* 1.5M 1.5M) (* 3 4.50M))
```

## Two equalities, on purpose

`=` is structural: `1.5M` and `1.50M` are different *values*, exactly as
`equals` says on the JVM. `==`, `compare`, `<` and their family are *numeric*:
the two are the same *number*. Sorting, `max`, `min` and `sort-by` all go
through the numeric side, so a mixed column of integers and decimals orders
correctly.

```beam-lisp
(println "=  " (= 1.5M 1.50M) "  == " (== 1.5M 1.50M))
(println (sort [3M 1.5M 2 0.25M]) (max 1M 2.5M 2) (compare 2.50M 2.5M))
```

## Integers promote; floats are refused

An integer beside a decimal lifts to a decimal at scale 0 — exact, no
question. A float beside a decimal is **refused**, because the float is not
the number that was written and laundering it into exact arithmetic is the
bug this type exists to prevent. When an approximation is what you mean, ask
for it by name.

```beam-lisp
(println (+ 1M 2) (* 2.5M 4) (< 1 1.5M 2))
(println (try (+ 1M 0.1) (catch e (:type (ex-data e)))))
(println (d/from-float 0.1) (d/from-float 2.5))
```

## Rounding is a decision, so it is an argument

Nothing rounds silently. `rescale` and `div` take a scale and a mode; there
is no ambient precision or rounding context anywhere in the language, so the
result of an operation is a function of its arguments and nothing else. The
modes are the seven Clojure code spells as `RoundingMode/…`, as keywords —
`:half-even` (banker's, the accounting default), `:half-up`, `:half-down`,
`:ceiling`, `:floor`, `:down`, `:up` — plus `:unnecessary`, which raises
rather than lose a digit.

```beam-lisp
(println (d/round 2.345M) (d/round 2.355M))                 ; banker's: to the even neighbour
(println (d/round 2.345M 2 :half-up) (d/round 2.345M 2 :down))
(println (d/rescale 7M 2) (d/rescale 1.239M 2 :floor) (d/rescale -1.239M 2 :floor))
(println (try (d/rescale 1.239M 2) (catch e (:type (ex-data e)))))  ; :unnecessary by default
```

## Division

`/` on decimals is *exact* division. `1 ÷ 8` terminates, so it has an
answer; `1 ÷ 3` does not, so it is refused — the JVM's `ArithmeticException`,
here `:decimal/non-terminating`. A rounded quotient is spelled with its scale
and mode, which is the only honest way to write one.

```beam-lisp
(println (/ 1M 8M) (/ 10M 4M) (d/div 10M 3M 2 :half-even) (d/div 2M 3M 4 :floor))
(println (try (/ 1M 3M) (catch e (:type (ex-data e)))))
```

## A worked example: splitting a bill exactly

Divide 100 three ways and the naive answer, 33.33 each, loses a cent.
Largest-remainder apportionment gives the cent to the first parts until the
sum is exact. Every step below is a decision you can read.

```beam-lisp
(defn split-evenly
  "Split `amount` into `n` parts at two places whose sum is exactly `amount`."
  [amount n]
  (let [base (d/div amount n 2 :down)                  ; floor each share
        remainder (- amount (* base n))                ; what the floors left over
        cents (d/->long (d/move-point-right remainder 2))]
    (mapv (fn [i] (if (< i cents) (+ base 0.01M) base)) (range n))))

(let [parts (split-evenly 100M 3)]
  (println parts "→ sum" (reduce + 0M parts)))
(let [parts (split-evenly 1M 7)]
  (println parts "→ sum" (reduce + 0M parts)))
```

## Display and escape hatches

`plain-str` prints the number with exactly its scale and never an exponent.
`->double` and `->long` exist for sort keys, plots and indices — lossy by
definition, and named so.

```beam-lisp
(println (d/plain-str 1234.50M) (d/plain-str 0.050M) (d/->double 0.1M) (d/->long -3.99M))
(println (d/move-point-left 1M 2) (d/move-point-right 0.05M 3) (d/abs -2.5M) (d/signum -2.5M))
```

## Why not the `Decimal` library already in `deps/`?

Because it carries a process-global context (precision + rounding mode) that
every operation consults, so a result depends on ambient state set somewhere
else — the exact wart a port from the JVM must not inherit. The type above is
three hundred lines, has no global anywhere, and is checked against
`java.math.BigDecimal` row by row: `test/beam_lisp/decimal_oracle_test.exs`
pins 1051 JVM-captured answers (every rounding mode, every half-way case,
terminating and non-terminating division).
