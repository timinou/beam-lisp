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
| 37 | take-while | 3070–3087 | `take-while` | ✓ | coll arity; *transducer 1-arity behaves* (wave 25 — `reduced` is now core) |
| 38 | drop-while | 3117–3140 | `drop-while` | ✓ | coll arity; *transducer 1-arity behaves* (wave 25 — `volatile!`) |
| 39 | split-at | 3157–3160 | `split-at` | ✓ | `take`/`drop` |
| 40 | interleave | 3167–3181 | `interleave` | ✓ | *was ◐* — the 1-arity `(lazy-seq c1)` case, same fix as lazy-cat |
| 41 | partition | 3231–3251 | `partition` | ✓ | *was ✗* — `nthrest`; exposed the lazy `count`/`next`/`Inspect` bugs |
| 42 | frequencies | 3322–3331 | `frequencies` | ✓ | *was ✗* — transients (wave 17) |
| 43 | group-by | 3333–3344 | `group-by` | ✓ | *was ✗* — transients (wave 17) |
| 44 | for | 3145–3216 | `for` macro | ✓ | *was ✗* — needed three unrelated fixes: a rest arg that is itself a pattern, bare-LazySeq normalization, and `when-first` (wave 23) |
| 45 | assoc-in | 3697–3704 | `assoc-in` | ✓ | *was ✗ (hung)* — closed by nil-terminating `&` rest |
| 46 | update-in | 3706–3718 | `update-in` | ✓ | *was ✗ (hung)* — same fix; needs the `assoc-in` slice co-loaded |
| 47 | update | 3720–3734 | `update` | ✓ | `assoc`/`get`/`apply`, variadic |
| 48 | mapcat | 3790–3796 | `mapcat` | ✓ | coll arity; *transducer 1-arity behaves* (wave 25 — needs `cat` + `comp` co-loaded, core deps) |
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
| 65 | meta-def | 75–79 | `list?` (via `def ^{:arglists …}`) | ✓ | *was ✗* — the reader `^{}`-metadata fix (wave 25) + the `is_list` cpp shim |
| 66 | reduced | 1090–1094 | `reduced` | ✓ | *was ✗* — `cpp/jank.runtime.reduced` shimmed (wave 25) |
| 67 | reduced? | 1095–1099 | `reduced?` | ✓ | *was ✗* — `is_reduced` shimmed |
| 68 | ensure-reduced | 1100–1106 | `ensure-reduced` | ✓ | *was ✗* — `reduced?`/`reduced` are now core |
| 69 | unreduced | 1107–1113 | `unreduced` | ✓ | *was ✗* — `reduced?` is now core |
| 70 | reduce | 1114–1132 | `reduce` | ✓ | *was ◐* — the `[f init coll]` arity now runs the shimmed `cpp/jank.runtime.reduce`, which genuinely short-circuits a `Reduced` |
| 71 | completing | 1133–1143 | `completing` | ✓ | pure fn (multi-arity) |
| 72 | transduce | 1144–1160 | `transduce` | ✓ | *was ✗* — `cpp reduce` shimmed; the docstring example needs the vendored 1-arity transducer `map` (slice 89) co-loaded |
| 73 | preserving-reduced | 1161–1167 | `preserving-reduced` | ✓ | *was ✗* — `reduced?`/`reduced` are now core |
| 74 | cat | 1168–1178 | `cat` | ✓ | *was ✗* — needs the `preserving-reduced` slice co-loaded (core dep) |
| 75 | peek | 1203–1208 | `peek` | ✓ | *was ✗* — `cpp/jank.runtime.peek` shimmed (vector-last / list-first) |
| 76 | pop | 1209–1216 | `pop` | ✓ | *was ✗* — `cpp/jank.runtime.pop` shimmed |
| 77 | volatile! | 1308–1315 | `volatile!` | ✓ | *was ✗* — reader `^{:inline (fn* …)}` now reads + `volatile_` shimmed (wave 25) |
| 78 | bit-not | 1426–1432 | `bit-not` | ✗ | loads now (the `^{:inline}` reader gate is clear), but `cpp/jank.runtime.bit_not` is **not shimmed** — still fails at call |
| 79 | not= | 1533–1540 | `not=` | ✓ | `not`/`=`/`apply` |
| 80 | mod | 1693–1701 | `mod` | ✗ | `rem` still undefined in core |
| 81 | inc' | 1750–1774 | `inc'` | ✓ | *was ✗* — `cpp/jank.runtime.promoting_inc` shimmed (arbitrary-precision integers never overflow) |
| 82 | unchecked-inc-int | 1825–1831 | `unchecked-inc-int` | ✗ | **upstream TODO stub** — `(throw "TODO: port unchecked-inc-int")` |
| 83 | int? | 1930–1934 | `int?` | ✓ | *was ✗* — `cpp/jank.runtime.is_integer` shimmed |
| 84 | pos-int? | 1935–1939 | `pos-int?` | ✓ | `int?` resolves to beam-lisp's native int?; `pos?` |
| 85 | double? | 1950–1954 | `double?` | ✗ | `float?` still undefined in core |
| 86 | nthnext | 2839–2847 | `nthnext` | ✓ | `seq`/`next`/`pos?` |
| 87 | nthrest | 2848–2857 | `nthrest` | ✓ | `if-let`/`seq`/`rest` |
| 88 | take-nth | 2858–2876 | `take-nth` | ✓ | coll arity; *transducer 1-arity needs `rem`* (new blocker — `volatile!` is done, its xform body uses `(rem i n)`) |
| 89 | map | 2877–2926 | `map` | ✓ | all coll arities incl. multi-coll; the `chunked-seq?` branch is dead here (`chunked-seq?` is false), so the lazy path runs. *Transducer 1-arity behaves* (wave 25) |
| 90 | map-indexed | 2943–2970 | `map-indexed` | ✓ | coll + *transducer 1-arity both behave* (wave 25) |
| 91 | keep | 2971–3001 | `keep` | ✓ | coll arity; chunked branch dead |
| 92 | keep-indexed | 3002–3037 | `keep-indexed` | ✓ | coll + *transducer 1-arity both behave* (wave 25) |
| 93 | drop-last | 3112–3116 | `drop-last` | ✓ | *was ✗* — `(map f coll (drop n coll))` is a two-coll `map`; behaves when core.jank's own multi-coll `map` (slice 89) is co-loaded. beam-lisp's *native* `map` is still single-coll (a user-facing gap, tracked below) |
| 94 | split-with | 3162–3166 | `split-with` | ✓ | needs the `juxt` slice co-loaded (core dep) |
| 95 | interpose | 3183–3203 | `interpose` | ✓ | *was ✗* — the `interleave` lazy-infinite crash is fixed (core `interleave` is now the pure lazy `priv/core.bl` version, not `Enum.intersperse`); the 1-arity transducer (volatile!-based) also behaves. Needs the `interleave` slice co-loaded (core dep) |
| 96 | dorun | 3204–3216 | `dorun` | ✓ | `when-let` + top-level `recur` |
| 97 | doall | 3217–3230 | `doall` | ✓ | needs the `dorun` slice co-loaded |
| 98 | reductions | 3346–3361 | `reductions` | ✓ | *was ✗* — `reduced?` is now core |
| 99 | into | 3362–3375 | `into` | ✗ | `transientable?` still undefined in core — loads, fails at call |
| 100 | take-last | 3749–3758 | `take-last` | ✓ | `loop`/`drop` |
| 101 | mapv | 3759–3777 | `mapv` | ◐ | 1-arity (transient) passes; multi-coll arities still need `into` + a multi-coll `map` — both still gaps |
| 102 | filterv | 3778–3789 | `filterv` | ✓ | transients + `persistent!` |
| 103 | distinct? | 3838–3852 | `distinct?` | ✓ | the `#{}` set literal + `contains?` + `not=` |
| 104 | filter | 3853–3882 | `filter` | ✓ | coll arity; chunked branch dead |
| 105 | dedupe | 3900–3923 | `dedupe` | ✓ | coll arity; *transducer 1-arity behaves* (wave 25); needs the `when-some` slice co-loaded (core dep) |
| 106 | nfirst | 4993–4997 | `nfirst` | ✓ | `next`/`first` |
| 107 | fnext | 4998–5002 | `fnext` | ✓ | `first`/`next` |
| 108 | instance? | 5003–5009 | `instance?` | ✗ | **upstream TODO stub** — `(throw "TODO: port instance?")` |
| 109 | map-entry? | 5066–5071 | `map-entry?` | ✓ | `vector?` + `==` |
| 110 | rseq | 5072–5078 | `rseq` | ✗ | **upstream TODO stub** — `(throw "TODO: port rseq")` |
| 111 | not-every? | 5533–5538 | `not-every?` | ✓ | `every?` |
| 112 | replicate | 5543–5547 | `replicate` | ✓ | `take`/`repeat` |
| 113 | comparator | 5644–5649 | `comparator` | ✓ | `cond` |
| 114 | ratio? | 5831–5835 | `ratio?` | ✓ | *was ✗* — `is_ratio` shimmed; genuinely always false (beam-lisp has no Ratio type) |
| 115 | decimal? | 5846–5851 | `decimal?` | ✓ | *was ✗* — `is_big_decimal` shimmed; always false (no BigDecimal) |
| 116 | sorted? | 6977–6981 | `sorted?` | ✓ | *was ✗* — `is_sorted` shimmed; always false (no sorted coll) |
| 117 | splitv-at | 7448–7452 | `splitv-at` | ✗ | `(into [] (take n) coll)` — the transducer arity of `into`; loads but `into` (99) still fails on `transientable?`, and the `(take n)` 1-arity needs a transducer `take` |
| 118 | update-vals | 7721–7735 | `update-vals` | ✗ | `reduce-kv` + `transientable?` undefined in core |
| 119 | update-keys | 7736–7749 | `update-keys` | ✗ | `reduce-kv` undefined in core |
| 120 | NaN? | 7787–7791 | `NaN?` | ✓ | *was ✗* — `is_nan` shimmed; always false because beam-lisp cannot produce a NaN (no `##NaN` literal, `(/ 0.0 0.0)` raises, no Math module) |

## Counts — the headline

> **109 of 120 attempted slices** load **and** behave correctly. The
> trajectory is the point: **7 → 13 → 21 → 36 → 38 → 62 → 63 → 89 → 109**
> across eleven waves, each aimed by this document's ranked gap list. Wave 25
> was a *re-measure*, not a widening: the wave-24 gap list named exactly what
> the four headline gaps blocked, the gaps were built, and 20 of the 31
> then-failing slices turned out to behave once measured. Nothing was patched
> into passing — the fixtures are still byte-for-byte upstream and the
> checksum test proves it. Where a slice needs another slice (`split-with`
> needs `juxt`; `doall` needs `dorun`; `dedupe` needs `when-some`; `mapcat`
> needs `complement`; `drop-last` needs the vendored multi-coll `map`;
> `interpose` needs `interleave`), that dependency is `core.jank`'s own,
> satisfied with unmodified upstream text.
>
> **The re-measure is the deliverable.** The wave-24 ranked list predicted
> which slices each gap would unlock; the honest check below ("prediction
> vs outcome") says where that list was right and where it was wrong. The
> headline: the `cpp/jank.runtime.*` shim, the reader `^{}`-metadata fix,
> and `volatile!`/`vreset!`/`vswap!` together turned 20 failing slices into
> behaving ones, and the transducer 1-arities that the shim+volatile pair
> was built to complete now work. The *small-core-gaps* item in the wave-24
> list (`rem`, `float?`, `transientable?`, `reduce-kv`, multi-coll `map`,
> the `interleave` crash) was **not actually built** — only the `interleave`
> crash was fixed as a side effect of self-hosting `interleave` in
> `priv/core.bl`. That part of the prediction is where the list was wrong,
> and the seven remaining failures are exactly those gaps.
>
> The score now: **109 pass**, **7 real failures**, **4 upstream TODO stubs**.
> The seven failures load (the reader accepts every form now) but compute a
> wrong answer or raise at call time:
>
> 1. **`transientable?`** (3 slices) — `into` (99), `update-vals` (118),
>    `splitv-at` (117, which also needs the transducer `take`);
> 2. **`reduce-kv`** (2 slices) — `update-vals` (118), `update-keys` (119);
> 3. **one-slice gaps** — `rem` (`mod`), `float?` (`double?`), and the
>    cpp shim's missing `bit_not` entry (`bit-not`), whose reader gate is
>    now clear.
>
> The four upstream stubs (`with-open`, `instance?`, `rseq`,
> `unchecked-inc-int`) throw by construction and cannot pass anywhere,
> jank included. They are recorded, never counted against beam-lisp.

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

### What wave 25 found (re-measure, not widening)

Wave 25 did not add slices; it re-loaded every one of the 31 that wave 24
had marked failing and called it with its own docstring example. The results
are the honest test of the wave-24 gap list.

- **All 31 slices now LOAD.** The reader `^{}` fix unblocked the three
  `^{:arglists}`/`^{:inline}` forms outright (`meta-def`, `volatile!`,
  `bit-not`), and every other fixture's reader form was already accepted.
  Loading is no longer the discriminator — behavior is.
- **Twenty previously-failing slices now behave.** The cpp shim entries
  (`reduced`, `is_reduced`, `reduce`, `peek`, `pop`, `promoting_inc`, the
  five `is_*` predicates) are real, the reader reads `^{}` metadata, and
  `volatile!`/`vreset!`/`vswap!` work — so `reduced`/`reduced?`/
  `ensure-reduced`/`unreduced`/`preserving-reduced`/`cat`/`transduce`/`peek`/
  `pop`/`inc'`/`int?`/`list?`/`volatile!`/`reductions`/`interpose`/
  `drop-last` and the four numeric predicates all compute the right answer.
  `reduce` upgraded from ◐ to ✓ (its `[f init coll]` arity now short-circuits
  on a `Reduced`).
- **The transducer 1-arities behave — almost all of them.** This is where
  the volatile! prediction was *right*: `take-while`, `drop-while`,
  `map-indexed`, `keep-indexed`, `dedupe`, `distinct`, `interpose`, `map`,
  `mapcat` now reduce correctly as transducers. Two honest caveats:
  `take-nth`'s xform is now blocked by `rem` (its body is `(rem i n)`), a
  *different* blocker than the predicted `volatile!`; and driving any of
  them with `conj` as the reducing fn fails at transduce's final `(f ret)`
  because beam-lisp's `conj` has no 1-arity completing form (a real core
  gap — `(conj coll)` is valid Clojure). The tests drive them with `+`,
  which accepts the completing 1-arity.
- **`interpose` was the prediction's cleanest win.** The `interleave` lazy-
  infinite crash is gone because core `interleave` is now the pure lazy
  `priv/core.bl` self-hosted version, not `Enum.intersperse`. `interpose`
  behaves on both its coll arity and its volatile!-based transducer arity.
- **The prediction's miss: the "small core gaps" were not built.** The
  wave-24 list claimed `rem`, `float?`, `transientable?`, `reduce-kv`,
  multi-coll `map`, and the `interleave` crash were slated fixes. Measured:
  only the `interleave` crash is fixed (a side effect of the self-hosted
  rewrite). `rem`, `float?`, `transientable?`, and `reduce-kv` are simply
  absent, and the cpp shim also lacks the `bit_not` entry `bit-not` needs
  (its reader gate, cleared this wave, now reveals the missing shim entry).
  Those are the seven failures that remain, and they are exactly the gaps
  this wave was supposed to close but did not.
- **Four "wins" are vacuously correct.** `ratio?`, `decimal?`, `sorted?`
  and `NaN?` load and behave — but only because beam-lisp has no Ratio,
  BigDecimal, sorted-collection, or NaN value at all, so they are genuinely
  always false. `NaN?` in particular cannot ever see a NaN: there is no
  `##NaN` literal, `(/ 0.0 0.0)` raises instead of yielding one, and no Math
  module exists. These are honest passes (correct for every reachable
  input) that happen to exercise no true branch.

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

*Re-derived from the wave-25 sample — every gap is a *call-time* failure now,
not a load failure. The reader accepts every form in the 120; the remaining
seven failures load and then compute a wrong answer or raise. Items are
ordered by unlock count.*

### 1. `transientable?` — the dominant blocker (3 slices + 1 upgrade)

`into`'s fast path branches on `(transientable? to)`; `update-vals` builds a
`transient {}` fallback under the same predicate; `splitv-at` goes through
`into`'s transducer arity; and `mapv`'s multi-coll arities are `(into []
(map …))`. The predicate simply does not exist in beam-lisp's core. `into`
remains the single biggest prize — it is the confluence of `reduce`, `conj!`,
and `transduce` that the whole collection layer leans on, and it was the
wave-24 list's #4 that was never actually built. `splitv-at` also needs the
1-arity transducer `take` (`(into [] (take n) coll)`), which folds into the
same transducer work.

### 2. `reduce-kv` (2 slices)

`update-vals` and `update-keys` both build through `(reduce-kv (fn [acc k v]
(assoc! acc …)) …)`. Neither self-hosted `reduce-kv` nor a core prim exists.
(`update-vals` is double-blocked — it also needs `transientable?`.)

### 3. Small one-slice gaps

| prim | blocks | note |
|------|--------|------|
| `rem` | mod · take-nth's transducer (88) | `(rem i n)` — Erlang `:rem`; take-nth's xform is *newly* blocked here, its old `volatile!` blocker being gone |
| `float?` | double? | upstream `double?` is `(float? x)` |
| `cpp … bit_not` | bit-not | the one cpp shim entry still missing — its reader `^{:inline}` gate is cleared, so this is now a pure table addition |

### 4. Multi-coll `map` in core (1 upgrade)

`mapv`'s multi-coll arities still need a two-coll core `map` (and `into`).
`drop-last` no longer counts here — it behaves via core.jank's own vendored
multi-coll `map` (slice 89) co-loaded — but a *user* calling `(map f a b)`
still hits beam-lisp's single-coll native `map`. Worth doing for user code;
worth one slice upgrade (`mapv` ◐→✓).

### 5. `conj` has no 1-arity completing form (latent)

Discovered by the wave-25 transducer pass: `(conj coll)` is valid Clojure and
is what transduce's final `(f ret)` step needs when `conj` is the reducing
fn. beam-lisp's `conj` is fixed-2-arity, so `(transduce xform conj [] coll)`
fails at the completing step. Every transducer xform in the sample works when
driven with a completing-capable rf (`+`); this gap blocks the *standard*
Clojure idiom, not any individual slice. One arity on `conj` closes it.

### 6. Upstream stubs (not beam-lisp gaps)

`instance?`, `rseq`, `unchecked-inc-int`, and the already-known `with-open`
are `(throw "TODO: port …")` stubs in `core.jank` itself. They load and then
throw by construction; they cannot pass anywhere, including jank. Recorded
so a future agent does not chase them.

## What to build next

*Re-ranked by unlock count from the wave-25 reality. The three biggest
wave-24 items (the cpp shim, the reader `^{}` fix, `volatile!`) are done and
paid for — they are the 20 new passes. What remains is a much smaller,
more precise list, and its top two items are exactly the wave-24 entries
that were *predicted but never built*.*

1. **`transientable?`** (→ `into`, `update-vals`, `splitv-at`, `mapv`
   multi-coll). The highest-value remaining single primitive. `into` is
   the collection layer's confluence point; a one-line predicate plus the
   transducer arity of `take` closes three slices and upgrades `mapv`.
2. **`reduce-kv`** (→ `update-vals`, `update-keys`). Self-hosted over the
   map, or a core prim; two slices.
3. **`rem`** (→ `mod`, take-nth's transducer). One Erlang BIF call; two
   slices including the last `volatile!`-era holdout.
4. **`float?`** (→ `double?`). One slice.
5. **`cpp/jank.runtime.bit_not`** (→ `bit-not`). One table row in `rt.ex`;
   completes the shim. `bit-not`'s reader gate is already clear, so this
   slice is one registry entry from ✓.
6. **Multi-coll `map` in core** (→ `mapv` ◐→✓, and fixes real user code).
7. **`conj` 1-arity completing form** (→ the standard `(transduce xform conj
   …)` idiom). A real core gap the transducer pass exposed.

### Prediction vs outcome — how the wave-24 list fared

The wave-24 ranked list predicted what each gap would unlock. Checked
against what the re-measure actually found:

- **The cpp shim was exactly as predicted, mostly.** It unlocked the
  transducer family (`reduced`/`reduced?`/`reduce` → `ensure-reduced`,
  `unreduced`, `preserving-reduced`, `reductions`, `cat`, `transduce`, the
  `[f init coll]` arity of `reduce`) and the numeric layer (`int?`,
  `ratio?`, `decimal?`, `sorted?`, `NaN?`) — every one of those predictions
  landed. The one miss: the list called `bit-not` a shim+reader double gap;
  the reader half was fixed but the `bit_not` table entry was **not** added,
  so that slice still fails at call time.
- **Reader `^{}` metadata: exactly right.** It unblocked `meta-def`,
  `volatile!`, `bit-not` at load, and with it every `^{:inline}`-carrying
  definition. All 31 slices now load — a claim the previous list did not
  make and the measurement now does.
- **`volatile!`/`vreset!`/`vswap!`: right on the transducer arities, with
  one wrong name.** The list said it would complete five transducer
  1-arities; it did, and a couple more (`drop-while`, `distinct`,
  `interpose`, `map`). But it *named `take-nth` among them* — take-nth's
  xform turns out to be blocked by `rem`, not `volatile!`. The prediction
  got the category right and one concrete slice wrong.
- **The "small core gaps" item was the outright miss.** The list presented
  `rem`, `float?`, `transientable?`, `reduce-kv`, multi-coll `map`, and the
  `interleave` crash as a settled backlog. Measured: only the `interleave`
  crash is fixed (as a side effect of self-hosting `interleave`); the other
  five primitives simply do not exist. The seven failures that remain are
  *exactly* those never-built primitives. The prediction over-claimed what
  had shipped, and the score honestly reflects it.

A gap list that is never checked against results is astrology. This one
was checked: the shim, the reader, and `volatile!` were real and paid off;
the small-prim backlog was listed but not built, and the re-measure catches
that rather than laundering it into the number.

## Keeping this honest

- The vendored fixtures carry a sha256 of their code portion; the test
  asserts it so any local edit silently voids the fidelity claim.
- If a slice ever *needs* an edit to load, that is a FAIL with the reason
  recorded — the fix goes into beam-lisp (`lib/`), never into the vendor.
- Big-bang loading of all 7795 lines is explicitly out of scope; the value
  is the per-slice, per-gap measurement above.

All 109 fully-behaving slices (108 clean plus `mapv`, whose 1-arity passes and
multi-coll arities are recorded ◐) are exercised by
`test/beam_lisp/jank_compat_test.exs` and demonstrated end-to-end by
`examples/jank_slice.bl` (unmodified jank running on the BEAM, exit 0).
