# The verify loop

*A runnable walkthrough. The cells write a 33-line program under
`tmp/bl-verify-loop/`; the shell blocks show what to type and what comes back.
Run `bl doc run docs/bl/02-the-verify-loop.bl.md` to (re)create the files.*

beam-lisp's compiler does not only check a program — it **proves facts** about
every function: what it returns, whether it is pure, whether it terminates, and
whether it is eligible to run as native code. `bl` puts those facts on three
surfaces: `bl lsp check` reads them, `bl ask` queries the call graph they form,
and `bl check` compares them against a committed baseline so a change cannot
quietly lose one.

This page walks that loop on one small program.

## The program

```beam-lisp
(ns bl.verify-loop)

(do (File/mkdir_p! "tmp/bl-verify-loop/src")
    (File/write! "tmp/bl-verify-loop/src/ledger.bl"
                 "(ns ledger)\n\n(def rate 3)\n\n(defn cents [dollars]\n  (* dollars 100))\n\n(defn fee [amount]\n  (quot (* amount rate) 100))\n\n(defn total [amount]\n  (+ amount (fee amount)))\n\n(defn charged? [amount]\n  (< 0 (fee amount)))\n\n(defn receipt [amount]\n  {:amount amount\n   :fee (fee amount)\n   :total (total amount)})\n\n(defn receipts [amounts]\n  (map receipt amounts))\n\n(defn bill [amounts]\n  (reduce (fn [sum a] (+ sum (total a))) 0 amounts))\n\n(defn largest [amounts]\n  (reduce (fn [m a] (if (> a m) a m)) 0 amounts))\n\n(defn announce [amounts]\n  (println \"billing\" (count amounts) \"amounts\")\n  (bill amounts))\n"))
```

```bl-result cell0
:ok
```

A second file calls into it, and carries one helper nothing calls:

```beam-lisp
(File/write! "tmp/bl-verify-loop/src/audit.bl"
             "(ns audit\n  (:require [ledger]))\n\n(defn report [amounts]\n  (println (ledger/bill amounts)))\n\n(defn unused-helper [x]\n  (+ x 1))\n\n(report [10 20])\n")
```

```bl-result cell1
:ok
```

## Read what the compiler proved

`bl lsp check FILE` prints the diagnostics, then every definition with its
proven summary. Each badge is read straight off the compiler's analysis — none
is a guess.

```sh
$ cd tmp/bl-verify-loop
$ bl lsp check src/ledger.bl
── ledger ──
  diagnostics: none
  symbols (9):
    announce
        → nil|bool|float|fn|int|kw|list|map|seq|set|string|sym|vec  effects  terminates  ·
        calls: bill
    bill
        → nil|bool|float|fn|int|kw|list|map|seq|set|string|sym|vec  pure  terminates  ◆ native
        calls: total
    cents
        → float|int  pure  terminates  ◆ native
    charged?
        → bool  pure  terminates  ◆ native
        calls: fee
    fee
        → …  pure  terminates  ◆ native
    largest
        → …  pure  terminates  ◆ native
    receipt
        → …  pure  terminates  ◆ native
        calls: fee, total
    receipts
        → …  pure  terminates  ◆ native
    total
        → float|int  pure  terminates  ◆ native
        calls: fee
```

Five badges, five theorems:

- **`→ type`** — the return type or type set the analyzer inferred. `cents` and
  `total` return numbers; `charged?` returns `bool`.
- **`pure` / `effects`** — whether the function can read or write the outside
  world. `announce` prints, so it has `effects`; the rest are `pure`.
- **`terminates` / `may-diverge`** — whether every call is proved to finish.
- **`◆ native`** — pure **and** terminating, the two facts that make an offload
  to native code sound. `announce` is not eligible, because it is not pure.
- **`O(…)`** — the growth class of the function's OWN recursion, read off the
  same analysis the termination proof uses. It is printed only for a function
  that calls itself.

## Growth: what a function costs as its input grows

A termination proof answers "does it stop"; the growth badge answers "at what
cost", which is the difference between a loop that finishes and a call that
finishes after lunch. Three shapes are named, and nothing else is claimed:

```sh
$ bl lsp check src/bigo.bl
── bigo.demo ──
  diagnostics: none
  symbols (3):
    fib
        → …  effects  terminates  ·  O(2^n)
        calls: fib
    nested
        → …  effects  terminates  ·  >= O(n^2)
        calls: nested
    walk
        → …  effects  terminates  ·  O(n)
        calls: walk
```

- **`O(n)`** — one self-call, or a loop whose ranking variable moves toward its
  floor. `walk` is here even though it makes TWO recursive calls, because it
  recurs over the two halves of its argument: those subproblems are disjoint,
  so the total work is linear in the tree.
- **`>= O(n^2)`** — nested recursion: a self-call inside the argument of another
  self-call. The inner call redoes work the outer one already paid for.
- **`O(2^n)`** — ≥2 self-calls whose arguments are arithmetic images of the SAME
  parameter (`(- n 1)` and `(- n 2)`, the naive `fib`). The subproblems overlap,
  so without memoisation the work doubles per level.

Two limits are worth stating out loud. The class bounds the function's own
recursion shape — not the cost of the library functions it calls, so a `O(n)`
that calls a quadratic helper still reads `O(n)`. And a non-recursive function
carries no badge at all: there is nothing to bound.

The `calls:` line is the resolved call graph — `bill` calls `total`, which calls
`fee`.

Exit `0` when the file has no diagnostics, `1` when it has some.

## Plan a datalog query before it runs

`bl lint` reads datalog literals in source and flags the one shape whose cost is
invisible until the data grows: a nested `:not` / `:not-join` / `:or` / `:or-join`
sub-query re-runs for every row the outer query produces. If a clause inside it
reads an attribute column without an index, the whole column is read again per
row.

`datom/explain` answers the same question at runtime, against the live schema,
with the exact index the planner picked:

```sh
$ bl eval "(datom/explain-str '[:find ?n :where [?d :fn/name ?n] [:not-join [?n] [?d2 :fn/name ?n]]] nil)"
plan:
  [?d :fn/name ?n]   index=[:aevt [:fn/name]]  cost=4  bound=#{}
  [:not-join [?n] [?d2 :fn/name ?n]]   index=[:eavt [:not-join [?n]]]  cost=0  bound=#{?d ?n}
smells:
  [?d2 :fn/name ?n]  →  [:aevt [:fn/name]]
      The planner reads the whole :fn/name column and re-runs this clause for
      every outer row. Two remedies: (1) make the attribute AVET-indexed —
      `:db/index true` (or `:db/unique`) — so the pattern prefix-scans;
      (2) build the sub-query's answer ONCE outside the outer loop (a set, a
      `memo`, or an `index!` step) and join against it. When no schema is at
      hand, `datom/explain` against the live connection shows the exact plan.
verdict: 1 per-row rescan
```

Pass the live db (`(datom/db conn)`) instead of `nil` and the plan is exact: an
attribute that IS indexed resolves to `[:avet …]` and the smell disappears.
`docs/datom-query-plans.md` has the whole story.

## Ask the call graph

Facts about the functions form a database; `bl ask` queries it. The questions
are named, so you ask in words, not datalog.

```sh
$ bl ask callers fee src
callers fee
charged?	15
receipt	19
total	12
$ bl ask impact fee src
impact fee
announce
bill
charged?
receipt
total
$ bl ask reachable bill src
reachable bill
*
+
fee
quot
reduce
total
```

`callers` is one hop; `impact` is the transitive blast radius — every function
that breaks if `fee` changes. `reachable` is the other direction: everything
`bill` calls, including the core functions `*`, `+`, `quot` and `reduce`.

The type question asks by tag:

```sh
$ bl ask returns-type map src
returns-type map
receipt	inferred
```

`receipt` returns a map, so a question about map-returning functions finds it.

The remaining questions scan for problems:

```sh
$ bl ask arity-mismatches src
arity-mismatches
no results
$ bl ask unknown-callees src
unknown-callees
no results
$ bl ask dead-code src/audit.bl
dead-code
src/audit.bl	unused-helper
```

`unused-helper` is unreachable from `audit.bl`'s own top-level code, which calls
`report` and nothing else — so it is dead. A library with no top-level call at
all treats every definition as an entry point, so it reports nothing dead.

`bl ask symbols` is the same per-function summary `bl lsp check` renders, as
rows:

```sh
$ bl ask symbols src
symbols
src/audit.bl	report	…	no	yes
src/audit.bl	unused-helper	float|int	yes	yes
src/ledger.bl	announce	…	no	yes
…
```

Rows are tab-separated: path, name, returns, pure, terminates.

Every valid question exits `0`, even one with no rows. A bad invocation exits
`2`.

## Set a baseline, catch a regression

`bl check` measures every source and compares it to `.bl-check.edn`. It also
records the **names** of the pure, terminating and native-eligible functions, so
a lost proof names the function that lost it. The first run has no baseline and
is a measurement:

```sh
$ bl check
src/audit.bl  diags=0 smells=1 fns=2 pure=1 eligible=1
src/ledger.bl  diags=0 smells=0 fns=9 pure=8 eligible=8
no baseline: run bl check --update to create .bl-check.edn
ok
$ bl check --update
wrote .bl-check.edn (2 files)
```

Now make `fee` write to stdout and give it a smell:

```beam-lisp
(File/write! "tmp/bl-verify-loop/src/ledger.bl"
             "(ns ledger)\n\n(def rate 3)\n\n(defn cents [dollars]\n  (* dollars 100))\n\n(defn fee [amount]\n  (println \"fee\")\n  (if (not (= amount 0)) (quot (* amount rate) 100) 0))\n\n(defn total [amount]\n  (+ amount (fee amount)))\n\n(defn charged? [amount]\n  (< 0 (fee amount)))\n\n(defn receipt [amount]\n  {:amount amount\n   :fee (fee amount)\n   :total (total amount)})\n\n(defn receipts [amounts]\n  (map receipt amounts))\n\n(defn bill [amounts]\n  (reduce (fn [sum a] (+ sum (total a))) 0 amounts))\n\n(defn largest [amounts]\n  (reduce (fn [m a] (if (> a m) a m)) 0 amounts))\n\n(defn announce [amounts]\n  (println \"billing\" (count amounts) \"amounts\")\n  (bill amounts))\n")
```

```bl-result cell2
:ok
```

`fee` is impure, and purity flows through the callers: `total`,
`charged?` and `receipt` each lose their proof too.

```sh
$ bl check
src/audit.bl  diags=0 smells=1 fns=2 pure=1 eligible=1
src/ledger.bl  diags=0 smells=3 fns=9 pure=4 eligible=4
✗ smells 0 → 3 (src/ledger.bl)
✗ pure lost: charged?, fee, receipt, total (src/ledger.bl)
✗ eligible lost: charged?, fee, receipt, total (src/ledger.bl)
✗ 3 regression(s)
```

Exit `1` when anything regressed, `0` when nothing did.

`--changed` selects only the sources whose content moved — here, the one file
that changed:

```sh
$ bl check --changed
src/ledger.bl  diags=0 smells=3 fns=9 pure=4 eligible=4
✗ smells 0 → 3 (src/ledger.bl)
✗ pure lost: charged?, fee, receipt, total (src/ledger.bl)
✗ eligible lost: charged?, fee, receipt, total (src/ledger.bl)
✗ 3 regression(s)
```

`--fix` applies the safe rewrites before measuring. It removes the mechanical
smells — three down to one — but it cannot restore a lost proof: making `fee`
pure again is a code change, not a rewrite.

```sh
$ bl check --fix
src/audit.bl  diags=0 smells=1 fns=2 pure=1 eligible=1
src/ledger.bl  diags=0 smells=1 fns=9 pure=4 eligible=4
✗ smells 0 → 1 (src/ledger.bl)
✗ pure lost: charged?, fee, receipt, total (src/ledger.bl)
✗ eligible lost: charged?, fee, receipt, total (src/ledger.bl)
✗ 3 regression(s)
```

## Compose it in CI and the hook

The loop is a sequence of commands, so it drops into CI and into a git hook:

```sh
bl test                  # the tests pass
bl check --changed       # no proof regressed, no new smell
bl examples              # every example still runs
bl doc run $(find docs -name '*.bl.md' -o -name '*.bl.org')   # docs still run
```

`bl check --changed` is exactly what `bl check --install-hook` writes into
`.git/hooks/pre-commit`, so the same gate runs locally before a commit:

```sh
#!/bin/sh
exec bl check --changed
```

See [00-the-cli.md](00-the-cli.md#the-baseline-and-the-pre-commit-hook) for the
baseline file, and [03-the-live-loop.md](03-the-live-loop.md) for `bl doc`.
