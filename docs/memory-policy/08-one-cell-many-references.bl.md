# One cell behind delay, atom, and derived

A lazy sequence, a delay, an atom, and a derived value look like four different
things. Underneath, they are one thing: a small cell that holds a value, can be
read, and can be swapped atomically. Everything else is a thin layer of meaning
on top of that one cell.

This is worth seeing directly, because it explains why these features behave
consistently, share their performance, and compose.

You do not need Rust or the BEAM internals. The ideas are ordinary.

## Run the examples

Literate Beam Lisp. `beam-lisp` blocks run top to bottom:

```sh
mix run -e '"docs/memory-policy/08-one-cell-many-references.bl.md" |> BeamLisp.Loader.read_source() |> BeamLisp.eval()'
```

```beam-lisp
(ns tutorial.one-cell)

(defn check [label expected actual]
  (if (= expected actual)
    (println label "ok")
    (throw (ex-info (str "Check failed: " label)
                    {:expected expected :actual actual}))))
```

```bl-result check
&:"Elixir.BeamLisp.Ns.Tutorial.One-cell".check/3
```

## 1. delay: run once, remember

A `delay` wraps work that has not happened yet. `force` (or `@`) makes it
happen, once; every later force returns the remembered answer.

```beam-lisp
(let [runs (atom 0)
      d (delay (do (swap! runs inc) (* 6 7)))]
  (check "not run until forced" 0 @runs)
  (check "first force" 42 (force d))
  (check "second force" 42 @d)
  (check "body ran once" 1 @runs))
```

```bl-result cell1
not run until forced ok
first force ok
second force ok
body ran once ok
:ok
```

A delay is not a sequence. Its value comes back exactly as produced — a vector
stays a vector, not a stream of elements:

```beam-lisp
(check "value returned as-is" [1 2 3] (force (delay [1 2 3])))
```

```bl-result cell1b
value returned as-is ok
:ok
```

## 2. atom: a value you can swap

An `atom` holds a value you can read with `@` and change with `swap!`. It is
the same kind of cell as the delay — a box holding one value — but its value is
meant to change over time, not to be computed once.

```beam-lisp
(let [a (atom {:count 0})]
  (check "read" 0 (:count @a))
  (swap! a update :count inc)
  (check "after swap" 1 (:count @a))
  (reset! a {:count 99})
  (check "after reset" 99 (:count @a)))
```

```bl-result cell2
read ok
after swap ok
after reset ok
:ok
```

Because an atom is a value behind a reference and not a running process, it
lives as long as something holds it — it does not vanish when the code that
created it returns. It may also hold a reference to another atom, even
cyclically; it is ordinary data.

```beam-lisp
(let [a (atom nil)
      b (atom nil)]
  (reset! a b)
  (reset! b a)
  (check "a points at b" b @a)
  (check "b points at a" a @b))
```

```bl-result cell2b
a points at b ok
b points at a ok
:ok
```

## 3. Watch a change without asking

Add a watch to an atom and a function runs on every change, told the key, the
reference, the old value, and the new. This is how a change can drive something
else — a UI, a log — without the writer knowing.

```beam-lisp
(let [a (atom 0)
      seen (atom [])]
  (add-watch a :log (fn [_k _ref old new] (swap! seen conj [old new])))
  (swap! a inc)
  (swap! a inc)
  (check "watch saw each change" [[0 1] [1 2]] (vec @seen)))
```

```bl-result cell3
watch saw each change ok
:ok
```

## 4. derived: a value that follows other values

A `derived` is computed from other references and recomputes only when one of
them actually changed. Reading it is cheap when nothing moved; a change is
picked up on the next read.

```beam-lisp
(let [celsius (atom 0)
      runs (atom 0)
      fahrenheit (derived [celsius]
                   (do (swap! runs inc) (+ 32 (* celsius 1.8))))]
  (check "initial" 32.0 @fahrenheit)
  (check "cached" 32.0 @fahrenheit)
  (check "computed once" 1 @runs)
  (reset! celsius 100)
  (check "recomputed" 212.0 @fahrenheit)
  (check "computed twice" 2 @runs))
```

```bl-result cell4
initial ok
cached ok
computed once ok
recomputed ok
computed twice ok
:ok
```

The value `9/5` is written `1.8` here; a temperature comes back as a float
(`32.0`), which is why the checks compare against floats.

Deriveds chain. A derived built on another derived becomes stale, and
recomputes, exactly when the value beneath it does — the staleness flows on
demand, when you read.

```beam-lisp
(let [n (atom 1)
      doubled (derived [n] (* 2 n))
      labelled (derived [doubled] (str "value=" doubled))]
  (check "chain initial" "value=2" @labelled)
  (reset! n 5)
  (check "chain follows" "value=10" @labelled))
```

```bl-result cell5
chain initial ok
chain follows ok
:ok
```

## 5. memoize: one delay per argument

`memoize` remembers a function's result for each argument list. It is delays
and an atom composed: a shared atom maps each argument list to a delay, and
forcing that delay runs the function once for that key.

```beam-lisp
(let [runs (atom 0)
      slow (memoize (fn [x] (swap! runs inc) (* x x)))]
  (check "first 5" 25 (slow 5))
  (check "cached 5" 25 (slow 5))
  (check "first 6" 36 (slow 6))
  (check "one run per key" 2 @runs))
```

```bl-result cell6
first 5 ok
cached 5 ok
first 6 ok
one run per key ok
:ok
```

## Why they behave alike

Every one of these — `delay`, `atom`, `derived`, `memoize`, and the `lazy-seq`
from the earlier tutorial — is a thin layer over the same native cell. That is
not an implementation trivia; it is why they share their properties:

- **One read, one write, atomically.** `@` is a cell read; `swap!` and `force`
  are compare-and-set on a cell. The atomic swap is what makes concurrent
  callers safe without locks in your code.
- **Compute once, share the answer.** A delay forced by many processes runs its
  body once. A `memoize` under a stampede of identical calls runs the function
  once. Both inherit this from the cell's "one process computes, the rest wait
  for the answer" rule.
- **Ownership follows references.** A cell lives while something holds it and is
  reclaimed when the last holder lets go. An atom that escapes its creator
  keeps working; a delay captured in a closure stays forceable.
- **The same speed budget.** A cell read is about 150 nanoseconds and a swap
  about 750. Because a derived read, a memoize hit, and an atom deref are all
  cell reads underneath, they are all in that budget — a signal graph of
  deriveds is practical for the same reason a plain atom is fast.

## What stays true

- **`delay` runs its body at most once**, returns the value as produced, and
  `@` forces it.
- **`atom` is eager, mutable, shareable, and may hold cycles.** It outlives its
  creator. `swap!`/`reset!`/`compare-and-set!`/`add-watch` are its verbs.
- **`derived` is pull-based.** Changing a dependency costs nothing; the
  recompute happens on the next read, and only if a dependency's value actually
  changed. No push, so no ordering surprises to reason about.
- **`memoize` is delays in an atom.** One run per argument key; a throwing call
  is retryable, not a poisoned key.

## Keep exploring

- `priv/boot/core.bl` — the `delay`, `derived`, and `memoize` definitions, and
  the `lazy-seq` macro they are cousins to.
- `lib/beam_lisp/deferred.ex` — delay/force/realized? over the cell.
- `lib/beam_lisp/refs.ex` — atoms and watches over the cell.
- `lib/beam_lisp/reactive.ex` — derived, pull-based value-diffing.
- `docs/memory-policy/shared-lazy-values.bl.md` — the cell itself, and why
  ownership follows references rather than a global table.
