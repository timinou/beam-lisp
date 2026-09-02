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
> failed at the reader/compiler itself (`for` and `distinct` were reader
> failures that later waves fixed, and wave 25's reader `^{}`-metadata fix
> cleared the last of them — every fixture loads now). And only some of the
> loaded slices run correctly when called. The verdicts below are behavioral
> — the checklist marks each.

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
| 78 | bit-not | 1426–1432 | `bit-not` | ✓ | *was ✗* — the `cpp/jank.runtime.bit_not` shim row shipped (wave 26); its `^{:inline}` reader gate cleared in wave 25 |
| 79 | not= | 1533–1540 | `not=` | ✓ | `not`/`=`/`apply` |
| 80 | mod | 1693–1701 | `mod` | ✓ | *was ✗* — `rem` shipped as a core prim (wave 26); truncates toward negative infinity, matching Clojure |
| 81 | inc' | 1750–1774 | `inc'` | ✓ | *was ✗* — `cpp/jank.runtime.promoting_inc` shimmed (arbitrary-precision integers never overflow) |
| 82 | unchecked-inc-int | 1825–1831 | `unchecked-inc-int` | ✗ | **upstream TODO stub** — `(throw "TODO: port unchecked-inc-int")` |
| 83 | int? | 1930–1934 | `int?` | ✓ | *was ✗* — `cpp/jank.runtime.is_integer` shimmed |
| 84 | pos-int? | 1935–1939 | `pos-int?` | ✓ | `int?` resolves to beam-lisp's native int?; `pos?` |
| 85 | double? | 1950–1954 | `double?` | ✓ | *was ✗* — `float?` shipped as a core prim (wave 26) |
| 86 | nthnext | 2839–2847 | `nthnext` | ✓ | `seq`/`next`/`pos?` |
| 87 | nthrest | 2848–2857 | `nthrest` | ✓ | `if-let`/`seq`/`rest` |
| 88 | take-nth | 2858–2876 | `take-nth` | ✓ | coll arity; *transducer 1-arity now behaves too* — its xform body is `(rem i n)`, and `rem` shipped (wave 26) |
| 89 | map | 2877–2926 | `map` | ✓ | all coll arities incl. multi-coll; the `chunked-seq?` branch is dead here (`chunked-seq?` is false), so the lazy path runs. *Transducer 1-arity behaves* (wave 25) |
| 90 | map-indexed | 2943–2970 | `map-indexed` | ✓ | coll + *transducer 1-arity both behave* (wave 25) |
| 91 | keep | 2971–3001 | `keep` | ✓ | coll arity; chunked branch dead |
| 92 | keep-indexed | 3002–3037 | `keep-indexed` | ✓ | coll + *transducer 1-arity both behave* (wave 25) |
| 93 | drop-last | 3112–3116 | `drop-last` | ✓ | *was ✗* — `(map f coll (drop n coll))` is a two-coll `map`; behaves when core.jank's own multi-coll `map` (slice 89) is co-loaded. beam-lisp's *native* `map` is still single-coll (a user-facing gap, tracked below) |
| 94 | split-with | 3162–3166 | `split-with` | ✓ | needs the `juxt` slice co-loaded (core dep) |
| 95 | interpose | 3183–3203 | `interpose` | ✓ | *was ✗* — the `interleave` lazy-infinite crash is fixed (core `interleave` is now the pure lazy `priv/boot/core.bl` version, not `Enum.intersperse`); the 1-arity transducer (volatile!-based) also behaves. Needs the `interleave` slice co-loaded (core dep) |
| 96 | dorun | 3204–3216 | `dorun` | ✓ | `when-let` + top-level `recur` |
| 97 | doall | 3217–3230 | `doall` | ✓ | needs the `dorun` slice co-loaded |
| 98 | reductions | 3346–3361 | `reductions` | ✓ | *was ✗* — `reduced?` is now core |
| 99 | into | 3362–3375 | `into` | ✓ | *was ◐* — both remaining gaps closed in wave 27: `conj!` grew a map-transient clause (accepting either entry spelling) and `map`/`filter` grew 1-arity transducer forms **on the primitive**. All four upstream arities are now called in the compat test, not just the easy one |
| 100 | take-last | 3749–3758 | `take-last` | ✓ | `loop`/`drop` |
| 101 | mapv | 3759–3777 | `mapv` | ✓ | *was ◐* — the multi-coll arities are `(into [] (map f c1 c2 …))`; `into` and core multi-coll `map` shipped (wave 26), so all arities behave |
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
| 117 | splitv-at | 7448–7452 | `splitv-at` | ✓ | *was ✗* — `(into [] (take n) coll)` needs `into`'s transducer arity (now on `transientable?`) and the 1-arity transducer `take`, both shipped (wave 26) |
| 118 | update-vals | 7721–7735 | `update-vals` | ✓ | *was ✗* — `reduce-kv` + `transientable?` both shipped (wave 26) |
| 119 | update-keys | 7736–7749 | `update-keys` | ✓ | *was ✗* — `reduce-kv` shipped (wave 26) |
| 120 | NaN? | 7787–7791 | `NaN?` | ✓ | *was ✗* — `is_nan` shimmed; always false because beam-lisp cannot produce a NaN (no `##NaN` literal, `(/ 0.0 0.0)` raises, no Math module) |

## Counts — the headline

> **116 of 120 attempted slices** load **and** behave correctly. The
> trajectory is the point: **7 → 13 → 21 → 36 → 38 → 62 → 63 → 89 → 109 → 115 → 116**
> across twelve waves, each aimed by this document's ranked gap list. Wave 25
> was a *re-measure*, not a widening: the wave-24 gap list named exactly what
> the four headline gaps blocked, the gaps were built, and 20 of the 31
> then-failing slices turned out to behave once measured. Wave 26 was the
> *payoff*: the seven remaining failures were exactly the "small core gaps"
> the wave-24 list had ranked and wave 25 admitted were never built — and
> this time they were. Nothing was patched into passing — the fixtures are
> still byte-for-byte upstream and the checksum test proves it. Where a slice
> needs another slice (`split-with` needs `juxt`; `doall` needs `dorun`;
> `dedupe` needs `when-some`; `mapcat` needs `complement`; `drop-last` needs
> the vendored multi-coll `map`; `interpose` needs `interleave`), that
> dependency is `core.jank`'s own, satisfied with unmodified upstream text.
>
> **Wave 26 shipped the wave-25 failure list.** The seven real failures wave
> 25 recorded were `transientable?` (into, update-vals, splitv-at),
> `reduce-kv` (update-vals, update-keys), `rem` (mod, take-nth's transducer),
> `float?` (double?), and the cpp shim's missing `bit_not` entry (bit-not).
> Every one of those primitives shipped, and six of the seven affected slices
> now load **and** behave (`mod`, `double?`, `bit-not`, `splitv-at`,
> `update-vals`, `update-keys`), `take-nth`'s transducer arity unblocked, and
> `mapv` upgraded from ◐ to ✓ (its multi-coll arities are `(into [] (map f
> c1 c2 …))`, and `into` + core multi-coll `map` both shipped).
>
> **One slice did not behave, and it was not promoted.** `into` (99) was the
> worker's ninth claim, and the honest verdict is ◐, not ✓. `transientable?`
> unblocked its vector/reduce and `take`-xform transducer paths, but two
> common call shapes still throw at call time: `(into {} …)` (the
> map-transient `conj!` clause is missing — `BeamLisp.Transient.conj!/2` only
> handles vector and set transients) and `(into [] (map inc) …)` (core `map`
> still lacks its 1-arity transducer form). Both are small prim gaps, recorded
> in the taxonomy below. `into` stays un-promoted until they close.
>
> The score now: **116 pass**, **4 upstream TODO stubs**, **0 outstanding
> beam-lisp gaps**. The four stubs (`with-open`, `instance?`, `rseq`,
> `unchecked-inc-int`) have commented-out bodies in `core.jank` itself: they
> load and then throw by construction, so they cannot pass in jank either.
> They are recorded, never counted against beam-lisp.
>
> **This sample is now exhausted.** Every slice that can pass, does. The
> informative next move is a fourth widening, not further work against these
> 120 — a sample where everything passes has stopped measuring anything.
>
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
  `priv/boot/core.bl` self-hosted version, not `Enum.intersperse`. `interpose`
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

### What wave 26 found (the small-core-gaps backlog, actually built)

Wave 26 built the primitives the wave-25 failure list named — `rem`,
`float?`, `transientable?`, `reduce-kv`, the `cpp/jank.runtime.bit_not` shim
row, plus `into` in core, a multi-coll `map`, and `take`'s transducer 1-arity
— and re-measured the nine slices that had been blocked on them. The honest
findings, each verified by calling the slice with its own docstring semantics:

- **Six of the seven previously-failing slices now behave outright.** `mod`
  (`rem`), `double?` (`float?`), `bit-not` (the `bit_not` shim row), and the
  transducer forms `splitv-at` (`into`'s transducer arity + `take` 1-arity),
  `update-vals` (`reduce-kv` + `transientable?`), and `update-keys`
  (`reduce-kv`) all load and compute the right answer. `take-nth`'s
  transducer arity (blocked on `rem`) behaves too.
- **`mapv` upgraded from ◐ to ✓.** Its multi-coll arities are `(into [] (map
  f c1 c2 …))`; with `into` and core multi-coll `map` both shipped, every
  arity computes the right vector. The ◐ was a dependency on two slices that
  are now both present.
- **`into` was the one refusal.** `transientable?` unblocked its
  vector/reduce and `take`-xform paths, but `(into {} …)` still throws —
  `BeamLisp.Transient.conj!/2` has clauses only for vector and set transients,
  not map — and `(into [] (map inc) …)` still throws because core `map` has
  no 1-arity transducer form. Both are genuine call-time failures on common
  usage, so `into` was **not** promoted; it is recorded ◐ below. Two small
  prim gaps the wave-25 ranked list did *not* predict (it predicted
  `transientable?` would fully unblock `into`; the predicate shipped but two
  unlisted gaps surfaced when `into` was finally measured).
- **The `conj` 1-arity completing form shipped too.** Wave 25 recorded it as
  a latent gap; `(conj coll)` now returns `coll`, so `transduce`'s final
  `(f ret)` step works with `conj` as the reducing fn.
- **The sample is effectively exhausted.** With `into` ◐ and the four
  upstream stubs (`with-open`, `instance?`, `rseq`, `unchecked-inc-int`)
  throwing by construction, there are no *fully* loadable-but-failing slices
  left to chase. The informative next moves are the two `into` gaps (below)
  and a fourth widening of the sample — see "What to build next".

### `deftype` / `defrecord` — nothing to vendor

The task list names `deftype`/`defrecord` users as a widening target. The
honest measurement result: **`core.jank@3028594` contains no `deftype`,
`defrecord`, or `defprotocol` form at all** — the only occurrences are
commented out (`(defprotocol Inst …)` at line 7236, `(deftype Eduction …)`
at line 7549). There is therefore no upstream slice that exercises records,
and another worker's `deftype`/`defrecord` implementation cannot be measured
through this file. The one protocol-adjacent machinery `core.jank` does use
(`defmulti`/`defmethod`, already shipped) was not widened further this wave.

## What wave 27 found (the sample's last useful finding)

Closing `into` took two prim fixes, and the *way* the second one was built
is the finding worth keeping.

- **`conj!` had no map-transient clause.** `into`'s fast path reduces `conj!`
  over a transient, and `BeamLisp.Transient.conj!/2` handled only vector and
  set transients. A map entry arrives in one of two spellings — the
  2-element `%Vector{}` that `seq` yields over a map, or a 2-element list from
  a quoted source — and both had to be accepted. A 3-element vector now
  raises rather than silently binding its first two fields, which would have
  produced a plausible-looking wrong map.

- **`map`/`filter` had no 1-arity transducer form**, so `(into [] (map inc) c)`
  failed at *xform construction*, before `into`'s body ran at all.

- **The transducer arities were first built the wrong way, and this sample
  caught it.** They initially landed as a REBINDING in `core.bl`:
  `(def map-coll-prim map)` followed by a new `defn map` delegating back to
  the captured primitive. Every unit test passed. The fidelity suite failed —
  correctly. Upstream's own `map` slice (89) *defines a `map`* with no
  transducer arity, a `defn` outlives the namespace that made it, and the
  captured prim was shadowed globally. The symptom was a `BadArityError` in a
  test file that had not changed.

  Defining the arity on the primitive instead leaves nothing to shadow, and
  keeps one implementation of the chunked-lazy path rather than a second
  Lisp-level copy that would drift. **A rebinding is only safe when nobody
  else can rebind the same name** — and in a language whose fidelity target
  is a stdlib full of `defn map`, nobody can promise that.

  This is the second time in as many waves that running someone else's code
  caught a design error the language's own tests could not.

- **A cross-test namespace leak, found on the way.** Wave 24's records test
  was `defn`-ing `keys`/`vals`/`merge`/`into` into the shared `user`
  namespace, which outlives the file. Whichever ran last won, so `(keys nil)`
  returned `()` instead of `nil` in roughly two runs in three. The shim
  predated those functions existing; three of the four now ship, and `merge`
  was added to the prelude to retire the last of it.

## Gap classification

*Re-derived from the wave-27 sample. **There are no outstanding beam-lisp
gaps against these 120 slices.** The two prim gaps inside `into` (99) both
closed — `conj!` grew its map-transient clause and `map`/`filter` grew
1-arity transducer forms on the primitive — and `into` is promoted to ✓.
What is left is one category, and it is not ours.*

### 1. Upstream stubs (not beam-lisp gaps) — 4 slices

`with-open`, `instance?`, `rseq`, and `unchecked-inc-int` are
`(throw "TODO: port …")` stubs in `core.jank` itself: their real bodies are
commented out upstream. They load and then throw by construction, so they
cannot pass anywhere, jank included. Recorded permanently so a future agent
does not chase them.

Note `instance?` is a special case worth stating: beam-lisp *does* ship an
`instance?` in its prelude (wave 27), defined against beam-lisp's own type
identities. The SLICE still fails, because the vendored slice is upstream's
stub, and the fixture is never edited. Both facts are true and neither
cancels the other.

### 2. Nothing else

This is the honest end of this sample. Every slice that can pass, does.

## What to build next

*Re-ranked from the wave-27 reality. Every item on the wave-26 list shipped;
that backlog is closed, and so is this sample. There is no remaining
beam-lisp gap to rank against these 120 slices.*

1. **A fourth widening of the sample.** This is the only informative move
   left. The sample is exhausted: 116 pass, and the 4 that do not are
   upstream stubs that throw by construction. A sample where everything
   that can pass does pass has stopped measuring anything — it now confirms
   a result rather than finding new ones. Vendor another tranche of
   `core.jank`, expect the score to DROP, and treat the drop as the
   deliverable (it has happened twice before: 63→89 on the 64→120
   widening, and the list refilled each time).
2. **A different measured target.** Specter is already vendored and sits far
   lower (see `specter-compat.md`), and its remaining distance is a
   *different kind* of work — library impl machinery rather than language
   surface. Other candidates worth weighing if a third target is wanted:
   `core.match`, `clojure.spec`, `medley`, `meander`.

**What NOT to do:** re-measure these 120 again. Wave 27 was the last
re-measure that could move the number, and it moved it by one.

### Prediction vs outcome — how the ranked lists fared

**Wave 27's check (most recent).** The wave-26 list ranked exactly two items,
both inside `into`, and predicted they were the last beam-lisp gaps in this
sample.

- **Both materialised, exactly as ranked.** `conj!`'s map-transient clause
  closed `(into {} …)`; the 1-arity transducer forms closed
  `(into [] (map f) …)`. `into` went ◐ → ✓ and the sample went 115 → 116.
- **The prediction that the sample would then be exhausted also held.** No
  slice outside the four upstream stubs fails now. That was the useful part
  of the ranking: it correctly said the end was one item away, rather than
  refilling itself indefinitely.
- **What the list did NOT predict, and could not have:** that building item
  #2 the obvious way would break item #1. The transducer arities were first
  added by rebinding `map` in the prelude — which upstream's own `map` slice
  (89) then shadowed globally, because a `defn` outlives its namespace. The
  ranked list reasons about *what* to build and is silent about *where*; this
  sample answered the second question by failing. See "What wave 27 found".
- **Honest note on `instance?`:** wave 27 shipped an `instance?` in the
  prelude, and slice 08's `instance?` still fails. Those are compatible — the
  slice is upstream's TODO stub, and fixtures are never edited. A future
  reader should not read the shipped prim as a contradiction of the recorded
  failure.


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

**Wave 26 closed the loop — the small-core-gaps backlog was built, and it
delivered, item by item.** Wave 25's honest admission was that its ranked
list had never been acted on. It has now. Checked against what wave 26
found:

- **`reduce-kv` (predicted → update-vals, update-keys): delivered exactly.**
  Both slices behave. No over- or under-claim.
- **`rem` (predicted → mod, take-nth's transducer): delivered exactly.**
  `mod` behaves and take-nth's xform (its body is `(rem i n)`) finally
  reduces correctly.
- **`float?` (predicted → double?): delivered exactly.** `double?` behaves.
- **`cpp/jank.runtime.bit_not` (predicted → bit-not): delivered exactly.**
  One registry row; the slice behaves.
- **Multi-coll `map` (predicted → mapv ◐→✓): delivered.** `mapv`'s
  multi-coll arities behave. But the list said nothing about `map`'s
  *1-arity transducer* form, which is still missing — and that is one of
  the two gaps now pinning `into`.
- **`transientable?` (predicted → into, update-vals, splitv-at, mapv):
  half delivered, one over-claim.** `update-vals`, `splitv-at`, and `mapv`
  all behave. But the list's headline claim — that `transientable?` would
  unblock `into` — was wrong: `into` is still ◐ because two *unlisted*
  prims are missing (`conj!`'s map-transient clause, `map`'s 1-arity). The
  predicate was necessary but not sufficient. This is exactly the kind of
  miss only measuring the actual slice surfaces.
- **`conj` 1-arity (predicted → the transduce-conj idiom): delivered.**
  `(conj coll)` now returns `coll`; the completing step works.

So of the seven wave-25 items, six delivered exactly as ranked and one
(`transientable?` → `into`) over-claimed by one slice. The two gaps that
actually pin `into` today were not on the wave-25 list at all — they are
new, and they are the whole of "What to build next". The ranked list
survived this contact; the new list is two one-liners, and the sample has
nothing else left to unlock.

## Keeping this honest

- The vendored fixtures carry a sha256 of their code portion; the test
  asserts it so any local edit silently voids the fidelity claim.
- If a slice ever *needs* an edit to load, that is a FAIL with the reason
  recorded — the fix goes into beam-lisp (`lib/`), never into the vendor.
- Big-bang loading of all 7795 lines is explicitly out of scope; the value
  is the per-slice, per-gap measurement above.

All 115 fully-behaving slices are exercised by `test/beam_lisp/jank_compat_test.exs`
and demonstrated end-to-end by `examples/jank_slice.bl` (unmodified jank
running on the BEAM, exit 0). `into` (99) is the one ◐ — its vector/reduce
and `take`-xform paths behave, but `(into {} …)` and `(into [] (map inc) …)`
still throw on the two prim gaps in "What to build next".
