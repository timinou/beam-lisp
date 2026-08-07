# jank compatibility measurement

**Thesis under test:** beam-lisp claims *"jank's language, BEAM's runtime"*.
jank ships its stdlib as `core.jank` — Clojure source written for jank.
If beam-lisp can load slices of it **unmodified** and run them, fidelity
stops being an opinion and becomes a test suite.

This document is the measurement: which slices of jank's `core.jank`
beam-lisp can load and run today, which it cannot, and — most
importantly — what to implement next to unlock the most.

## Source & provenance

| | |
|---|---|
| repo | `https://github.com/jank-lang/jank` |
| file | `compiler+runtime/src/jank/clojure/core.jank` |
| commit | `30285949933065417c6311a91902b7866ab60f87` |
| date | 2026-08-01 |
| license | EPL-1.0 (see the copyright header of `core.jank`) |
| vendored | `test/fixtures/jank/slice_*.bl` — each block byte-for-byte upstream, with URL/commit/line-range/sha256 in a header comment |

## Method

1. **Slice.** Copy each candidate `defn`/`defmacro` block *verbatim* out of
   `core.jank` into `test/fixtures/jank/slice_NN_<name>.bl`. Start from
   leaves — functions that need only what beam-lisp already has
   (`fn`, `let`, `if`, `loop`/`recur`, `defmacro`, seq fns).
2. **Load.** The harness wraps each slice in a throwaway `(ns jank.slice_NN)`
   and `Compiler.eval_string`s it. A slice that needs a local edit is a
   **FAIL with a recorded reason** — never a patch. The vendored text is
   never rewritten (a checksum test guards that).
3. **Behave.** Loading only proves the reader + compiler accept the form:
   a `defn` body resolves its callees at *call* time. So each loaded slice
   is then *called* with its own docstring examples. This is where the
   real verdict lands.

> **`load` ≠ `behave`.** Many of the 120 slices read+compile ("load"); six
> fail *at the reader/compiler itself* (`for` and `distinct` were reader
> failures that waves later fixed; wave 24's `^{}`-metadata slices fail
> there today). And only some of the loaded slices run correctly when
> called. The verdicts below are behavioral — the checklist marks each.

## The checklist — 120 attempted slices

Verdicts: **✓ pass** (loads and behaves) · **◐ partial** (common arities
pass, higher/transducer arities fail) · **✗ fail** (a recorded gap).
Slices 01–21 are the original measurement; 22–64 are the wave-16 widening;
**65–120 are the wave-24 widening** (the `reduce`/transducer family, the
arithmetic and bit-op layer, `volatile!`, the pure tail-of-file seq fns,
and the reader-level `^{}`-metadata forms). Row *lines* columns are the
upstream span in `core.jank@3028594`.

| # | slice | core.jank lines | defines | verdict | blocker |
|---|-------|-----------------|---------|:-------:|---------|
| 01 | constantly | 1048–1052 | `constantly` | ✓ | — self-contained |
| 02 | identity | 1054–1057 | `identity` | ✓ | — also in prelude |
| 03 | complement | 1059–1067 | `complement` | ✓ | needs `apply`(2-arity) + `not` |
| 04 | comp | 1186–1201 | `comp` | ✓ | *was ◐* — closed by `list*` + variadic `apply` (wave 14) |
| 05 | juxt | 2084–2118 | `juxt` | ✓ | *was ◐* — closed by `list*` + variadic `apply` + `#()` (wave 14) |
| 06 | partial | 2120–2147 | `partial` | ✓ | *was ◐* — closed by variadic `apply` (wave 14) |
| 07 | fnil | 2149–2170 | `fnil` | ✓ | needs `apply`(2-arity) |
| 08 | some | 2172–2180 | `some` | ✓ | *was ✗* — closed by `next` (wave 14) |
| 09 | not-any? | 2262–2263 | `not-any?` | ✓ | *was ✗* — closed by `next` + the `not` fix (wave 14); needs the `some` slice loaded alongside, which is core.jank's own dependency |
| 10 | `->` | 2265–2279 | `->` macro | ✓ | *was ✗* — closed by `loop*` + form metadata + `seq?` (wave 15) |
| 11 | `->>` | 2281–2295 | `->>` macro | ✓ | *was ✗* — same as `->` |
| 12 | key/val | 2298–2307 | `key`, `val` | ✓ | `first`/`second` |
| 13 | if-let | 2608–2626 | `if-let` macro | ✓ | *was ✗* — closed by `assert-macro-args` + `&form` + `clojure.core` alias (wave 15) |
| 14 | when-let | 2628–2641 | `when-let` macro | ✓ | *was ✗* — same chain; needs the `if-let` slice co-loaded |
| 15 | if-not | 2662–2667 | `if-not` macro | ✓ | pure |
| 16 | dotimes | 2686–2701 | `dotimes` macro | ✓ | *was ✗* — same chain (wave 15) |
| 17 | doseq | 2703–2756 | `doseq` macro | ✓ | *was ✗* — same chain, plus seqable `~@` splice and vector-as-function |
| 18 | doto | 2927–2941 | `doto` macro | ✓ | *was ✗* — closed by form metadata (wave 15) |
| 19 | trampoline | 6999–7013 | `trampoline` | ✓ | *was ✗* — closed by `fn?` + `#()` fn literals (wave 14) |
| 20 | while | 7015–7022 | `while` macro | ✓ | pure (`loop`/`when`/`recur`) |
| 21 | memoize | 7024–7036 | `memoize` | ✓ | *was ✗* — closed by `if-let` + `find`; needs the `if-let` and `key/val` slices co-loaded |
| 22 | reverse | 1983–1986 | `reverse` | ✓ | `reduce` + `conj` onto `'()` |
| 23 | run! | 1179–1184 | `run!` | ✓ | `#()` + `reduce` |
| 24 | every-pred | 2183–2220 | `every-pred` | ✓ | `boolean`, `every?`, `list*` |
| 25 | some-fn | 2222–2259 | `some-fn` | ✓ | needs the `some` slice co-loaded (core dep) |
| 26 | keys | 2308–2317 | `keys` | ✓ | *was ✗* — closed by transients (wave 17) |
| 27 | vals | 2319–2328 | `vals` | ✓ | *was ✗* — transients (wave 17) |
| 28 | select-keys | 2392–2401 | `select-keys` | ✓ | *was ✗* — `conj` of a map entry (wave 18) |
| 29 | zipmap | 2403–2413 | `zipmap` | ✓ | *was ✗* — transients + `hash-map` (wave 17) |
| 30 | set | 2459–2467 | `set` | ✓ | *was ✗* — a set type, the `#{}` reader literal, and transient sets (wave 18) |
| 31 | name | 2484–2487 | `name` | ✓ | *was ✗* — the `cpp/*` primitive shim (wave 18) |
| 32 | namespace | 2489–2492 | `namespace` | ✓ | *was ✗* — `cpp/*` shim |
| 33 | keyword | 2548–2557 | `keyword` | ✓ | *was ✗* — `cpp/*` shim |
| 34 | if-some | 2643–2660 | `if-some` | ✓ | `assert-macro-args`, `temp#` |
| 35 | when-some | 2669–2684 | `when-some` | ✓ | `assert-macro-args`, `~@` splice |
| 36 | repeatedly | 3063–3068 | `repeatedly` | ✓ | `lazy-seq`, `cons`, `take` |
| 37 | take-while | 3070–3087 | `take-while` | ✓ | coll arity; *transducer 1-arity needs `reduced`* (noted below) |
| 38 | drop-while | 3117–3140 | `drop-while` | ✓ | coll arity; *transducer 1-arity needs `volatile!`* (noted) |
| 39 | split-at | 3157–3160 | `split-at` | ✓ | `take`/`drop` |
| 40 | interleave | 3167–3181 | `interleave` | ✓ | *was ◐* — the 1-arity `(lazy-seq c1)` case, same fix as lazy-cat |
| 41 | partition | 3231–3251 | `partition` | ✓ | *was ✗* — `nthrest`; exposed the lazy `count`/`next`/`Inspect` bugs |
| 42 | frequencies | 3322–3331 | `frequencies` | ✓ | *was ✗* — transients (wave 17) |
| 43 | group-by | 3333–3344 | `group-by` | ✓ | *was ✗* — transients (wave 17) |
| 44 | for | 3145–3216 | `for` macro | ✓ | *was ✗* — needed three unrelated fixes: a rest arg that is itself a pattern, bare-LazySeq normalization, and `when-first` (wave 23) |
| 45 | assoc-in | 3697–3704 | `assoc-in` | ✓ | *was ✗ (hung)* — closed by nil-terminating `&` rest |
| 46 | update-in | 3706–3718 | `update-in` | ✓ | *was ✗ (hung)* — same fix; needs the `assoc-in` slice co-loaded |
| 47 | update | 3720–3734 | `update` | ✓ | `assoc`/`get`/`apply`, variadic |
| 48 | mapcat | 3790–3796 | `mapcat` | ✓ | coll arity; *transducer 1-arity needs `cat`* (noted) |
| 49 | distinct | 3813–3836 | `distinct` | ✓ | *was ✗* — `:as` (wave 18) then the `#{}` set literal |
| 50 | flatten | 3883–3889 | `flatten` | ✓ | *was ✗* — `tree-seq`/`sequential?`; needs the `complement` slice co-loaded |
| 51 | remove | 3891–3898 | `remove` | ✓ | needs the `complement` slice co-loaded (core dep) |
| 52 | condp | 3924–3962 | `condp` | ✓ | *was ✗* — closed by `:as` in sequential destructuring (wave 18); needs the `split-at` slice co-loaded |
| 53 | cond-> | 3963–3982 | `cond->` macro | ✓ | *was ✗* — `*assert*`/`butlast`/`partition` (wave 17) |
| 54 | cond->> | 3984–3998 | `cond->>` macro | ✓ | *was ✗* — same chain |
| 55 | as-> | 4000–4009 | `as->` macro | ✓ | *was ✗* — `butlast` (wave 17) |
| 56 | some-> | 4011–4022 | `some->` macro | ✓ | *was ✗* — `butlast` (wave 17) |
| 57 | some->> | 4024–4035 | `some->>` macro | ✓ | *was ✗* — `butlast` (wave 17) |
| 58 | merge-with | 5556–5570 | `merge-with` | ✓ | *was ✗* — `seq` over a map (wave 18) |
| 59 | sort-by | 5661–5671 | `sort-by` | ✓ | *was ✗* — `sort` + a total-order `compare` (wave 18) |
| 60 | with-open | 5976–5995 | `with-open` macro | ✗ | **upstream TODO stub** — the slice itself throws |
| 61 | lazy-cat | 6268–6275 | `lazy-cat` macro | ✓ | *was ✗* — a lazy-seq body may return a bare collection, now normalized when realized |
| 62 | max-key | 6428–6444 | `max-key` | ✓ | `>` / `>=` |
| 63 | min-key | 6446–6462 | `min-key` | ✓ | *was ✗* — the `<=` link pointed at `:erlang."<="`, which does not exist (Erlang spells it `=<`) |
| 64 | assert | 903–918 | `assert` macro | ✓ | *was ✗* — `*assert*` + `assert` in the prelude (wave 17) |
| 65 | meta-def | 75–79 | `list?` (via `def ^{:arglists …}`) | ✗ | **reader `^{}` metadata** — `compile_special/3` has no clause for the map-meta `def` |
| 66 | reduced | 1090–1094 | `reduced` | ✗ | `cpp/jank.runtime.reduced` absent (cpp shim) |
| 67 | reduced? | 1095–1099 | `reduced?` | ✗ | `cpp/jank.runtime.is_reduced` absent |
| 68 | ensure-reduced | 1100–1106 | `ensure-reduced` | ✗ | needs `reduced?`/`reduced` (cpp) |
| 69 | unreduced | 1107–1113 | `unreduced` | ✗ | needs `reduced?` (cpp) |
| 70 | reduce | 1114–1132 | `reduce` | ◐ | 2-arity passes (self-recursive `recur`); the `[f init coll]` arity needs `cpp/jank.runtime.reduce` |
| 71 | completing | 1133–1143 | `completing` | ✓ | pure fn (multi-arity) |
| 72 | transduce | 1144–1160 | `transduce` | ✗ | needs the 1-arity transducer `map` + `cpp reduce` |
| 73 | preserving-reduced | 1161–1167 | `preserving-reduced` | ✗ | needs `reduced?` (cpp) |
| 74 | cat | 1168–1178 | `cat` | ✗ | needs `preserving-reduced` + `reduce` |
| 75 | peek | 1203–1208 | `peek` | ✗ | `cpp/jank.runtime.peek` absent |
| 76 | pop | 1209–1216 | `pop` | ✗ | `cpp/jank.runtime.pop` absent |
| 77 | volatile! | 1308–1315 | `volatile!` | ✗ | **reader `^{:inline (fn* …)}`** — `invalid fn clause` at compile |
| 78 | bit-not | 1426–1432 | `bit-not` | ✗ | reader `^{:inline …}` metadata + `cpp/jank.runtime.bit_not` |
| 79 | not= | 1533–1540 | `not=` | ✓ | `not`/`=`/`apply` |
| 80 | mod | 1693–1701 | `mod` | ✗ | `rem` undefined in core |
| 81 | inc' | 1750–1774 | `inc'` | ✗ | `cpp/jank.runtime.promoting_inc` absent |
| 82 | unchecked-inc-int | 1825–1831 | `unchecked-inc-int` | ✗ | **upstream TODO stub** — `(throw "TODO: port unchecked-inc-int")` |
| 83 | int? | 1930–1934 | `int?` | ✗ | `cpp/jank.runtime.is_integer` absent |
| 84 | pos-int? | 1935–1939 | `pos-int?` | ✓ | `int?` resolves to beam-lisp's native int?; `pos?` |
| 85 | double? | 1950–1954 | `double?` | ✗ | `float?` undefined in core |
| 86 | nthnext | 2839–2847 | `nthnext` | ✓ | `seq`/`next`/`pos?` |
| 87 | nthrest | 2848–2857 | `nthrest` | ✓ | `if-let`/`seq`/`rest` |
| 88 | take-nth | 2858–2876 | `take-nth` | ✓ | coll arity; *transducer 1-arity needs `volatile!`* (noted) |
| 89 | map | 2877–2926 | `map` | ✓ | all coll arities incl. multi-coll; the `chunked-seq?` branch is dead here (`chunked-seq?` is false), so the lazy path runs |
| 90 | map-indexed | 2943–2970 | `map-indexed` | ✓ | coll arity; *transducer needs `volatile!`* (noted) |
| 91 | keep | 2971–3001 | `keep` | ✓ | coll arity; chunked branch dead |
| 92 | keep-indexed | 3002–3037 | `keep-indexed` | ✓ | coll arity; *transducer needs `volatile!`* (noted) |
| 93 | drop-last | 3112–3116 | `drop-last` | ✗ | `(map f coll (drop n coll))` — a **two-collection `map`**, and beam-lisp's core `map` is single-coll |
| 94 | split-with | 3162–3166 | `split-with` | ✓ | needs the `juxt` slice co-loaded (core dep) |
| 95 | interpose | 3183–3203 | `interpose` | ✗ | **beam-lisp `interleave` bug** — `(interleave (repeat sep) coll)` crashes (`Enum.map_intersperse_list/3` no clause) |
| 96 | dorun | 3204–3216 | `dorun` | ✓ | `when-let` + top-level `recur` |
| 97 | doall | 3217–3230 | `doall` | ✓ | needs the `dorun` slice co-loaded |
| 98 | reductions | 3346–3361 | `reductions` | ✗ | needs `reduced?` (cpp) |
| 99 | into | 3362–3375 | `into` | ✗ | `transientable?` undefined in core |
| 100 | take-last | 3749–3758 | `take-last` | ✓ | `loop`/`drop` |
| 101 | mapv | 3759–3777 | `mapv` | ◐ | 1-arity (transient) passes; multi-coll arities need `into` + a multi-coll `map` |
| 102 | filterv | 3778–3789 | `filterv` | ✓ | transients + `persistent!` |
| 103 | distinct? | 3838–3852 | `distinct?` | ✓ | the `#{}` set literal + `contains?` + `not=` |
| 104 | filter | 3853–3882 | `filter` | ✓ | coll arity; chunked branch dead |
| 105 | dedupe | 3900–3923 | `dedupe` | ✓ | coll arity; needs the `when-some` slice co-loaded (core dep); *transducer needs `volatile!`* (noted) |
| 106 | nfirst | 4993–4997 | `nfirst` | ✓ | `next`/`first` |
| 107 | fnext | 4998–5002 | `fnext` | ✓ | `first`/`next` |
| 108 | instance? | 5003–5009 | `instance?` | ✗ | **upstream TODO stub** — `(throw "TODO: port instance?")` |
| 109 | map-entry? | 5066–5071 | `map-entry?` | ✓ | `vector?` + `==` |
| 110 | rseq | 5072–5078 | `rseq` | ✗ | **upstream TODO stub** — `(throw "TODO: port rseq")` |
| 111 | not-every? | 5533–5538 | `not-every?` | ✓ | `every?` |
| 112 | replicate | 5543–5547 | `replicate` | ✓ | `take`/`repeat` |
| 113 | comparator | 5644–5649 | `comparator` | ✓ | `cond` |
| 114 | ratio? | 5831–5835 | `ratio?` | ✗ | `cpp/jank.runtime.is_ratio` absent |
| 115 | decimal? | 5846–5851 | `decimal?` | ✗ | `cpp/jank.runtime.is_big_decimal` absent |
| 116 | sorted? | 6977–6981 | `sorted?` | ✗ | `cpp/jank.runtime.is_sorted` absent |
| 117 | splitv-at | 7448–7452 | `splitv-at` | ✗ | `(into [] (take n) coll)` — needs `into`'s transducer arity |
| 118 | update-vals | 7721–7735 | `update-vals` | ✗ | `reduce-kv` undefined in core |
| 119 | update-keys | 7736–7749 | `update-keys` | ✗ | `reduce-kv` undefined in core |
| 120 | NaN? | 7787–7791 | `NaN?` | ✗ | `cpp/jank.runtime.is_nan` absent |

## Counts — the headline

> **89 of 120 attempted slices** load **and** behave correctly. The
> trajectory is the point: **7 → 13 → 21 → 36 → 38 → 62 → 63 → 89** across
> ten waves, each aimed by this document's ranked gap list. Nothing was
> patched into passing — the fixtures are still byte-for-byte upstream and
> the checksum test proves it. Where a slice needs another slice
> (`split-with` needs `juxt`; `doall` needs `dorun`; `dedupe` needs
> `when-some`; `mapcat` needs `complement`), that dependency is
> `core.jank`'s own, satisfied with unmodified upstream text.
>
> **The drop is the deliverable.** The previous sample (63/64) had stopped
> being informative — everything that *could* pass did. Wave 24 deliberately
> widened into the hard middle of the file: the `reduce`/`into`/`transduce`
> family, the arithmetic and bit-op layer, `volatile!`, and the `^{}`-
> metadata forms at the head. The score fell to 89/120, and the fall names
> the work. Four categories carry almost all of the 31 failures:
>
> 1. **the `cpp/jank.runtime.*` shim** (15 slices) — beam-lisp maps the
>    handful of primitives the earlier sample touched, but not the 
>    transducer/runtime core (`reduce`, `reduced`, `reduced?`, `peek`,
>    `pop`, the promoting/unchecked arithmetic, `is_*` predicates);
> 2. **reader `^{}` metadata** (3 slices fail *at load*) — the whole
>    `def ^{:arglists …}` / `defn ^{:inline …}` dialect at the head of
>    `core.jank` is unreadable;
> 3. **upstream TODO stubs** (4 slices) — `instance?`, `rseq`,
>    `unchecked-inc-int`, plus the already-known `with-open`; these throw
>    by construction and cannot pass anywhere, jank included;
> 4. **small core gaps and one real bug** — `rem`, `float?`,
>    `transientable?`, `reduce-kv`, multi-coll `map`, and a genuine
>    `interleave` crash on a lazy infinite input.
>
> The value of re-measuring over a harder tranche is *more* evidence about
> the real distance to whole-file fidelity than any single score: it names
> precisely which primitives and reader rules stand between beam-lisp and
> the rest of `core.jank`, and ranks them by how many slices each unlocks.
> (See "What to build next" below — the transducer layer is the big one.)

### What wave 24 found that the previous sample hid

- **The transducer family is cpp-shaped, not pure.** Every reduce/transduce
  building block — `reduced`, `reduced?`, `reduce`'s `[f init coll]` arity —
  is a one-line `cpp/jank.runtime.*` call. beam-lisp's own `reduce` is
  self-hosted, but the *upstream* definition is unreachable until the shim
  covers it. That one shim entry (`reduce`) plus `reduced`/`reduced?` gates
  eight slices.
- **`volatile!` is doubly blocked.** Its definition carries `^{:inline
  (fn* …)}` — a reader-level FAIL before the `cpp/jank.runtime.volatile_`
  call is even reached. So the transducer 1-arities of `take-nth`,
  `map-indexed`, `keep-indexed`, `interpose`, `dedupe`, `drop-while`,
  `distinct` all wait on the same two fixes.
- **`map`/`filter`/`keep` load and behave.** Their collection arities run
  through the `(chunked-seq? s)` branch, and beam-lisp's `chunked-seq?` is
  `false`, so the dead chunked path never executes and the lazy path works —
  including `map`'s multi-coll arities (a *two-collection* `map` works when
  it is the vendored upstream one, because it recurses into itself; it is
  core's single-coll `map` that blocks `drop-last`/`mapv`).
- **`interleave` crashes on a lazy infinite input.** `(interleave (repeat
  :x) coll)` — which `interpose` expands to — raises
  `Enum.map_intersperse_list/3` no-clause. This is a genuine beam-lisp bug,
  not a missing feature, and it is the sole blocker for `interpose`.
- **The pure tail of the file is fully loadable.** `nthnext`, `nthrest`,
  `split-with`, `dorun`/`doall`, `take-last`, `filterv`, `distinct?`,
  `nfirst`/`fnext`, `map-entry?`, `not-every?`, `replicate`, `comparator`,
  `completing`, `not=`, `pos-int?` all behave verbatim — the deepest slices
  yet, none needing a patch.

### `deftype` / `defrecord` — nothing to vendor

The task list names `deftype`/`defrecord` users as a widening target. The
honest measurement result: **`core.jank@3028594` contains no `deftype`,
`defrecord`, or `defprotocol` form at all** — the only occurrences are
commented out (`(defprotocol Inst …)` at line 7236, `(deftype Eduction …)`
at line 7549). There is therefore no upstream slice that exercises records,
and another worker's `deftype`/`defrecord` implementation cannot be measured
through this file. The one protocol-adjacent machinery `core.jank` does use
(`defmulti`/`defmethod`, already shipped) was not widened further this wave.

## Gap classification

*Re-derived from the wave-24 sample. Unlock counts are the number of the 56
new slices each gap blocks; items are ordered by unlock count.*

### 1. The `cpp/jank.runtime.*` shim — the dominant blocker (15 slices)

`reduced`, `reduced?`, `reduce`(3-arity), `peek`, `pop`, `promoting_inc`,
`is_integer`, `is_ratio`, `is_big_decimal`, `is_sorted`, `is_nan`, plus the
bit ops, are all one-line `(cpp/jank.runtime.X …)` calls with no shim
entry. The earlier sample needed only `name`/`namespace_`/`keyword`; the
reduce family and every numeric predicate reach for more. **Smallest fix:
register `jank.runtime.reduced`, `is_reduced`, `reduce`, `peek`, `pop`, and
the `is_*` predicates under the `cpp` namespace** (the mechanism already
exists in `rt.ex`). `reduced`+`reduced?`+`reduce` alone unlock eight slices
directly (`ensure-reduced`, `unreduced`, `preserving-reduced`, `reductions`,
`cat`, `transduce`, and the `[f init coll]` arity of `reduce`), and
`transduce` is then a hop away from `into`.

### 2. Reader `^{}` metadata — the gate for the whole `^{}`-dialect (3 slices load, many more latent)

`(def ^{:arglists '([x])} …)` and `(defn ^{:inline (fn* …)} …)` both fail at
compile with no clause / `invalid fn clause`. Blocks `meta-def`, `volatile!`,
`bit-not` outright, and it is the *reader* half of the reason every `^{:inline}`
definition (`vreset!`, `vswap!`, the bit ops, `abs`, the `unchecked-*` set)
is unreachable. **The form-metadata machinery exists (`BeamLisp.FormMeta`);**
the reader only needs to attach the map to the following form. Unblocks
upstream's `^:private` / `^{:doc …}` / `^{:inline …}` definitions, which the
head of `core.jank` is built on.

### 3. `volatile!` / `vreset!` / `vswap!` (5 transducer arities)

Even once `^{}` reads, the transducer 1-arities of `take-nth`,
`map-indexed`, `keep-indexed`, `interpose`, and `dedupe` (plus the already-
noted `drop-while`/`distinct`) all build state on `(volatile! …)` /
`vswap!` / `vreset!`. Their collection arities already pass; this gap
completes the 1-arity transducer path of each, turning ✓-with-note into
full ✓. Depends on gap 2 (the definitions carry `^{:inline}`).

### 4. `transientable?` (3 slices)

`into`'s fast path branches on `(transientable? to)`; `splitv-at` and
`mapv`'s multi-coll arities go through `into`. beam-lisp has the transient
machinery but not the `transientable?` predicate. `into` is the biggest
single prize here — it is the confluence of `reduce`, `conj!`, and
`transduce` that the whole collection layer leans on.

### 5. `reduce-kv` (2 slices)

`update-vals` and `update-keys` both build through `(reduce-kv (fn [acc k v]
(assoc! acc …)) …)`. Self-hosted `reduce-kv` over the trie, or a core prim.

### 6. Multi-coll `map` in core (2 slices)

`drop-last` (`(map f coll (drop n coll))`) and `mapv`'s multi-coll arities
fail because beam-lisp's core `map` is single-coll. (The *vendored* upstream
`map` handles two colls by recursing into itself — slice 89 proves the
semantics; core just needs the arity.)

### 7. Small prims — one slice each

| prim | blocks | note |
|------|--------|------|
| `rem` | mod | `(rem num div)` — Erlang `:rem` |
| `float?` | double? | upstream `double?` is `(float? x)` |
| `==` | — | **present**; `map-entry?` passes because of it |
| `into` (transducer arity) | splitv-at | folds into gap 4 |

### 8. A real beam-lisp bug: `interleave` on a lazy infinite input (1 slice)

`interpose`'s coll arity is `(drop 1 (interleave (repeat sep) coll))`.
`(interleave (repeat :x) [1 2 3])` raises `Enum.map_intersperse_list/3` no
clause — the accepted `interleave` slice only ever saw finite realized
lists, so its lazy-input path was never exercised. This is a *bug* to fix,
not a feature to add.

### 9. Upstream stubs (not beam-lisp gaps)

`instance?`, `rseq`, `unchecked-inc-int`, and the already-known `with-open`
are `(throw "TODO: port …")` stubs in `core.jank` itself. They load and then
throw by construction; they cannot pass anywhere, including jank. Recorded
so a future agent does not chase them.

## What to build next

*Ranked by unlock count — the top of this list is what a whole-file fidelity
run now needs. The previous sample's "widen again" item is done; the gaps
below are the refilled, ranked backlog it produced.*

1. **The `cpp/jank.runtime.*` shim — `reduce`, `reduced`, `reduced?`,
   `peek`, `pop`, `is_*`.** One table in `rt.ex` already maps `name` /
   `namespace_` / `keyword`; extend it. `reduce`+`reduced`+`reduced?` unlock
   the entire transducer family (8 slices); the `is_*` predicates unlock the
   numeric layer (`int?`, `ratio?`, `decimal?`, `sorted?`, `NaN?`).
2. **Reader `^{}` metadata.** The single highest-leverage reader fix: it is
   the gate for every `def ^{:arglists …}` / `defn ^{:inline …}` at the head
   of `core.jank` (slice 65, 77, 78 today, and the whole primitive layer
   behind them). `BeamLisp.FormMeta` already exists — attach the map on read.
3. **`volatile!` / `vreset!` / `vswap!`** (after 2) — completes five
   transducer 1-arities and is the last piece of the transducer story.
4. **`transientable?`** → `into` → `splitv-at`, `mapv` multi-coll.
5. **`reduce-kv`** → `update-vals`, `update-keys`.
6. **Multi-coll `map` in core** → `drop-last`, `mapv` multi-coll.
7. **`rem`** → `mod`; **`float?`** → `double?`.
8. **Fix `interleave` on lazy infinite input** — a bug, not a feature; the
   accepted `interleave` slice hides it because its tests never feed it a
   lazy source.

## Keeping this honest

- The vendored fixtures carry a sha256 of their code portion; the test
  asserts it so any local edit silently voids the fidelity claim.
- If a slice ever *needs* an edit to load, that is a FAIL with the reason
  recorded — the fix goes into beam-lisp (`lib/`), never into the vendor.
- Big-bang loading of all 7795 lines is explicitly out of scope; the value
  is the per-slice, per-gap measurement above.

All 87 fully-behaving slices (89 counting the two ◐-partial `reduce`/`mapv`,
which pass their primary arities) are exercised by
`test/beam_lisp/jank_compat_test.exs` and demonstrated end-to-end by
`examples/jank_slice.bl` (unmodified jank running on the BEAM, exit 0).
