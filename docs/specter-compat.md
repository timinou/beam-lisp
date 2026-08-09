# Specter compatibility measurement

**Thesis under test:** Specter is the settled north star for beam-lisp's
optics story. beam-lisp ships its own `priv/optics.bl` — a
van-Laarhoven-flavored lens/traversal library — but that is a beam-lisp
design, not the thing users of Clojure reach for. Clojure's optics
de-facto standard is *Specter*, and the question this document measures
is the honest one: **how far is beam-lisp from running the real
Specter, unmodified?**

This is the jank fidelity programme pointed at a library instead of a
stdlib. Same rules, same honesty: loading a slice of the real Specter
and calling it with Specter's own examples is the measurement. A low
score is a *successful measurement* — it names precisely what to build
next, ranked by how many slices each gap unlocks.

## Headline — measured 2026-08-08

> **23 of 31 slices load. 8 of 31 load *and* behave.**
>
> The load number is flat at **23 → 23**, but the behave number moved
> this time: **4 → 8**, doubled. The previous wave's verdict — "the
> syntax wave closed the load gap but barely moved behavior" — is no
> longer the story. This wave moved behavior by exactly the mechanism
> the old ranking promised: the missing core prims (`into`, `keys`,
> `type`, `vec`, `subs`, `sequence`, …) plus the quoted-symbol
> destructure key were the actual gate, and four slices that could not
> run now compute right answers (03, 04, 17, 31).
>
> The load number being flat is *not* stasis — it is two opposing
> moves that cancel. The destructure fix brought **04 and 05 in**, and
> the loud unresolved-qualified-name fix (the "phantom sentinel"
> fix, which landed with this wave) pushed **11 out**: slice 11's
> `(def srange-transform i/srange-transform*)` used to *silently*
> compile into a vacuous function reference; it now fails honestly at
> load, because `i/srange-transform*` is not vendored. **That is not a
> regression — it is the measurement becoming trustworthy.**
>
> The eight behaving slices are: the two protocol definitions (01, 02),
> the `nav`/`richnav` macro stack (04), `determine-params-impls` (03),
> the path-analyzer records + `dynamic-param?` (31), `static-path?`/`wrap-dynamic-nav` (17),
> and two pure helpers (12, 16). **A navigator is now constructible by
> the real `nav` macro and dispatches correctly end to end.** Every
> remaining *navigator that runs* is still blocked — but now on
> Specter's engine (`i/NONE`, the compiled-path cache, the exec
> interop), not on beam-lisp's grammar.

### Trajectory across measurements

| measurement | load | behave | notes |
|---|:--:|:--:|---|
| prior (syntax wave) | 11 | 1 | the syntax list was the wall |
| last full (2026-08-07) | 23 | 4 | syntax done; impl machinery + prims named as the wall |
| **this (wave 27, 2026-08-08)** | **23** | **8** | prims + destructure fix landed; phantom-sentinel fix makes the rest honest |

## Source & provenance

| | |
|---|---|
| repo | `https://github.com/redplanetlabs/specter` |
| files | `src/clj/com/rpl/specter/{protocols,impl,navs}.cljc`, `macros.clj`, `specter.cljc` |
| commit | `6119462a4d959834f2d78a6183d74608bf08ab52` |
| license | Apache-2.0 (see `LICENSE` in the specter repo) |
| vendored | `test/fixtures/specter/slice_*.bl` — each block byte-for-byte upstream, with file/URL/commit/line-range/sha256 in a header comment |

Measured shape of the source (all 3,379 lines):

| file | lines | forms |
|------|-------|-------|
| `protocols.cljc` | 27 | 3 defprotocol |
| `macros.clj` | 54 | 4 defmacro |
| `navs.cljc` | 786 | 1 defrecord, 7 defprotocol, 7 extend-protocol, 66 reader conditionals |
| `impl.cljc` | 1,004 | 1 deftype, 11 defrecord, 4 defprotocol, 57 reader conditionals |
| `specter.cljc` | 1,508 | 2 defrecord, 3 defprotocol, 14 extend-type, 35 defmacro, 16 reader conditionals |

> **`.bl` vs `.cljc`.** The fixtures use `.bl` for consistency with the
> jank fixtures, even though the source is `.cljc`. The extension is
> cosmetic — the harness evaluates the text directly. Reader-conditionals
> (`#?`) are preserved verbatim inside a slice, and the reader now reads
> them (selecting the `:clj` branch); one slice (29) still cannot load
> because its `#?(:bb … :cljs …)` block has **no** `:clj` branch — which
> is *correct* reader behavior, identical to Clojure (see below).

## Method

1. **Slice.** Copy each candidate block *verbatim* out of the Specter
   source into `test/fixtures/specter/slice_NN_<name>.bl`. The slices
   span the real surface: protocol definitions, simple navigators,
   entry-point macros, plus the `defrecord`-heavy path-analyzer and the
   `deftype`/reader-conditional `MutableCell` block.
2. **Load.** The harness wraps each slice in a throwaway `(ns …)` and
   `Compiler.eval_string`s it. The vendored `(ns com.rpl.specter.impl …)`
   header line is excluded because the harness provides its own
   namespace. A slice that needs a local edit is a **FAIL with a
   recorded reason** — never a patch. The vendored text is never
   rewritten (a checksum test guards that).
3. **Behave.** Each loaded slice is then *called* with an
   upstream-shaped argument. Where a slice calls a sibling in the
   vendored set, the sibling is co-loaded into its canonical upstream
   namespace and aliased as upstream does — that is Specter's own
   internal dependency, not a beam-lisp gap. Slices that need
   *non-vendored* upstream machinery (`i/NONE`, `doseqres`, `eachnav`,
   `PosNavigator`, the `path` macro, `compiled-traverse*`, `for`,
   `vary-meta` variadic, `^Tag`-meta let bindings) are recorded as
   load-only with that named as the blocker.

> **`load` ≠ `behave`, and this wave narrowed the gap for the first
> time.** 15 of the 23 loaded slices still cannot run — but every one
> of them now *fails loudly when called*, naming its exact blocker,
> instead of returning a plausible-but-wrong answer. That is the
> phantom-sentinel fix working, and it is a precondition for trusting
> any future behavior credit.

## The checklist — 31 attempted slices

Verdicts: **✓ pass** (loads *and* behaves) · **◐ load-only** (reads and
compiles, fails loudly when called) · **✗ fail** (a recorded load
gap). Row *lines* are the upstream span at the commit above.

| # | slice | upstream | defines | verdict | blocker |
|---|-------|----------|---------|:-------:|---------|
| 01 | rich-navigator-protocol | protocols.cljc 3–18 | `RichNavigator` defprotocol | **✓** | — reify + dispatch of both methods work |
| 02 | collector-implicitnav | protocols.cljc 21–27 | `Collector`, `ImplicitNav` | **✓** | — both dispatch |
| 03 | determine-params-impls | macros.clj 6–11 | `determine-params-impls` | **✓** | — `into`/`keys` landed; groups impls into a method-keyed map |
| 04 | richnav+nav | macros.clj 14–32 | `richnav`, `nav` | **✓** | quoted-symbol destructure key **fixed** — empty-params navigators construct & dispatch |
| 05 | defnav+defrichnav | macros.clj 34–54 | `defnav`, `defrichnav` | ◐ | macros *define*; expansion needs `for` + `vary-meta` variadic (see taxonomy) |
| 06 | not-selected?/selected? | navs.cljc 15–23 | `not-selected?*`, `selected?*` | ◐ | `i/compiled-select-any*` + `i/NONE` (impl) — loud at call |
| 07 | all-select | navs.cljc 26–28 | `all-select` | ◐ | `doseqres` + `i/NONE` (not vendored) |
| 08 | queue? reader-cond | navs.cljc 30–37 | `queue?` | ◐ | `:clj` branch = `instance? clojure.lang.PersistentQueue` — Java class, untestable on BEAM |
| 09 | void-kv-pair + non-transient | navs.cljc 43–55 | `void-transformed-kv-pair?`, `non-transient-map-all-transform` | ◐ | `i/NONE` (loud); `reduce-kv` now present |
| 10 | not-NONE? + all-transform | navs.cljc 57–69 | `not-NONE?`, `all-transform-list/-record` | ◐ | `i/NONE` (loud); `sequence` now present |
| 11 | srange-select | navs.cljc 395–402 | `srange-select`, `srange-transform` | ✗ | **`(def srange-transform i/srange-transform*)`** — eager def now fails loudly (non-vendored); `srange-select` itself is prim-clean |
| 12 | extract-basic-filter-fn | navs.cljc 405–418 | `extract-basic-filter-fn` | **✓** | self-contained |
| 13 | if-select + if-transform | navs.cljc 421–437 | `if-select`, `if-transform` | ◐ | `i/exec-select*` expansion hits `^Tag`-meta let binding (28) |
| 14 | do-keypath-transform | navs.cljc 689–695 | `do-keypath-transform` | ◐ | `i/NONE` + `i/srange-transform*` (loud); `dissoc` now present |
| 15 | keypath* + must* | navs.cljc 697–721 | `keypath*`, `must*` | ✗ | `defrichnav` expansion → `vary-meta` variadic (2-arity only) |
| 16 | insert-before-index-list | navs.cljc 755–758 | `insert-before-index-list` | **✓** | self-contained |
| 17 | static-path + wrap-dynamic | specter.cljc 35–53 | `static-path?`, `wrap-dynamic-nav` | **✓** | `type` landed → `dynamic-param?` (31) → `static-path?` works; `wrap-dynamic-nav` still needs `i/comp-paths*` |
| 18 | select macro | specter.cljc 349–354 | `select` | ◐ | `path` macro + `i/compiled-select*` (impl) |
| 19 | select-any macro | specter.cljc 373–379 | `select-any` | ◐ | `path` + `i/compiled-select-any*` |
| 20 | transform macro | specter.cljc 386–392 | `transform` | ◐ | `path` + `i/compiled-transform*` |
| 21 | setval macro | specter.cljc 409–413 | `setval` | ◐ | `path` + `i/compiled-setval*` |
| 22 | comp-paths | specter.cljc 516–520 | `comp-paths` | ◐ | `i/comp-paths*`; `vec` now present |
| 23 | ALL | specter.cljc 717–725 | `ALL` nav | ✗ | `defnav` expansion → `for` missing |
| 24 | MAP-VALS | specter.cljc 740–749 | `MAP-VALS` nav | ✗ | `defnav` expansion → `for` missing; also `doseqres` + `n/map-vals-transform` |
| 25 | FIRST + LAST | specter.cljc 767–777 | `FIRST`, `LAST` | ✗ | `n/PosNavigator`, `n/get-last`/`update-last` (non-vendored navs) |
| 26 | srange | specter.cljc 793–801 | `srange` nav | ✗ | `defnav` expansion → `for`; non-empty params also need `i/direct-nav-obj` |
| 27 | keypath | specter.cljc 989–993 | `keypath` | ✗ | `eachnav` + `n/keypath*` (non-vendored navs) |
| 28 | exec-select/transform | impl.cljc 99–127 | `exec-select*`, `exec-transform*` macros | ◐ | expansion emits `(let [^RichNavigator g …])` — `^Tag`-meta let binding unsupported |
| 29 | mutable-cell deftype | impl.cljc 222–273 | `MutableCell` | ✗ | `#?(:bb … :cljs …)` — **no `:clj` branch** (correct) |
| 30 | compiled-select/transform | impl.cljc 372–441 | `compiled-select*` … `terminal*` | ◐ | expands `exec-transform*` → `^Tag`-meta binding; also `mutable-cell`, `compiled-traverse*`, `NONE` |
| 31 | defrecord path forms | impl.cljc 449–474 | `LocalSym` … `dynamic-param?` | **✓** | records construct; `type` landed → `dynamic-param?` classifies correctly |

**Counts.** 23 load; **8 behave** (`✓`: 01, 02, 03, 04, 12, 16, 17,
31); 8 fail to load (11, 15, 23, 24, 25, 26, 27, 29); 15 load but do
not behave (05, 06, 07, 08, 09, 10, 13, 14, 18, 19, 20, 21, 22, 28,
30).

## The interesting finding: behavior moved this time

The previous wave's whole point was that closing the syntax list did
*not* move behavior (1 → 4, and three of those were protocol/`defn-`
fixes). This wave, the old ranking's promised mechanism finally paid
off: **the missing core prims were the gate, and behavior doubled
(4 → 8).**

The four new behaving slices and their unlock:

| slice | unlocked by | what it does now |
|-------|-------------|------------------|
| 03 | `into` + `keys` | `determine-params-impls` groups the `nav` macro's impl list into a method-keyed map |
| 04 | quoted-symbol destructure key | the `nav`/`richnav` macro stack expands; an empty-params navigator constructs via `reify` and dispatches `select*`/`transform*` correctly |
| 17 | `type` → `dynamic-param?` (31) | `static-path?` recurses a path and correctly rejects dynamic-path records |
| 31 | `type` over records | `dynamic-param?` classifies `DynamicVal`/`DynamicPath`/`DynamicFunction` vs plain values |

Crucially, **04 was the destructure fix** (wave 27 item #1), and 03,
17, 31 were the **prims** (item #2). The two promises that previously
under-delivered — `reify` unlocking zero navigator slices, `defn-`
holding only for load — landed here because the gate was one level
earlier (the macro's destructure) and the prims underneath it
(`into`/`keys`/`type`).

But the other half of the story is that **15 of 23 loaded slices still
cannot run**, and they now *fail loudly* when called. That list is
blocked on Specter's engine — `i/NONE` (06, 09, 10, 14), the
`i/compiled-*` family + `path` (18–21), `i/exec-*` expansion (13, 28,
30), `doseqres` (07), `i/srange-transform*` (14), `i/comp-paths*`
(22). The prims were necessary and are now in place; the impl
machinery is the dominant remaining wall.

## The phantom sentinel — resolved, and it changed the score

The prior measurement called out a silent miscompilation: an
unresolved qualified name (`i/NONE` with no `i` alias) compiled into a
zero-argument function reference — not an error, not a value — so
NONE-detection silently never fired and a load-only slice could *look*
like it worked. That made the whole load-vs-behave line untrustworthy.

**Wave 27 fixed this** (loud unresolved-qualified-name). Verified this
measurement:

```
(defn g [] (i/NONE))        ; loads
(g)                          ; ERROR "module :i is not available"  ← loud, at call
(fn? i/NONE)                 ; ERROR unresolved qualified name (eager)
(def x i/NONE)               ; ERROR at load (eager def value)
```

The consequences, both good:

1. **The measurement is now honest.** Every `i/*`-dependent slice that
   previously "ran with a vacuous sentinel" now *raises* when called.
   No more verdicts that could be silently wrong. The old standing
   caveat on `i/*` verdicts is withdrawn — loud failure is the new
   baseline.
2. **Slice 11 dropped out of the load set**, and it is the right call.
   `(def srange-transform i/srange-transform*)` is an eager top-level
   `def` of an unvendored impl function. It *used* to load as a phantom;
   it now fails loudly. `srange-select` itself (the vendored part) is
   prim-clean and would behave if the slice could load — but the slice
   as a whole cannot, and it is recorded as a load FAIL against the
   non-vendored `i/srange-transform*`. This is why the headline load
   number is flat (23 → 23): 04/05 came in, 11 went out.

## Load-failure taxonomy (the remaining 8)

*Unlock counts are slices each gap blocks; ordered by current relevance.*

### 1. The macro-stack core gaps — `for` and `vary-meta` variadic (4 slices)

The quoted-symbol destructure wall (last wave's #1) is **gone** — 04
loads and behaves. But the *next* link in the stack was hiding behind
it. `defnav` (slice 05) builds its helpers with a `for` comprehension,
and `defnav`/`defrichnav` stamp `:arglists` meta with `(vary-meta name
assoc :arglists …)` — the variadic form. beam-lisp has **neither**:

- `for` (list comprehension) is **not in the prelude at all** —
  `(for [x [1 2]] (* x 2))` → `undefined var: for`. (The jank
  fixture *defines* `for`; Specter assumes core `for`.) Blocks `defnav`
  expansion → **23, 24, 26**.
- `vary-meta` is **2-arity only** — `(vary-meta obj f)` works, but the
  Clojure form `(vary-meta obj f & args)` → "arity 2 called with 4
  arguments". Blocks `defrichnav` expansion → **15** (and `defnav`, so
  23/24/26 share it).

Both are small, self-contained core gaps, and they are the honest
successor to last wave's destructure wall: **the macro stack is gated
one level deeper than the last ranking said.** Even after both land,
23 is the only one of the four that would *load* (empty params); 15/26
have non-empty params and need `i/direct-nav-obj` (impl) too, and 24
needs `doseqres` + `n/map-vals-transform`. None would *behave* without
the engine — see the re-rank.

### 2. Non-vendored navs/impl helpers (3 slices)

`FIRST`/`LAST` (25) reference `n/PosNavigator`, `n/get-last`/
`update-last`; `keypath` (27) references `eachnav`, `n/keypath*`;
`srange-transform` (11) references `i/srange-transform*`. All live in
`navs.cljc`/`impl.cljc` outside the vendored 31. They are upstream
internal deps, not beam-lisp gaps, and now they *fail loudly* rather
than phantom-load.

### 3. A reader conditional with no matching branch (1 slice — correct)

Slice 29 (`MutableCell`) is `#?(:bb … :cljs …)`: under `:clj` reader
features it has no branch, so the reader correctly raises *no
conditional matching* — exactly as real Clojure would. On `:clj`,
`MutableCell` is a Java class (`com.rpl.specter.MutableCell`), not a
beam-lisp form. This is a **correct measurement, not a gap**: the
slice genuinely cannot be read as `:clj` source. Its `mutable-cell`/
`get-cell`/`set-cell!` functions are also `:clj`-branch Java interop
(`.get`/`.set`), untestable on the BEAM.

## Prediction vs. outcome — the check the list is owed

The last ranking made three promises for wave 27. Here is what
actually happened:

| predicted | shipped? | outcome |
|---|---|---|
| **#1 quoted-symbol destructure key → 5 slices** (04 direct; 15/23/24/26 transitive) | yes | **Half materialized.** 04 unlocked at **load *and* behave** — the empty-params `nav`/`richnav` reify path constructs a navigator and dispatches correctly, the first working navigator from the macro stack. 05 also loads (was implied). But **15/23/24/26 did not unlock at load**: their blocker moved to `for` + `vary-meta` variadic in the `defnav`/`defrichnav` *macro bodies* — the real wall was one level deeper than the destructure. And none of the four would behave without the engine. |
| **#2 ten prims → prerequisite for behavior tests of 10 of the 19 load-only slices; cheapest way to move behave** | yes | **Materialized at behave.** 4 → 8. `into`/`keys` (03), `type` (17, 31), and the `nav` stack (04, whose `determine-params-impls` needs `into`/`keys`). But the "10 of 19" was an **over-promise**: the prims are now present, yet the other load-only slices are blocked on Specter's *impl machinery*, not on prims. The prims were necessary and are done; they were never sufficient. |
| **#3 loud unresolved-qualified-name** | yes (landed earlier) | **Materialized, and it re-shaped the score.** The phantom is gone; every `i/*` client now fails loudly. Directly cost slice 11's load (honest regression), and made the other 15 load-only verdicts trustworthy. This is the fix that lets behave credit be believed at all. |

**Verdict.** Two of three promises held where it counted, and the
third (transitive unlock of 15/23/24/26) mis-named the gate *again* —
the previous wave blamed the destructure, and this wave shows the real
blocker is `for` + `vary-meta` variadic one step deeper. That is
precisely the mis-attribution this section exists to catch: **the
macro stack is gated by core forms, not by the macro's own grammar.**
The behave number did move this time (4 → 8), so item #2's core
promise — the prims are the cheapest way to move behavior — finally
held.

## What to build next — re-ranked for *behavior*

*Ordered by behavioral yield, not load yield. Each item names the axis
it moves, and distinguishes beam-lisp gaps from Specter's engine.*

**Beam-lisp gaps (buildable, mostly load-yield this wave):**

1. **`for` (list comprehension)** — missing core form. Unblocks the
   `defnav` macro body → **23/24/26 load** and makes slice 05's
   `defnav` usable. Also a general stdlib hole every Clojure program
   touches. A standard `for` compiles to nested `loop`/`lazy-seq`; it
   is the natural companion to the already-working jank fixture.
2. **`vary-meta` variadic** (`(vary-meta obj f & args)`) — 2-arity
   only. Together with `for`, makes the whole macro stack (05) expand:
   **15 load** (defrichnav) and shares 23/24/26.
3. **`^Tag`-meta let bindings** (`(let [^Tag x …])`) — unsupported
   binding pattern. Unblocks the **exec interop bridge**: slice 28's
   `exec-select*`/`exec-transform*` macros emit exactly this form, so
   landing it unlocks 13 (if-select/transform expansion) and unblocks
   30's compile path.

> **Why these are load-gaps, not behave-gaps.** Even with all three,
> the navigators still cannot *run*: they bottom out in Specter's
> engine, which is the next item. The value of 1–3 is unblocking the
> macro stack so navigators *construct*; running them is the engine's
> job.

**Specter's impl machinery (the behave wall — the larger kind of work):**

4. **The compiled-path engine** — a real `i/NONE` sentinel value
   (instead of a loud error), the `path` macro, `i/compiled-select*`/
   `select-any*`/`transform*`/`setval*`, `i/comp-paths*`, and behind
   them `doseqres` (07, 24), `i/srange-transform*` (11, 14),
   `i/direct-nav-obj` (15, 26), `mutable-cell` + `compiled-traverse*`
   + `NONE` (30). This is the heart of Specter — the thing the
   entry-point macros (18–21) and the `i/NONE` clients (06, 09, 10,
   14) are actually waiting on. It is the difference between
   "navigators construct" (achieved this wave, via 04) and "navigators
   run" (the next behave jump).
5. **The exec interop** — accepting the `^Tag`-metad let symbol (gap
   #3) and `.select*`/`.transform*` on a reify'd `RichNavigator`.
   Unblocks 13 and 28, and is the bridge between constructed
   navigators and the entry-point macros.

**Upstream / non-vendored dependencies (a different and larger kind):**

6. **Non-vendored navs helpers** — `n/PosNavigator`, `n/get-last`/
   `update-last` (25), `eachnav` + `n/keypath*` (27), `n/map-vals-transform`
   (24), `all-transform` (23). These live in `navs.cljc` outside the
   vendored 31. Meaningful only after the engine (#4) and the macro
   stack (1–2) exist, since they are built on both.

**Correct-by-construction (no work, by design):**

7. **Slice 29** — `#?(:bb … :cljs …)` with no `:clj` branch *should*
   fail to read; on `:clj` it is a Java class. **Slice 08** — the
   `:clj` branch is `(instance? clojure.lang.PersistentQueue …)`, Java
   interop untestable on the BEAM. Neither is a beam-lisp gap.

**The honest trajectory.** The behave number finally moved — **4 → 8** —
because the prims and the destructure fix were, as ranked, the real
gate. But the curve is now flattening for a structural reason: the
remaining behave gap (15 load-only slices) is dominated by Specter's
**engine**, not by beam-lisp's grammar. The next honest wave is
#1 + #2 + #3 (the three core gaps, all small) to finish the macro
stack, then the much larger #4/#5 engine work — that is where the next
behave jump, when it comes, will come from. And #3 is a prerequisite
for the engine's own `exec-*` macros, so it is the natural hinge.

## Keeping this honest

- The vendored fixtures carry a sha256 of their code portion; the test
  asserts it so any local edit silently voids the fidelity claim. The
  checksum recipe is `grep -v '^;' test/fixtures/specter/<f>.bl |
  sha256sum | cut -d' ' -f1` (matching the jank fixtures' convention,
  including the trailing newline).
- If a slice ever *needs* an edit to load, that is a FAIL with the
  reason recorded — the fix goes into beam-lisp (`lib/`/`priv/`), never
  into the vendor.
- Whole-file loading of the 3,379 lines is explicitly out of scope, for
  the same reason as in jank-compat: the value is the per-slice,
  per-gap measurement.
- Behavior was tested with upstream's own usage (the `core_test.cljc`
  suite and the README/docstrings); a load-only verdict means the slice
  failed a genuine call, with the exact blocker named. Sibling co-loads
  are noted where they occurred (04 co-loads 01+03; 17 co-loads 31 into
  `com.rpl.specter.impl` and aliases `i`).
- **The phantom-sentinel caveat is withdrawn.** Unresolved qualified
  names now fail loudly (eager positions at load, function bodies at
  call), so every `i/*` verdict above is a clean failure — no vacuous
  sentinel, no silently-wrong behavior. This is the change that made
  the whole measurement trustworthy, and it is why 11's verdict flipped
  from load-only to load-FAIL.

**Newly-identified beam-lisp gaps (reported, not fixed — measurement
only):**

- **`for` missing** — `(for [x [1 2]] (* x 2))` → `undefined var: for`.
  Blocks `defnav` expansion (slices 23/24/26).
- **`vary-meta` 2-arity only** — `(vary-meta x assoc :k 1)` → "arity 2
  called with 4 arguments". Blocks `defrichnav`/`defnav` expansion
  (slice 15 and 23/24/26).
- **`^Tag`-meta let binding unsupported** — `(let [^C g v] …)` →
  "unsupported binding pattern: {:meta, …}". Blocks `exec-select*`/
  `exec-transform*` expansion (slices 13, 28, 30).
- **`defprotocol` with a leading docstring doesn't register its ns for
  `:require`** — a docstring-less `defprotocol` registers the ns, but
  the vendored `RichNavigator` (leading docstring) does not, so
  `(ns impl (:require […protocols :as p]))` fails. Harness-infrastructure
  detail; worth a look because it would block any future canonical
  co-load of the protocols ns.
