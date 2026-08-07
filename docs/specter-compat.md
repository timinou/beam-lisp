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

## Headline — measured 2026-08-07

> **23 of 31 slices load. 4 of 31 load *and* behave.**
>
> Load rose from **11 → 23** since the last full measurement, and behave
> from **1 → 4**. The two numbers now tell opposite stories, and that
> divergence *is* the finding: the syntax wave closed the load gap but
> barely moved behavior, because what remains is not special forms — it
> is Specter's **impl machinery** (`i/NONE`, the compiled-path cache, the
> exec interop) plus a handful of missing *core prims* (`type`, `into`,
> `vec`, `sequence`, `reduce-kv`, `subs`, `unreduced`, …) that the old
> taxonomy never listed.
>
> The four behaving slices are the protocol definitions (`RichNavigator`,
> `Collector`, `ImplicitNav`), one pure filter-path function, and one
> pure list-insertion helper. Every *navigator* still either fails to
> load (blocked on the `defnav` macro stack) or loads but cannot run.

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
   vendored set (e.g. `if-select` calls `i/exec-select*`), the sibling
   is co-loaded into its canonical upstream namespace and aliased as
   upstream does — that is Specter's own internal dependency, not a
   beam-lisp gap. Slices that need *non-vendored* upstream machinery
   (`i/NONE`, `doseqres`, `eachnav`, `PosNavigator`, the `path` macro,
   `compiled-traverse*`, …) are recorded as load-only with that named as
   the blocker.

> **`load` ≠ `behave`, and never more starkly than here.** 19 of the 23
> loaded slices cannot run. Worse than a clean failure, the ones that
> reference an unresolved qualified name — every `i/NONE` client — do
> not fail loudly at all: see *the phantom sentinel* below. The gap
> between the two numbers is not syntax; it is machinery.

## The checklist — 31 attempted slices

Verdicts: **✓ pass** (loads *and* behaves) · **◐ load-only** (reads and
compiles, fails when called — behavioral gap) · **✗ fail** (a recorded
load/compile gap). Row *lines* are the upstream span at the commit
above.

| # | slice | upstream | defines | verdict | blocker |
|---|-------|----------|---------|:-------:|---------|
| 01 | rich-navigator-protocol | protocols.cljc 3–18 | `RichNavigator` defprotocol | **✓** | — reify + dispatch of both methods work |
| 02 | collector-implicitnav | protocols.cljc 21–27 | `Collector`, `ImplicitNav` | **✓** | — both dispatch |
| 03 | determine-params-impls | macros.clj 6–11 | `determine-params-impls` | ◐ | `into`, `keys` missing |
| 04 | richnav+nav | macros.clj 14–32 | `richnav`, `nav` | ✗ | **quoted-symbol map-destructure key** (`'select*`) |
| 05 | defnav+defrichnav | macros.clj 34–54 | `defnav`, `defrichnav` | ◐ | `symbol` missing (`helper-name`); macros expand via 04 |
| 06 | not-selected/selected | navs.cljc 15–23 | `not-selected?*`, `selected?*` | ◐ | `i/compiled-select-any*` + `i/NONE` (impl) |
| 07 | all-select | navs.cljc 26–28 | `all-select` | ◐ | `doseqres` + `i/NONE` (not vendored) |
| 08 | queue? reader-cond | navs.cljc 30–37 | `queue?` | ◐ | `instance?` + `clojure.lang.PersistentQueue` (Java) |
| 09 | void-kv-pair + non-transient | navs.cljc 43–55 | `void-transformed-kv-pair?`, `non-transient-map-all-transform` | ◐ | `i/NONE`, `reduce-kv` |
| 10 | not-NONE? + all-transform | navs.cljc 57–69 | `not-NONE?`, `all-transform-list/-record` | ◐ | `i/NONE`, `sequence` |
| 11 | srange-select | navs.cljc 395–402 | `srange-select`, `srange-transform` | ◐ | `vec`, `subs`, `i/srange-transform*` |
| 12 | extract-basic-filter-fn | navs.cljc 405–418 | `extract-basic-filter-fn` | **✓** | self-contained |
| 13 | if-select + if-transform | navs.cljc 421–437 | `if-select`, `if-transform` | ◐ | `i/exec-select*` (28) can't expand: `^Tag`-metad let symbol + `.select*` |
| 14 | do-keypath-transform | navs.cljc 689–695 | `do-keypath-transform` | ◐ | `i/NONE` (phantom), `dissoc`, `i/srange-transform*` |
| 15 | keypath* + must* | navs.cljc 697–721 | `keypath*`, `must*` | ✗ | needs `defrichnav` (05) → stack blocked at 04 |
| 16 | insert-before-index-list | navs.cljc 755–758 | `insert-before-index-list` | **✓** | self-contained |
| 17 | static-path + wrap-dynamic | specter.cljc 35–53 | `static-path?`, `wrap-dynamic-nav` | ◐ | `i/dynamic-param?` (31) needs `type` |
| 18 | select macro | specter.cljc 349–354 | `select` | ◐ | `path` macro + `i/compiled-select*` (impl) |
| 19 | select-any macro | specter.cljc 373–379 | `select-any` | ◐ | same — `path` + `i/compiled-select-any*` |
| 20 | transform macro | specter.cljc 386–392 | `transform` | ◐ | `path` + `i/compiled-transform*` |
| 21 | setval macro | specter.cljc 409–413 | `setval` | ◐ | `path` + `i/compiled-setval*` |
| 22 | comp-paths | specter.cljc 516–520 | `comp-paths` | ◐ | `i/comp-paths*` + `vec` |
| 23 | ALL | specter.cljc 717–725 | `ALL` nav | ✗ | needs `defnav` (05) → stack blocked at 04 |
| 24 | MAP-VALS | specter.cljc 740–749 | `MAP-VALS` nav | ✗ | needs `defnav` (05) → stack blocked at 04 |
| 25 | FIRST + LAST | specter.cljc 767–777 | `FIRST`, `LAST` | ✗ | `n/PosNavigator` (non-vendored navs) |
| 26 | srange | specter.cljc 793–801 | `srange` nav | ✗ | needs `defnav` (05) → stack blocked at 04 |
| 27 | keypath | specter.cljc 989–993 | `keypath` | ✗ | `eachnav` (non-vendored navs) |
| 28 | exec-select/transform | impl.cljc 99–127 | `exec-select*`, `exec-transform*` | ◐ | expansion: `^Tag`-metad let symbol, `.select*` interop |
| 29 | mutable-cell deftype | impl.cljc 222–273 | `MutableCell` | ✗ | `#?(:bb … :cljs …)` — **no `:clj` branch** (correct) |
| 30 | compiled-select/transform | impl.cljc 372–441 | `compiled-select*` … `terminal*` | ◐ | `mutable-cell` (29), `compiled-traverse*`, `unreduced` |
| 31 | defrecord path forms | impl.cljc 449–474 | `LocalSym` … `dynamic-param?` | ◐ | records construct; `dynamic-param?` needs `type` |

**Counts.** 23 load; **4 behave** (`✓`); 8 fail to load (04, 15, 23, 24,
25, 26, 27, 29); 19 load but do not behave (03, 05, 06, 07, 08, 09, 10,
11, 13, 14, 17, 18, 19, 20, 21, 22, 28, 30, 31).

## The interesting finding: behavior barely moved

The prior measurement's implicit promise was that closing the syntax
list would move the *behavior* number. It did not. Load went **11 → 23**
— the syntax wave did its job — but behave went only **1 → 4**, and the
three new behaving slices (01, 02, 16) were unlocked by exactly two of
the shipped fixes: `defprotocol`'s leading docstring (01, 02) and
`defn-` (16). The other **19 loaded-but-not-behaving** slices are stuck
on things the syntax wave never touched.

Two walls, distinct in kind and both missing from the old taxonomy:

**1. Missing core prims.** `type` (blocks 17 and 31 via
`dynamic-param?`), `into` (03), `vec` (11, 22), `sequence` (10),
`reduce-kv` (09), `subs` (11), `unreduced` (30), `dissoc` (14),
`instance?` (08), `symbol` (05). These are small, cheap, and — because
Specter is *built* on them — each one is a gate to several slices once
the impl machinery is present.

**2. Specter's impl machinery.** `i/NONE` (06, 07, 09, 10, 14, 30),
`doseqres` (07), the `path` macro + `i/compiled-*` family (18–21),
`i/comp-paths*` (22), `i/exec-select*`/`exec-transform*` expansion
(13, 28), `mutable-cell`/`compiled-traverse*` (30), `i/srange-transform*`
(11, 14). This is the *larger kind of work* the load score always
tipped toward: it is not adding special forms, it is implementing the
engine those forms drive. `i/NONE` alone is a prerequisite of five
slices' genuine behavior.

The entry-point macros tell the whole story in miniature: `select`,
`select-any`, `transform`, `setval` **all load** (they compile their
backquote templates without resolving `path`/`i/compiled-*`), and
**none can run** — their expansion is the `path` caching machinery,
which is the compiled-path heart of Specter. Macro-heavy libraries load
far more readily than they run; that is this measurement in one line.

## The phantom sentinel — a hazard, not just a gap

Worth its own paragraph because it silently corrupts behavior
measurements. beam-lisp compiles an **unresolved qualified name** —
`i/NONE` in a namespace with no `i` alias — into a *zero-argument
function reference*, not an error and not a value. Probe:

```
(fn? i/NONE)            ;=> true
(identical? :x i/NONE)  ;=> false   (compares :x against a function)
(i/NONE)                ;=> ERROR  "module :i is not available"
```

So `not-selected?*`, `void-transformed-kv-pair?`, `do-keypath-transform`,
and the other `i/NONE` clients do not fail loudly at call time — they
run with a *vacuous sentinel*: `(identical? x i/NONE)` is false for
every real `x`, so NONE-detection never fires. That is worse than a
clean error: it turns a load-only slice into one that looks like it
might be working. **Before any further behavior credit is given, an
unresolved qualified name should be a loud error** (or resolve to a real
value), or the whole load-vs-behave line is untrustworthy. Every
`i/NONE` verdict above is `◐ load-only` *because* of this — even where
a happy path returned a plausible answer.

## Load-failure taxonomy (the remaining 8)

*Unlock counts are slices each gap blocks; ordered by current relevance.*

### 1. Quoted-symbol map-destructure key — the macro-stack wall (5 slices)

The `nav` macro destructures its impls on a literal quoted symbol:
`{[[_ s-sym s-next] & s-body] 'select* …}`. beam-lisp's map
destructuring rejects a quoted-symbol key at compile time, so slice 04
(`richnav`/`nav`) fails. This blocks **04 directly and 15/23/24/26
transitively**: `defnav`/`defrichnav` (05) expand into `nav`/`richnav`
(04), so every navigator built through the macro stack is unreachable.
Reify is *not* the blocker anymore (it works — wave 25); the gate is
one step earlier, in the macro's destructuring.

### 2. Non-vendored navs helpers (2 slices)

`FIRST`/`LAST` (25) reference `n/PosNavigator` and `keypath` (27)
reference `eachnav` — both live in `navs.cljc` outside the vendored 31.
They are upstream internal deps, not beam-lisp gaps, but they are also
*built on* the `defnav` stack, so they are double-blocked until #1 lands.

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

The previous ranking claimed `defn-` would unlock **7 slices** and
`reify` **6**. Both shipped. Here is what actually happened:

| predicted unlock | shipped? | outcome |
|---|---|---|
| `defn-` → 7 slices | yes | **Held only for load.** All 7 `defn-` slices now load (03, 05, 09, 10, 14, 16, 17), but just **1 of 7 behaves** (16). The helpers now parse and bind; they still call missing machinery when run. The prediction implicitly assumed loading ≈ behaving — exactly the assumption this measurement exists to falsify. |
| `reify` → 6 slices | yes | **Did not materialize.** `reify` works in isolation (wave 25), but all the navigator slices still fail to load — blocked one level *before* reify, in slice 04's quoted-symbol destructure. The ranking named the wrong gate: `reify` was necessary, but the actual wall was the `nav`/`richnav` macro body. |
| `#?` → 3 slices | yes | Materialized **for load**: 08 and 28 now load (29 correctly errors — no `:clj` branch). Not for behavior (08 needs `instance?`+Java; 28's expansion fails on `^Tag`-metad let symbol). |
| `defprotocol` docstring → 2 | yes | **Fully materialized** — 01 and 02 both load *and* behave. The one clean prediction. |
| `identical?` → 2 | yes | Necessary, not sufficient: 06 and 30 still load-only, blocked by compiled machinery rather than `identical?`. |
| `vec` → 2 | **no** | **Never shipped.** `vec` is still absent; 11 and 22 remain load-only. |
| `defrecord`/`deftype` → 1+ | yes | Partially: the path-analyzer records construct (31), but `dynamic-param?` needs `type`, and the `:clj` `MutableCell`/deftype surface isn't reachable at all. |
| `doseqres` → 1 | no | Not a beam-lisp prim — it is Specter's own util-macro; 07 still load-only. |
| `i/*` machinery | — | The wall, unchanged. |

**Verdict.** The ranking was right about *what* the cheap fixes were,
and *did* lift the load number as promised — but the count was taken on
the wrong axis. Every prediction was framed as "slices unlocked," and
unlocks were scored on load; the behave axis was never predicted. The
result is that the two big headline claims (`defn-` → 7, `reify` → 6)
were at best half-true, and the list entirely missed the missing core
prims. A ranked list that is never checked against outcomes is
astrology; this check says: predict **behave**, not load, and audit
prim availability before promising object-model wins.

## What to build next — re-ranked for *behavior*

*Ordered by behavioral yield, not load yield. Every item names the axis
it moves.*

1. **Quoted-symbol map-destructure key (slice 04)** — the single
   biggest load wall: unlocks **5 slices' load** (04, 15, 23, 24, 26)
   via the `defnav`/`defrichnav` stack. Reify is done; this is the
   one parser gap standing between the navigators and the macro stack.
   Cheap, contained, and it unblocks the *construction* half of Specter.
2. **The missing core prims** — `type` (17, 31), `into` (03), `vec`
   (11, 22), `sequence` (10), `reduce-kv` (09), `subs` (11),
   `unreduced` (30), `dissoc` (14), `instance?` (08), `symbol` (05).
   Each is a small, well-bounded function; together they are the
   prerequisite for any behavior test of 10 of the 19 load-only slices.
   This is the cheapest way to move the **behave** number.
3. **Loud unresolved-qualified-name** — turn the phantom `i/NONE`
   miscompilation into a real error (or a real value). This is a
   correctness hazard first: until it lands, no `i/*`-dependent slice
   can be trusted to fail honestly, and any future behavior credit is
   suspect. One-line compiler change with disproportionate payoff.
4. **Exec interop** — `(.select* nav …)` / `(.transform* nav …)` on a
   reify'd `RichNavigator`, plus accepting a `^Tag`-metad symbol as a
   `let` binding. Unblocks the `exec-select*`/`exec-transform*`
   expansion (13, 28) and is the bridge between the navigators (once #1
   lands) and the entry-point macros.
5. **The compiled-path machinery** — `i/NONE` sentinel, `doseqres`,
   `path` macro, `i/comp-paths*`, `compiled-traverse*`, `mutable-cell`
   (a BEAM analogue of the `:clj` Java cell). This unblocks the
   entry-point macros (18–21), `comp-paths` (22), `not-selected?*` (06),
   `all-select` (07) and is prerequisite to `compiled-*` (30). This is
   the *larger* kind of work — Specter's engine, not its grammar — and
   it is what the behave number is actually waiting on.
6. **Non-vendored navs helpers** (`PosNavigator`, `eachnav`) — for 25
   and 27; only meaningful after #1, since they are built on the
   `defnav` stack.

**The honest trajectory.** The syntax wall is nearly gone — 23 of 31
load — and that was real progress. But the behave number (4 of 31) is
the number that matters, and it is low for a structural reason: the
loaders that remain un-runnable are blocked on core prims and on
Specter's impl engine, both of which are different and larger kinds of
work than adding special forms. The cheapest honest next wave is #1 +
#2 + #3: unblock the macro stack, supply the missing prims, and make
the compiler fail loudly on unresolved names. That turns "19 slices
load but can't be trusted" into "loads and fails honestly" — and only
then is the impl-machinery work (#4, #5) worth starting.

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
  per-gap measurement. The dotted-ns shape was verified in isolation
  (`(ns com.rpl.specter.impl)` and `a.b.c/x` both resolve); the
  harness-provided `(ns specter.slice_NN)` follows the jank convention.
- Behavior was tested with upstream's own usage (the `core_test.cljc`
  suite and the README/docstrings); a load-only verdict means the slice
  failed a genuine call, with the exact blocker named. Sibling co-loads
  are noted where they occurred. The phantom-sentinel section above is
  the standing caveat on every `i/*`-dependent verdict.
