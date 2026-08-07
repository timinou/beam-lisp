# Specter compatibility measurement

**Thesis under test:** Specter is the settled north star for beam-lisp's
optics story. beam-lisp just shipped its own `priv/optics.bl` — a
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
> (`#?`) are preserved verbatim inside a slice, and one of the key
> findings is that beam-lisp's reader cannot read them.

## Method

1. **Slice.** Copy each candidate block *verbatim* out of the Specter
   source into `test/fixtures/specter/slice_NN_<name>.bl`. The slices
   are chosen to span the real surface rather than the easy surface:
   the protocol definitions, the simple navigators, the core entry
   points, plus — deliberately — a `defrecord`-heavy block, a `deftype`
   block, and a reader-conditional block that are *expected* to fail.
   Those failures are the point: they are the ranked gap list.
2. **Load.** The harness wraps each slice in a throwaway `(ns specter.slice_NN)`
   and `Compiler.eval_string`s it. The vendored `(ns com.rpl.specter.impl …)`
   header line is excluded because the harness provides its own
   namespace (the same convention as the jank fixtures). A slice that
   needs a local edit is a **FAIL with a recorded reason** — never a
   patch. The vendored text is never rewritten (a checksum test guards
   that).
3. **Behave.** Loading only proves the reader + compiler accept the
   form. Each loaded slice is then *called* with an upstream-shaped
   argument. This is where the real verdict lands.

> **`load` ≠ `behave`.** Ten slices read and compile ("load") but fail
> when called — the jank pattern in miniature. Notably the four
> entry-point *macros* (`select`/`select-any`/`transform`/`setval`)
> all load, because `defmacro` compiles its backquote template without
> resolving the vars it names; they fail at expansion, naming the
> absent `i/*` impl. And `not-selected?*` loads but can't run because
> its body reaches for `identical?` at call time.

## The checklist — 31 attempted slices

Verdicts: **✓ pass** (loads and behaves) · **◐ load-only** (reads and
compiles, fails at call — behavioral gap) · **✗ fail** (a recorded
load/compile gap). Row *lines* are the upstream span at the commit
above. `defn-` = private function definition.

| # | slice | upstream | defines | verdict | blocker |
|---|-------|----------|---------|:-------:|---------|
| 01 | rich-navigator-protocol | protocols.cljc 3–18 | `RichNavigator` defprotocol | ✗ | `defprotocol` can't skip a leading docstring |
| 02 | collector-implicitnav | protocols.cljc 21–27 | `Collector`, `ImplicitNav` | ✗ | same docstring gap |
| 03 | determine-params-impls | macros.clj 6–11 | `determine-params-impls` | ✗ | `defn-` missing |
| 04 | richnav+nav | macros.clj 14–32 | `richnav`, `nav` macros | ✗ | map destructuring can't key on `'select*` (and needs `reify`) |
| 05 | defnav+defrichnav | macros.clj 34–54 | `defnav`, `defrichnav` | ✗ | `defn-` missing |
| 06 | not-selected/selected | navs.cljc 15–23 | `not-selected?*`, `selected?*` | ◐ | loads; `identical?` missing at call |
| 07 | all-select | navs.cljc 26–28 | `all-select` | ◐ | loads; `doseqres` macro missing at call |
| 08 | queue? reader-cond | navs.cljc 30–37 | `queue?` | ✗ | **`#?` reader conditional** — reads `#?` as a bare symbol |
| 09 | void-kv-pair + non-transient | navs.cljc 43–55 | `void-transformed-kv-pair?`, `non-transient-map-all-transform` | ✗ | `defn-` missing |
| 10 | not-NONE? + all-transform | navs.cljc 57–69 | `not-NONE?`, `all-transform-list`, `all-transform-record` | ✗ | `defn-` missing |
| 11 | srange-select | navs.cljc 395–402 | `srange-select`, `srange-transform` | ◐ | loads; `vec` missing at call (`subs` too, for the string branch) |
| 12 | extract-basic-filter-fn | navs.cljc 405–418 | `extract-basic-filter-fn` | ✓ | self-contained |
| 13 | if-select + if-transform | navs.cljc 421–437 | `if-select`, `if-transform` | ◐ | loads; `i/exec-select*`/`i/exec-transform*` impl not vendored |
| 14 | do-keypath-transform | navs.cljc 689–695 | `do-keypath-transform` | ✗ | `defn-` missing |
| 15 | keypath* + must* | navs.cljc 697–721 | `keypath*`, `must*` | ✗ | `defrichnav` (→ `reify`) missing |
| 16 | insert-before-index-list | navs.cljc 755–758 | `insert-before-index-list` | ✗ | `defn-` missing |
| 17 | static-path + wrap-dynamic | specter.cljc 35–53 | `static-path?`, `wrap-dynamic-nav` | ✗ | `defn-` missing |
| 18 | select macro | specter.cljc 349–354 | `select` | ◐ | loads; expands to `path` + `i/compiled-select*` |
| 19 | select-any macro | specter.cljc 373–379 | `select-any` | ◐ | same — `path` + `i/compiled-select-any*` |
| 20 | transform macro | specter.cljc 386–392 | `transform` | ◐ | `path` + `i/compiled-transform*` |
| 21 | setval macro | specter.cljc 409–413 | `setval` | ◐ | `path` + `i/compiled-setval*` |
| 22 | comp-paths | specter.cljc 516–520 | `comp-paths` | ◐ | loads; `vec` missing at call (`(i/comp-paths* (vec apath))`) |
| 23 | ALL | specter.cljc 717–725 | `ALL` nav | ✗ | `defnav` (→ `reify`) missing |
| 24 | MAP-VALS | specter.cljc 740–749 | `MAP-VALS` nav | ✗ | `defnav` missing |
| 25 | FIRST + LAST | specter.cljc 767–777 | `FIRST`, `LAST` | ✗ | `def` init calls `n/PosNavigator` → **compiler crash** |
| 26 | srange | specter.cljc 793–801 | `srange` nav | ✗ | `defnav` missing |
| 27 | keypath | specter.cljc 989–993 | `keypath` | ✗ | `def` init calls `eachnav` → **compiler crash** |
| 28 | exec-select/transform | impl.cljc 99–127 | `exec-select*`, `exec-transform*` | ✗ | `#?` reader conditional |
| 29 | mutable-cell deftype | impl.cljc 222–273 | `MutableCell` | ✗ | `#?` reader + `defrecord`/`deftype` missing |
| 30 | compiled-select/transform | impl.cljc 372–441 | `compiled-select*` … `terminal*` | ◐ | loads; `mutable-cell`/`identical?`/`reduced`/`unreduced` missing at call |
| 31 | defrecord path forms | impl.cljc 449–474 | `LocalSym` … `DynamicFunction`, `dynamic-param?` | ✗ | `defrecord` missing |

## Counts — the headline

> **1 of 31 attempted slices** loads **and** behaves. 10 more load but
> fail when called; 20 fail at read/compile. That is a low number, and
> the honest one. Specter is *built* on the four things beam-lisp
> deliberately does not have — `deftype`, `defrecord`, `reify` (the
> whole Navigator-construction macro stack sits on it), and reader
> conditionals — plus `defn-`, which beam-lisp lacks entirely. Every
> single slice that fails does so for a nameable reason below.
>
> The single passing slice, `extract-basic-filter-fn` (a pure function
> that turns a filter path — one predicate or a collection of them —
> into one predicate), is telling in a good way: **Specter's pure
> functions run on beam-lisp today.** `fn?`/`coll?`/`every?`/`reduce`/
> `and`/`cond` are all present, and the slice behaves correctly. The
> gap is not the language's *expressiveness* — it is its *object model*
> (records/types/reify) and a handful of primitives (`defn-`,
> `identical?`, `vec`, `doseqres`, `#?`). This is a measurably narrower
> wall than the count alone suggests, because the object model is
> exactly the wave-11 exclusion the project already has on its roadmap.
>
> Also positive: **`defmacro` + backquote + `~`/`~@`/`x#` gensym all
> work** — the four entry-point macros (`select`/`select-any`/
> `transform`/`setval`) load as macro definitions. What fails is their
> *expansion*, which names `path` and the `i/*` compiled navigators.
> And **dotted namespaces work**: `(ns com.rpl.specter.impl)` compiles
> and `a.b.c/x` qualified references resolve. (`require`-from-disk is
> absent, but whole-file loading is explicitly out of scope here — the
> harness supplies the ns.)

## Failure taxonomy

*Unlock counts are the number of the 31 slices each gap blocks; items
are ordered by unlock count.*

### 1. `defn-` — private function definition — the dominant blocker (7 slices)

`determine-params-impls`, `defnav`/`defrichnav` helpers, `non-transient-*`,
`all-transform-list`/`-record`, `do-keypath-transform`,
`insert-before-index-list`, `static-path?` — all begin `(defn- …)`.
beam-lisp has **no `defn-`**: it is not a special form, so the reader
compiles `(defn- name …)` as a *call* to an undefined function and the
slice fails at load with `undefined var: …/defn-`. Every Specter
`defn-` helper is unreachable. Smallest fix in the whole list: treat
`defn-` as `defn` with a private var (or a one-line macro).

### 2. The Navigator-construction macro stack: `defnav`/`defrichnav`/`defdynamicnav` + `reify` (6 slices)

`ALL`, `MAP-VALS`, `FIRST`/`LAST`, `srange`, `keypath*`/`must*`, and
`keypath` all exist only through the `defnav`/`defrichnav` macros, which
build their navigators with `reify RichNavigator`. beam-lisp has
protocols and `extend-type`/`extend-protocol` but **no `reify`**, so the
macros themselves (`macros.clj`) don't compile and nothing that uses
them loads. Two slices (`FIRST`+`LAST`, `keypath`) fail even harder:
their `def` init calls `n/PosNavigator`/`eachnav` with no namespace
bound, and the compiler crashes with `no function clause matching in
compile_special/3` rather than a clean error. This is the single most
load-bearing feature for Specter — every simple navigator lives behind
it.

### 3. `#?` reader conditional (3 slices)

`queue?`, `exec-select*`/`exec-transform*`, and the `MutableCell` block
all carry `#?(:clj … :cljs …)` / `#?( :clj … :cljs …)`. beam-lisp's
reader does **not implement the reader conditional** — it reads `#?` as
a plain symbol, so `(#? :clj (defn queue? …) …)` compiles to a call of
a nonexistent `#?` function. Reader-level FAIL: the slice text itself
cannot be read as Clojure. (The reader *does* accept the text — it just
misreads it. `#?` is silently a symbol, which is worse than a loud
error.) A `.cljc` source leans on `#?` every few lines (66 in navs, 57
in impl), so no whole file can load until this lands.

### 4. `defprotocol` leading docstring (2 slices)

`RichNavigator`, `Collector`, `ImplicitNav` all carry a docstring
between the protocol name and the first method:
`(defprotocol RichNavigator "…" (select* …))`. beam-lisp's `defprotocol`
expects *every* form after the name to be a method; a leading string
raises. The whole 27-line `protocols.cljc` is blocked by this one small
parser gap — worth noting because these three protocols are the
foundation every navigator implements.

### 5. `identical?` missing (2 slices behaviorally, pervasive)

`not-selected?*`/`selected?*` and `compiled-select*`/`-transform*` fail
at call on `undefined var: …/identical?`. `identical?` is the linchpin
of Specter's `NONE` sentinel protocol — every transform path tests
`(identical? newv i/NONE)`. Almost every runtime slice in the set would
need it the moment it runs. A small BEAM identity/eq predicate would
unblock the two behavioral slices above and is prerequisite to nearly
everything in category 2/6 once those load.

### 6. `vec` missing (2 slices) — and `subs`

`comp-paths` (`(i/comp-paths* (vec apath))`) and `srange-select`
(`(-> structure vec (subvec …))`) both fail at call on `vec`.
`subs` is likewise absent for the string branch of `srange-select`.
Plain coercions.

### 7. `defrecord`/`deftype` missing (1 slice direct, strategic)

`LocalSym` … `DynamicFunction` (the path-analyzer records), `MutableCell`,
and — in navs — `SrangeEndFunction` are all `defrecord`s; the cljs
`MutableCell` is a `deftype`. These are the *deliberate wave-11
exclusions* already on the roadmap. Directly they block slice 31; more
importantly they are the substrate for the path macro's
precompilation/inline-caching analyzer, which is Specter's performance
heart. When `deftype`/`defrecord`/`reify` land, the load score jumps
far more than the 1 slice this category names.

### 8. `doseqres` macro missing (1 slice)

`all-select` and the `select*` bodies of `MAP-VALS`/`MAP-KEYS` use
`doseqres`, a util-macros helper that returns its accumulator. Not
vendored, so `all-select` loads but can't run. A trivial macro.

### 9. `i/*` impl namespace + `comp-paths*`/`exec-select*` machinery (4 macros + 2 slices)

The entry-point macros (`select`/`select-any`/`transform`/`setval`)
load but expand to `(path ~apath)` and `i/compiled-*` calls; the
`i/*` functions (`comp-paths*`, `exec-select*`, `compiled-select*`, …)
live in `impl.cljc` behind `deftype`/`defrecord`/`reify`. This is the
"big one" that makes `select`/`transform`/`setval` real — but it is
*downstream* of categories 2 and 7, so it is ranked last.

### 10. Map destructuring can't key on a quoted symbol (1 slice)

The `nav` macro destructures its impls with a map keyed on the literal
`'select*`:
`{[[_ s-structure-sym s-next-fn-sym] & s-body] 'select* …}`.
beam-lisp's map destructuring rejects a quoted-symbol key at
compile time. Macro-body edge case, unblocks the `nav` macro itself.

## What to build next

*Ranked by how many of the 31 slices each gap unlocks. The count is
deliberate: every item above the line is a prerequisite that buys
several slices; the big object-model items buy the most per unit of
design once they land.*

1. **`defn-` (private `defn`)** — unlocks **7 slices** with a one-line
   special-form/macro. The single highest-leverage fix in the sample;
   no design cost, and it also names a real language gap (beam-lisp
   currently has no way to mark a var private in source).
2. **`reify` + the `defnav`/`defrichnav`/`defdynamicnav` stack** —
   unlocks **6 slices** (`ALL`, `MAP-VALS`, `FIRST`/`LAST`, `srange`,
   `keypath*`/`must*`, `keypath`). Requires `reify` over the existing
   `defprotocol` machinery. This is the wall that keeps *every simple
   navigator* out; it should be the next object-model milestone. Also
   harden the two `compile_special` crashes (`FIRST`/`LAST`, `keypath`)
   so a missing qualifier is a clean error, not a case-clause failure.
3. **`#?` reader conditional** — unlocks **3 slices** and is the gate
   for reading *any* `.cljc` file (66 conditionals in navs alone).
   Read `#?(:clj … :cljs …)` selecting the `:clj` branch. Also make the
   current silent mis-read (bare symbol `#?`) a loud reader error until
   then.
4. **`defprotocol` leading docstring** — unlocks **2 slices** (the whole
   `protocols.cljc`) with a two-line parser tweak: skip a leading string
   form after the protocol name.
5. **`identical?`** — unlocks **2 behavioral slices** and is prerequisite
   to nearly every runtime slice once the object model lands (Specter's
   `NONE` sentinel protocol is built on it).
6. **`vec` (+ `subs`)** — unlocks **2 slices**; plain coercions.
7. **`defrecord`/`deftype`** — unlocks **1 slice** directly but is the
   *strategic* item: `MutableCell`, the path-analyzer records, and
   `SrangeEndFunction` are its direct consumers, and the path
   macro's precompilation cache (Specter's performance heart) is built
   on them. This is the wave-11 exclusion; landing it, with `reify`,
   is what would move the headline number materially.
8. **`doseqres`** — unlocks **1 slice**; a trivial macro.
9. **`i/*` compiled-navigator machinery** — unlocks the 4 entry-point
   macros to actually run (`select`/`select-any`/`transform`/`setval`)
   plus slices 13/30. *Downstream of 2 and 7* — the compiled select/
   transform/exec functions are implemented over `reify`'d navigators
   and the defrecord'd mutable cell.

**The honest trajectory.** The wall is real and named: object model
(`reify`/`defrecord`/`deftype`), `defn-`, `#?`, `defprotocol`
docstrings, and two missing prims. Items 1, 3, 4, 5, 6, 8 are small,
well-bounded, and buy **17 of the 31 slices between them**. Items 2 and
7 are the larger object-model work that turns "the pure functions run"
into "the navigators construct" — and that is exactly the leap from
1-of-31 toward something like a real Specter. The next wave should take
items 1–6 first (cheap, quantified), then commit to `reify` +
`defrecord`/`deftype` as the object-model milestone that makes the
entry points (18–21) and the navigators (23–27) land together.

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
- Specter's README/docstring examples were the call targets where a
  slice could run; the rest are recorded as load- or call-time gaps.
