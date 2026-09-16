# Running an unmodified Clojure library on the BEAM

> This is a **literate program**. Every `beam-lisp` block below runs:
> `bl run docs/running-clojure-libraries.bl.md`. The prose is the narrative;
> the code is the proof. It loads a real `.cljc` file — written for the JVM
> and ClojureScript, never for this language — and checks its answers against
> what the JVM printed for the same expressions.

The library is `examples/clojure-compat/ledger/src/acme/money.cljc`. Open it:
it has everything that used to stop a Clojure file at the door — an
`:import` of `java.math`, `#?(:clj …)` reader conditionals, `.add`/`.setScale`
method calls, `BigDecimal/valueOf` statics, `RoundingMode/HALF_EVEN`
constants, `0.01M` literals, `^BigDecimal` type hints, `defonce`, a
`(catch Exception …)`. None of it was edited.

```beam-lisp
(ns guide.clojure-libs
  (:require [acme.money :as m]))
```

That `:require` found `acme/money.cljc` on the search path (this file's own
directory tree is on it when run from the repository root; `-p DIR` adds
another). It read the file as Clojure source, took the `:clj` branch of every
`#?`, and compiled the rest through the same compiler every `.bl` file uses.

## The four doors, and where they lead

A JVM has classes; this runtime has values and functions. The bridge is a
**closed manifest** (`priv/lib/java/manifest.bl`): a table from Java's
spelling to beam-lisp's own. It is consulted at compile time, and it folds
the answer in — compiled code carries no trace of the Java name.

```beam-lisp
;; `.add` on BigDecimal → decimal/add. `BigDecimal/valueOf` → decimal/of.
(println (m/->str (m/add (m/money "10.10" :eur) (m/money 5 :eur))))

;; `.setScale x 2 RoundingMode/HALF_EVEN` → (decimal/rescale x 2 :half-even):
;; the constant became a keyword before the program ran.
(println (m/->str (m/round (m/money "2.345" :eur))))
```

What the manifest does *not* list is a compile-time error, not a runtime
surprise — with the list of what exists in the message:

```beam-lisp
(println
  (try (BeamLisp.Compiler/eval_string "(.frobnicate 1M 2M)")
       (catch e (first (split (ex-message e) (re-pattern "; "))))))
```

## The arithmetic is exact, and it is the JVM's

`allocate` below is the library's own largest-remainder split, written
against `BigDecimal` with `.multiply`, `.divide … RoundingMode/DOWN`,
`.movePointRight`, `.longValue`. Every one of those maps onto
`decimal/…`, whose answers are pinned row-by-row to what
`java.math.BigDecimal` prints (`test/beam_lisp/decimal_oracle_test.exs`,
1051 rows). So the split is cent-exact here for the same reason it is on
the JVM.

```beam-lisp
(println (mapv m/->str (m/allocate (m/money "100" :eur) [1 1 1])))
(println (mapv m/->str (m/allocate (m/money "0.05" :usd) [3 1])))
(println (m/zero? (m/add (m/money "1.5" :eur) (m/money "-1.50" :eur))))
```

The JVM, asked the same three things, printed:

```
["33.34 EUR" "33.33 EUR" "33.33 EUR"]
["0.04 USD" "0.01 USD"]
true
```

## Exceptions cross the bridge too

`(catch Exception e …)` in Clojure is the untyped catch here; the manifest
maps `Exception` and `Throwable` to "anything", `NumberFormatException` and
`ArithmeticException` to the `ex-info` types the decimal raises. So the
library's own error handling — and its refusal of a float, which is the
whole point of an exact money type — works as written.

```beam-lisp
(println (try (m/add (m/money 1 :eur) (m/money 1 :usd)) (catch Exception e (ex-message e))))
(println (try (m/money 1.5 :eur) (catch Exception e (ex-message e))))
```

## What `instance?` and type hints became

`(instance? BigDecimal x)` asks whether `x`'s type *is* `BigDecimal`. The
imported class name resolves, as a value, to the beam-lisp type identity
`(type x)` answers — so the check is the ordinary one. A `^BigDecimal` hint
is advice to a JVM compiler; it is read and dropped.

```beam-lisp
(println (type 1.5M) (instance? (type 1.5M) 1.5M) (instance? (type 1.5M) 1))
```

## Where the seams are

- **The manifest is closed and measured.** It holds what an accounting
  kernel's `:clj` lane actually calls (49 instance methods, 15 classes).
  A new class means a new row, its beam-lisp fn, and a JVM-captured oracle
  row in `test/beam_lisp/java_oracle_test.exs` — no row without an oracle.
- **`java.util.Date` is an integer** of epoch milliseconds — the same value
  the `datom` database stores for `:db.type/instant`, so a library's dates
  and the database's transaction times compare with no adapter.
- **No `java.io`, no threads, no reflection, no zones but UTC.** Those are
  not modelled, and the compiler says so by name.
- **`defonce`, `format`, `hash`, `random-uuid`, `parse-long` …** — the
  `clojure.core` names the prelude lacked live in `clojure.core-more` and
  are installed into `core` before any `.clj`/`.cljc` file loads.
