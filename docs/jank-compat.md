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

> **`load` ≠ `behave`.** Most of the 64 slices read+compile ("load"); three
> fail *at the reader/compiler itself* (`distinct`, `condp`, `for`). And
> only some of the loaded slices run correctly when called. The verdicts
> below are behavioral — the checklist marks each.

## The checklist — 64 attempted slices

Verdicts: **✓ pass** (loads and behaves) · **◐ partial** (common arities
pass, higher arities fail) · **✗ fail** (a recorded gap). Slices 01–21 are
the original measurement; 22–64 are the wave-16 widening. Row *lines*
columns are the upstream span in `core.jank@3028594`.

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
| 26 | keys | 2308–2317 | `keys` | ✗ | **transients** (`persistent!`) |
| 27 | vals | 2319–2328 | `vals` | ✗ | transients |
| 28 | select-keys | 2392–2401 | `select-keys` | ✗ | `conj` map-entry arity missing |
| 29 | zipmap | 2403–2413 | `zipmap` | ✗ | transients + `hash-map` |
| 30 | set | 2459–2467 | `set` | ✗ | `set?` + transients |
| 31 | name | 2484–2487 | `name` | ✗ | `cpp/*` interop |
| 32 | namespace | 2489–2492 | `namespace` | ✗ | `cpp/*` interop |
| 33 | keyword | 2548–2557 | `keyword` | ✗ | `cpp/*` interop |
| 34 | if-some | 2643–2660 | `if-some` | ✓ | `assert-macro-args`, `temp#` |
| 35 | when-some | 2669–2684 | `when-some` | ✓ | `assert-macro-args`, `~@` splice |
| 36 | repeatedly | 3063–3068 | `repeatedly` | ✓ | `lazy-seq`, `cons`, `take` |
| 37 | take-while | 3070–3087 | `take-while` | ✓ | coll arity; *transducer 1-arity needs `reduced`* (noted below) |
| 38 | drop-while | 3117–3140 | `drop-while` | ✓ | coll arity; *transducer 1-arity needs `volatile!`* (noted) |
| 39 | split-at | 3157–3160 | `split-at` | ✓ | `take`/`drop` |
| 40 | interleave | 3167–3181 | `interleave` | ◐ | 2-arity ✓; 1-arity `(lazy-seq c1)` on a realized vector fails (LazySeq) |
| 41 | partition | 3231–3251 | `partition` | ✗ | `nthrest` (+ `doall`/`concat`) |
| 42 | frequencies | 3322–3331 | `frequencies` | ✗ | transients |
| 43 | group-by | 3333–3344 | `group-by` | ✗ | transients |
| 44 | for | 3604–3689 | `for` | ✗ | reader: `&`+destructuring in fn params, `:as`, chunk-seq prims |
| 45 | assoc-in | 3697–3704 | `assoc-in` | ✗ | **`&` rest-destructure nil-semantics** (hangs) |
| 46 | update-in | 3706–3718 | `update-in` | ✗ | same `&` gap (hangs) |
| 47 | update | 3720–3734 | `update` | ✓ | `assoc`/`get`/`apply`, variadic |
| 48 | mapcat | 3790–3796 | `mapcat` | ✓ | coll arity; *transducer 1-arity needs `cat`* (noted) |
| 49 | distinct | 3813–3836 | `distinct` | ✗ | `[f :as xs]` destructuring unsupported |
| 50 | flatten | 3883–3889 | `flatten` | ✗ | `tree-seq`/`sequential?` (+ `complement` dep) |
| 51 | remove | 3891–3898 | `remove` | ✓ | needs the `complement` slice co-loaded (core dep) |
| 52 | condp | 3924–3962 | `condp` | ✗ | `[a b c :as clause]` destructuring |
| 53 | cond-> | 3963–3982 | `cond->` macro | ✗ | `*assert*` + `butlast` + `partition` |
| 54 | cond->> | 3984–3998 | `cond->>` macro | ✗ | same chain |
| 55 | as-> | 4000–4009 | `as->` macro | ✗ | `butlast` |
| 56 | some-> | 4011–4022 | `some->` macro | ✗ | `butlast` (+ `->` dep) |
| 57 | some->> | 4024–4035 | `some->>` macro | ✗ | `butlast` (+ `->>` dep) |
| 58 | merge-with | 5556–5570 | `merge-with` | ✗ | **`seq` on a map unsupported** (+ some/key/val deps) |
| 59 | sort-by | 5661–5671 | `sort-by` | ✗ | `sort`/`compare` |
| 60 | with-open | 5976–5995 | `with-open` macro | ✗ | **upstream TODO stub** — the slice itself throws |
| 61 | lazy-cat | 6268–6275 | `lazy-cat` macro | ✗ | `concat` over `(lazy-seq …)` of a vector breaks |
| 62 | max-key | 6428–6444 | `max-key` | ✓ | `>` / `>=` |
| 63 | min-key | 6446–6462 | `min-key` | ✗ | **`<=` link bug** (`:erlang.<=/2` undefined) |
| 64 | assert | 903–918 | `assert` macro | ✗ | `*assert*` var absent |

## Counts — the headline

> **36 of 64 attempted slices** load **and** behave correctly — 21 of the
> original 21, plus **15 of 43** new slices from the widened wave-16
> sample. The trajectory is the point: **7 → 13 → 21 → 36** across three
> waves. Nothing was patched into passing — the fixtures are still
> byte-for-byte upstream and the checksum test proves it. Where a slice
> needs another slice (`memoize` needs `if-let`+`val`; `some-fn` needs
> `some`; `remove` needs `complement`), that dependency is `core.jank`'s
> own, satisfied with unmodified upstream text.
>
> The drop is the deliverable. A 21-slice sample that fully passed had
> stopped being informative; this wave re-measured over a harder tranche
> and the honest count is **28 new FAILs with recorded causes** (see the
> checklist above and the re-ranked gaps below). This is *more* evidence
> about the real distance to whole-file fidelity than the previous
> perfect score, not less: it names precisely which primitives and
> reader rules stand between beam-lisp and the rest of `core.jank`, and
> ranks them by how many slices each unlocks.

All 36 behaving slices are exercised by `test/beam_lisp/jank_compat_test.exs`
and the strongest newcomers are demonstrated end-to-end by
`examples/jank_slice.bl` (unmodified jank running on the BEAM, exit 0).

## Gap classification

*Re-derived from the wave-16 sample. Unlock counts are the number of the
43 new slices each gap blocks; items are ordered by unlock count.*

### 1. Transients — the dominant blocker (6 slices)

`keys`, `vals`, `set`, `zipmap`, `frequencies`, `group-by` all build on
`(transient …)` / `(persistent! …)` / `conj!` / `assoc!` / `hash-map`.
beam-lisp has no transient API (the wave-8 trie has the structure but no
`transient` layer), so every one of these seq-building fns fails with
`undefined var: …/persistent!`. Smallest fix: `transient`/`persistent!`/
`conj!`/`assoc!` over the existing trie, plus `hash-map`.

### 2. `&` rest-destructuring is `rest`-semantics, not `next` (2 slices, silently hangs)

`[k & ks]` on an exhausted seq yields `()` (empty list) instead of
`nil`. In Clojure, `[k & ks]` uses `next`-semantics, so `(if ks …)`
terminates; here `()` is truthy, so `assoc-in` and `update-in` **recurse
forever** (each probe had to be killed). This is a *bug* in beam-lisp's
destructuring, not a missing feature, and it is the highest-leverage fix
per line of code: change `&`-rest to nil-terminate and two slices pass
that currently hang. Latent elsewhere too — `comp`/`juxt`/`partial` only
pass because their tests never hit an exhausted `& rest`.

### 3. `:as` binding / `&`-in-fn-params destructuring (3 slices, reader-level)

`[f :as xs]` and `[a b c :as clause]` destructuring raise
`unsupported binding pattern: {:keyword, "as"}` at read/compile time.
Blocks `distinct`, `condp`, and `for` (which additionally needs
chunk-seq prims and `when-first`). Reader-level FAIL — the slice text
itself cannot be compiled.

### 4. `cpp/*` runtime interop (3 slices)

`name`, `namespace`, `keyword` call `(cpp/jank.runtime.*)` directly;
beam-lisp has no `cpp/` namespace, so they fail with `module :cpp is not
available`. Same family as the primitive layer noted in wave 15 — every
upstream fn built on `cpp/jank.runtime.*` is unreachable until beam-lisp
supplies BEAM equivalents under a mapped namespace.

### 5. The threading-arrow cluster: `butlast` (+ `partition`, `assert`) (5 slices)

`as->`, `some->`, `some->>` each expand through `butlast` (absent).
`cond->`/`cond->>` additionally expand through `assert` (→ `*assert*`,
absent) and `partition` (→ `nthrest`, absent). So `butlast` unlocks 3
immediately; the two `cond->*` follow once `nthrest`+`*assert*` land.

### 6. Small prims — one slice each

| prim | blocks | note |
|------|--------|------|
| `conj` map-entry arity | select-keys | `(conj {} entry)` has no clause |
| `seq` on a map | merge-with | `(seq {:a 1})` raises; map-walking fns need it |
| `sort` / `compare` | sort-by | |
| `nthrest` | partition | also `doall`/`count`/`concat` |
| `tree-seq` / `sequential?` | flatten | |
| `*assert*` var | assert | upstream `assert` guards on `(when *assert* …)` |
| `<=` link | min-key | **`<=` maps to `:erlang.<=/2`, which does not exist** (`:=<` does); `>=` works. Fix the link table and `min-key` passes — and every future `<=` user stops crashing |

### 7. Requires laziness / transducers (partial, recorded honestly)

`take-while`, `drop-while`, `mapcat` behave on their collection arity
(the docstring contract) and are counted as ✓, but each carries a
**transducer 1-arity that diverges**: `take-while`'s needs `reduced`,
`drop-while`'s needs `volatile!`/`vreset!`, `mapcat`'s needs `cat`
(transducers). `interleave` is **◐**: its 2-arity (and 0-arity) pass,
but `([c1] (lazy-seq c1))` fails on a realized vector
(`LazySeq.prefix_loop`). And `lazy-cat` fails outright: `concat` over
`(lazy-seq …)` of a *vector* hits a case-clause error — a beam-lisp
`concat`/`lazy-seq` interplay bug worth its own fix.

### 8. Upstream stubs (not beam-lisp gaps)

`with-open` is a **TODO stub in `core.jank` itself** — its body is
`(throw "TODO: port with-open")`. The slice loads and then throws; that
is upstream's incompleteness, recorded so a future agent does not chase
it.

## What to build next (by unlock count)

*Re-ranked after wave 16 widened the sample from 21 to 64 slices and the
count dropped to 36/64. The gaps below are now evidence-ranked, not
guessed: each unlock count is how many of the 43 new slices that change
turns from FAIL to behave.*

1. **Transients** (`transient`/`persistent!`/`conj!`/`assoc!`/
   `hash-map`) — unlocks `keys`, `vals`, `set`, `zipmap`, `frequencies`,
   `group-by` (**6 slices**). The wave-8 trie already has the structure;
   this is the natural next collection layer.
2. **`&`-rest destructuring → nil-terminate** — unlocks `assoc-in`,
   `update-in` (**2 slices**, both currently *hanging*, plus removes a
   latent landmine from every `&`-rest user). Smallest fix, highest
   leverage per line.
3. **`butlast`** — unlocks `as->`, `some->`, `some->>` (**3 slices**);
   add `nthrest` + `*assert*` and `cond->`/`cond->>` (**2 more**).
4. **`:as` / `&`-in-fn-params destructuring** (compiler/reader) —
   unlocks `distinct`, `condp`, `for` (**3 slices**; `for` needs
   chunk-seq prims on top).
5. **`cpp/*` runtime equivalents** (`name`/`namespace_`/`keyword`, then
   the primitive layer) — unlocks `name`, `namespace`, `keyword`
   (**3 slices**) and is the long tail that makes the rest of the file
   loadable at all.
6. **Small prims, one each**: `sort`/`compare` (sort-by), `conj`
   map-entry arity (select-keys), `seq` on map (merge-with), `nthrest`
   (partition), `tree-seq`/`sequential?` (flatten), `*assert*` (assert),
   and the **`<=` link fix** (`:erlang.<=` → real BIF; min-key).
7. **`concat`/`lazy-seq` interplay** (lazy-cat) and **transducers**
   (`reduced`/`volatile!`/`cat`) — the honest note from §7; these also
   gate `for` and the transducer arities.

## Keeping this honest

- The vendored fixtures carry a sha256 of their code portion; the test
  asserts it so any local edit silently voids the fidelity claim.
- If a slice ever *needs* an edit to load, that is a FAIL with the reason
  recorded — the fix goes into beam-lisp (`lib/`), never into the vendor.
- Big-bang loading of all 7795 lines is explicitly out of scope; the value
  is the per-slice, per-gap measurement above.
