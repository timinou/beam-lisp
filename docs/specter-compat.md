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

## Headline — measured 2026-08-09

> **25 of 31 slices load. 9 of 31 load *and* behave.**
>
> Both numbers moved this wave. Load went **23 → 25** (slices **23** and
> **24** — the empty-params `defnav` callers `ALL` and `MAP-VALS` — now
> load), and behave went **8 → 9** (slice **05** — `defnav`/`defrichnav`
> — now *behaves*: an empty-params `defnav` constructs a navigator that
> dispatches `select*`/`transform*` end to end). All five items shipped
> since the last measurement landed, and they were exactly the macro
> stack's remaining beam-lisp gaps: `for`, `vary-meta` variadic,
> `^Tag`-meta bindings, `declare`, and the `var_meta_ast/4` datum fix.
>
> The behave move is the meaningful one. Slice 05 is the first slice to
> cross the whole `defnav` macro stack and come out running — `for`
> builds the per-method helpers, `declare` forward-declares them, and
> `vary-meta` variadic stamps `:arglists` (the `var_meta_ast` fix makes
> that a datum, not a crash). The prediction that these would unblock
> the `defnav`/`defrichnav` stack materialized at LOAD (23, 24) and at
> BEHAVE (05).
>
> **The caveat this measurement raised has since been closed.** The
> measurement found that under a *faithful* upstream layout (each slice
> in its canonical namespace, macros used cross-ns as Specter does) the
> `defnav` stack did not unlock, because beam-lisp's syntax-quote did not
> namespace-qualify symbols. **That is now fixed** (see the section
> below), and the whole navigator macro stack — 01, 02, 03, 04, 05, 23,
> 24 — loads under the canonical cross-namespace layout. Every remaining navigator is
> now blocked either on that new-found beam-lisp gap or on **Specter's
> own impl machinery** — `i/NONE`, `i/direct-nav-obj`, the compiled-path
> cache, the exec interop, `doseqres` — plus non-vendored upstream navs.
> Adding more *core forms* to beam-lisp will no longer move the load
> number; the next jump is Specter-engine-shaped.

### Trajectory across measurements

| measurement | load | behave | notes |
|---|:--:|:--:|---|
| prior (syntax wave) | 11 | 1 | the syntax list was the wall |
| wave 26 (2026-08-07) | 23 | 4 | syntax done; impl machinery + prims named as the wall |
| wave 27 (2026-08-08) | 23 | 8 | prims + destructure fix landed; phantom-sentinel fix makes the rest honest |
| **this (wave 28, 2026-08-09)** | **25** | **9** | `for`/`vary-meta`/`^Tag`/`declare` + the datum fix: 05 behaves, 23/24 load |

The behave curve is no longer flat: 1 → 4 → 8 → 9. The load curve
moved for the first time since the syntax wave (23 → 25), but the two
new loads are empty-params `defnav` callers whose *bodies* still need
Specter-internal helpers (`n/all-select`, `doseqres`) — so they load,
not behave. The prediction-vs-outcome section below is blunt about the
one load that did *not* materialize (the canonical-layout syntax-quote
gap).

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
   header line is excluded because the harness provides its own. A slice
   that needs a local edit is a **FAIL with a recorded reason** — never a
   patch. The vendored text is never rewritten (a checksum test guards
   that).
3. **Behave.** Each loaded slice is then *called* with an
   upstream-shaped argument. Where a slice calls a sibling in the
   vendored set, the sibling is co-loaded — the `nav`/`defnav` macro
   stack is co-loaded into one namespace exactly as the existing test
   does for slice 04 (`RichNavigator` + `determine-params-impls` +
   `nav`/`richnav`), and cross-ns aliasing (`:require … :as i`) is used
   where the slice itself is a qualified-name client (slice 17's
   `i/dynamic-param?`). Slices that need *non-vendored* upstream
   machinery (`i/NONE`, `doseqres`, `eachnav`, `PosNavigator`, the `path`
   macro, `compiled-traverse*`, `i/direct-nav-obj`, `.select*`) are
   recorded as load-only with that named as the blocker.
4. **Two verdicts, reported separately.** **LOAD** = the fixture
   evaluates without raising. **BEHAVE** = called with a real example it
   computes the right answer. A slice that loads but computes a wrong
   answer is a FAIL; a slice that loads and cannot even be called is
   load-only with the exact blocker named. Slices 23/24 are this wave's
   demonstration that the two verdicts are not the same claim: both now
   load (empty-params `defnav` expands) but neither behaves
   (`n/all-select`, `doseqres`).

## The checklist — 31 attempted slices

Verdicts: **✓ pass** (loads *and* behaves) · **◐ load-only** (reads and
compiles, fails loudly when called) · **✗ fail** (a recorded load
gap). Row *lines* are the upstream span at the commit above.

| # | slice | upstream | defines | verdict | blocker |
|---|-------|----------|---------|:-------:|---------|
| 01 | rich-navigator-protocol | protocols.cljc 3–18 | `RichNavigator` defprotocol | **✓** | — reify + dispatch of both methods work |
| 02 | collector-implicitnav | protocols.cljc 21–27 | `Collector`, `ImplicitNav` | **✓** | — both dispatch |
| 03 | determine-params-impls | macros.clj 6–11 | `determine-params-impls` | **✓** | — groups impls into a method-keyed map |
| 04 | richnav+nav | macros.clj 14–32 | `richnav`, `nav` | **✓** | empty-params navigators construct & dispatch |
| 05 | defnav+defrichnav | macros.clj 34–54 | `defnav`, `defrichnav` | **✓** | **`for`+`vary-meta`+`declare`+datum fix landed** — empty-params defnav/defrichnav build working navigators |
| 06 | not-selected?/selected? | navs.cljc 15–23 | `not-selected?*`, `selected?*` | ◐ | `i/compiled-select-any*` + `i/NONE` (impl) |
| 07 | all-select | navs.cljc 26–28 | `all-select` | ◐ | `doseqres` + `i/NONE` (not vendored) |
| 08 | queue? reader-cond | navs.cljc 30–37 | `queue?` | ◐ | `:clj` branch = `instance? clojure.lang.PersistentQueue` — Java class, untestable on BEAM |
| 09 | void-kv-pair + non-transient | navs.cljc 43–55 | `void-transformed-kv-pair?`, `non-transient-map-all-transform` | ◐ | `i/NONE`; `reduce-kv` present |
| 10 | not-NONE? + all-transform | navs.cljc 57–69 | `not-NONE?`, `all-transform-list/-record` | ◐ | `i/NONE`; `sequence` present |
| 11 | srange-select | navs.cljc 395–402 | `srange-select`, `srange-transform` | ✗ | **`(def srange-transform i/srange-transform*)`** — non-vendored impl fn |
| 12 | extract-basic-filter-fn | navs.cljc 405–418 | `extract-basic-filter-fn` | **✓** | self-contained |
| 13 | if-select + if-transform | navs.cljc 421–437 | `if-select`, `if-transform` | ◐ | `i/exec-select*` → expands to `.select*` (Java host dispatch) |
| 14 | do-keypath-transform | navs.cljc 689–695 | `do-keypath-transform` | ◐ | `i/NONE` + `i/srange-transform*` |
| 15 | keypath* + must* | navs.cljc 697–721 | `keypath*`, `must*` | ✗ | non-empty `defrichnav` → `i/direct-nav-obj` (impl); also `.select*`-adjacent |
| 16 | insert-before-index-list | navs.cljc 755–758 | `insert-before-index-list` | **✓** | self-contained |
| 17 | static-path + wrap-dynamic | specter.cljc 35–53 | `static-path?`, `wrap-dynamic-nav` | **✓** | `static-path?` works; `wrap-dynamic-nav` needs `i/comp-paths*` |
| 18 | select macro | specter.cljc 349–354 | `select` | ◐ | `path` macro + `i/compiled-select*` (impl) |
| 19 | select-any macro | specter.cljc 373–379 | `select-any` | ◐ | `path` + `i/compiled-select-any*` |
| 20 | transform macro | specter.cljc 386–392 | `transform` | ◐ | `path` + `i/compiled-transform*` |
| 21 | setval macro | specter.cljc 409–413 | `setval` | ◐ | `path` + `i/compiled-setval*` |
| 22 | comp-paths | specter.cljc 516–520 | `comp-paths` | ◐ | `i/comp-paths*`; `vec` present |
| 23 | ALL | specter.cljc 717–725 | `ALL` nav | ◐ | **LOADs now** (empty-params defnav); body needs `n/all-select`/`all-transform` |
| 24 | MAP-VALS | specter.cljc 740–749 | `MAP-VALS` nav | ◐ | **LOADs now** (empty-params defnav); body needs `doseqres` + `n/map-vals-transform` |
| 25 | FIRST + LAST | specter.cljc 767–777 | `FIRST`, `LAST` | ✗ | `n/PosNavigator`, `n/get-last`/`update-last` (non-vendored) |
| 26 | srange | specter.cljc 793–801 | `srange` nav | ✗ | non-empty `defnav` → `i/direct-nav-obj` (impl) |
| 27 | keypath | specter.cljc 989–993 | `keypath` | ✗ | `eachnav` + `n/keypath*` (non-vendored) |
| 28 | exec-select/transform | impl.cljc 99–127 | `exec-select*`, `exec-transform*` macros | ◐ | **`^Tag` now peeled** (expansion works); behavior hits `.select*` — Java host dispatch on a reify |
| 29 | mutable-cell deftype | impl.cljc 222–273 | `MutableCell` | ✗ | `#?(:bb … :cljs …)` — **no `:clj` branch** (correct) |
| 30 | compiled-select/transform | impl.cljc 372–441 | `compiled-select*` … `terminal*` | ◐ | `mutable-cell` (needs 29), `compiled-traverse*`, `NONE` |
| 31 | defrecord path forms | impl.cljc 449–474 | `LocalSym` … `dynamic-param?` | **✓** | records construct; `type` classifies correctly |

**Counts.** 25 load; **9 behave** (`✓`: 01, 02, 03, 04, 05, 12, 16, 17,
31); 6 fail to load (11, 15, 25, 26, 27, 29); 16 load but do not behave
(06, 07, 08, 09, 10, 13, 14, 18, 19, 20, 21, 22, 23, 24, 28, 30).

## What changed this wave — the five shipped items

All five shipped since the last measurement, and all five are now
independently verified (not trusted from the changelog):

1. **`for`** — now in the prelude. Lazy, nested, `:let`/`:when`/`:while`,
   destructuring, hygienic. This is what `defnav`'s helper-builder needs.
2. **`vary-meta` variadic** — `(vary-meta x assoc :k v)` works.
   `defnav`/`defrichnav` stamp `:arglists` with exactly this form.
3. **`^Tag` on binding forms** — peeled as a no-op at every binding
   position (let, loop, fn params, `:or`/`:keys`/`:as`). This is what
   slice 28's `exec-select*`/`exec-transform*` expansion emits.
4. **`declare`** — forward references and mutual recursion work.
   `defnav`'s per-method `declare` forms now resolve.
5. **`var_meta_ast/4` datum fix** — metadata values a macro attaches
   (as datum, via `(vary-meta name assoc :arglists '(...))`) now route
   through `data_to_form/1` instead of crashing the compiler. Without
   this, `defnav` died on a raw `FunctionClauseError`; with it, the
   `:arglists` stamp is a datum and the slice loads.

**Verified directly this session:** `for` (all four modifiers,
nested, destructure), `vary-meta` variadic, `^Tag` on let/loop/fn-param/
`:as`, `declare` + mutual recursion — all return correct values. Slice
05's `defnav`/`defrichnav` now construct and dispatch a navigator
(`[42 42 42 42]`). Slices 23 and 24 (empty-params `defnav` callers) now
load.

## Prediction vs. outcome — the check the list is owed

The last ranking named **five** items. Here is what actually happened to
each — including where the prediction was *not* the whole story.

| predicted | shipped? | outcome |
|---|---|---|
| **`for` + `vary-meta` variadic → unlock 15, 23, 24, 26** | yes | **Partially materialized — at LOAD for 23/24, at BEHAVE for 05; NOT for 15/26.** Slices 23 (ALL) and 24 (MAP-VALS) are empty-params `defnav` callers and now **load** — `for` and `vary-meta` were indeed the beam-lisp blockers. Slice 05 (`defnav`/`defrichnav` themselves) now **behaves**. But **15 and 26 did not unlock at load**: both have *non-empty* params, so `defnav`/`defrichnav` expand to `i/direct-nav-obj` — Specter's own impl function. Their beam-lisp blocker is gone; their remaining wall is Specter-internal, exactly as the old taxonomy ranked. **And there is a second, sharper miss — see the syntax-quote gap below.** |
| **`^Tag`-meta let bindings → unlock 13, 28, 30** | yes | **Partially materialized — at expansion, not at behave.** `^Tag` on a let binding no longer errors, so slice 28's `exec-select*`/`exec-transform*` macros now **expand** (the `(let [^RichNavigator g …])` form compiles). But 28's behavior still fails — at **`.select*`**, a Java host-method dispatch on the reify'd navigator, which is untestable on the BEAM (same class as slice 08's `instance? clojure.lang.PersistentQueue`). 13 inherits the same `.select*` blocker through `i/exec-select*`. 30 is blocked on `mutable-cell` (slice 29 cannot load) + `compiled-traverse*`. So `^Tag` was the *expansion* gate, and it is gone — but the exec interop's `.select*` and the `mutable-cell` machinery are the real behave walls, and they are Specter/Java-shaped, not beam-lisp-shaped. |
| **`declare`** | yes | Materialized. `defnav`'s forward `declare` of its per-method helpers resolves; mutual recursion verified directly. Enables 05's helper definitions. |
| **`var_meta_ast/4` datum fix** | yes (compiler bug, reported not requested) | Materialized and is the load-gate for 05. `defnav`'s `(vary-meta name assoc :arglists …)` previously crashed the compiler with a raw `FunctionClauseError`; now the metadata datum routes through `data_to_form/1` and the slice loads. Verified: `defnav` with the `:arglists` stamp expands and behaves. |
| **five items collectively → "the macro stack"** | — | The macro stack is done at the beam-lisp level: `nav`/`richnav` (04) behave, `defnav`/`defrichnav` (05) behave for empty params, 23/24 load. What remains inside the stack is **Specter-internal** (`i/direct-nav-obj` for non-empty params). |

**The honest miss the prediction did not name.** Under a *faithful*
upstream layout — each slice in its canonical namespace, the macros
`(:use …)`-cross-ns exactly as `navs.cljc` and `specter.cljc` do —
the `defnav` stack does **not** unlock, because **beam-lisp's
syntax-quote does not namespace-qualify symbols**. In Clojure,
`defnav` (defined in `com.rpl.specter.macros`) expands to
`` `(nav ~params ~@impls) ``, and Clojure qualifies that `nav` to
`com.rpl.specter.macros/nav`; the expansion works from any caller ns.
beam-lisp's `synq_data({:symbol, name}, …)` returns the bare symbol, so
the expansion resolves `nav`/`richnav`/`RichNavigator` in the *caller's*
namespace and fails (`undefined var`, or `No protocol named
…/RichNavigator`).

This is why the measurement's co-load convention matters and why it is
stated in the Method: **the same-ns co-load (which the existing test 04
uses, and which this measurement follows) is a workaround for a real
beam-lisp gap.** Reported here as a genuine finding, not fixed. Under
canonical layout, 15/23/24 would fail on this gap rather than loading.
It is the single most likely reason a *real* Specter user — who does not
co-load into one ns — would not get 23/24 to load even after this wave.

**Standing rule honored:** a ranked gap list not checked against
outcomes is astrology. `reify` once ranked as unlocking 6 slices and
unlocked zero; the prims round predicted "10 of 19" and delivered 4.
This wave's check: `for`/`vary-meta`/`declare`/datum-fix held where they
were named (05 behaves, 23/24 load), `^Tag` held only at expansion, and
a new gap (syntax-quote qualification) surfaced that the ranking had not
anticipated. That last item is the most valuable output of this
measurement.

## Load-failure taxonomy (the remaining 6)

*Unlock counts are slices each gap blocks; ordered by current relevance.*

### 1. Specter's own `i/direct-nav-obj` — non-empty-param `defnav`/`defrichnav` (2 slices)

`defnav`/`defrichnav` with non-empty params expand into
`(i/direct-nav-obj (fn ~params (reify RichNavigator …)))`. That impl
function is not vendored. Blocks **15** (keypath*/must*) and **26**
(srange). The beam-lisp side of these is done — this is now purely a
Specter-engine gap.

### 2. Non-vendored navs/impl helpers (3 slices)

`FIRST`/`LAST` (25) reference `n/PosNavigator`, `n/get-last`/
`update-last`; `keypath` (27) references `eachnav`, `n/keypath*`;
`srange-transform` (11) references `i/srange-transform*`. All live
outside the vendored 31. Upstream internal deps, not beam-lisp gaps.

### 3. A reader conditional with no matching branch (1 slice — correct)

Slice 29 (`MutableCell`) is `#?(:bb … :cljs …)`: under `:clj` reader
features it has no branch, so the reader correctly raises *no
conditional matching* — exactly as real Clojure would. On `:clj`,
`MutableCell` is a Java class. **Correct measurement, not a gap.**

## The gap this measurement found — and it is now closed

```
;; in com.rpl.specter.macros
(defmacro defnav [name params & impls]
  `(def ~name (nav ~params ~@impls)))   ; Clojure qualifies `nav` → macros/nav

;; beam-lisp: `nav in the expansion stays bare, resolves in the CALLER ns
(macros/defnav …) called from com.rpl.specter.navs
  → undefined var: com.rpl.specter.navs/nav
```

Verified this session, then **fixed in the same wave**. Syntax-quote now
resolves a symbol in the namespace that WROTE the template and emits it
qualified, as Clojure does. The whole navigator macro stack loads under
the canonical cross-namespace layout as a result: 01, 02, 03, 04, 05, 23
and 24 all load, and 15/26 now stop inside Specter's own
`i/direct-nav-obj` rather than in beam-lisp.

Two things about the fix are worth recording, because both were learned
by breaking something:

- **A macro name must stay bare.** The expander already searches the
  writing namespace and core; qualifying one sent it down the ordinary
  var path, where it was invoked as a function. That broke every vendored
  jank macro nesting `when` or `let` — 8 fidelity slices at once. The
  vendored suite caught it immediately.
- **The gap was never Specter-specific.** Any beam-lisp library shipping
  a macro hit it; it is why `priv/optics.bl` and `priv/rewrite.bl` keep
  their helpers and macros in a single file. Measuring someone else's
  code found a bug in our own libraries' constraints.


## What to build next — re-ranked for *behavior*

*Ordered by behavioral yield, not load yield. Each item names the axis
it moves, and distinguishes beam-lisp gaps from Specter's engine.*

**Beam-lisp gaps (buildable):**

1. **Syntax-quote namespace qualification** — the new finding above.
   Not needed by the same-ns measurement, but it is what makes a real
   cross-ns Specter load work. Unlock count: makes 15/23/24's canonical
   load honest; enables any cross-ns macro library (not just Specter).
   Zero behavioral yield on the current test (the convention masks it),
   but the highest *real-world* yield.
2. **(Nothing else in the core forms.)** `for`, `vary-meta` variadic,
   `^Tag` bindings, `declare`, quoted-symbol destructuring, `into`/
   `keys`/`type`/`vec`/`sequence` — the core-form gaps are closed. The
   remaining load failures are Specter-internal or non-vendored.

**Specter's impl machinery (the behave wall — the larger kind of work):**

3. **The compiled-path engine** — a real `i/NONE` sentinel, the `path`
   macro, `i/compiled-select*`/`select-any*`/`transform*`/`setval*`,
   `i/comp-paths*`, and behind them `i/direct-nav-obj` (15, 26),
   `doseqres` (07, 24), `i/srange-transform*` (11, 14). This is the
   heart of Specter — the thing the entry-point macros (18–21) and the
   `i/NONE` clients (06, 09, 10, 14) are waiting on.
4. **The exec interop / `.select*`** — the `exec-select*`/`exec-transform*`
   macros now expand (the `^Tag` is gone) but dispatch via `.select*` on
   a reify'd `RichNavigator`, which is Java host-method dispatch
   untestable on the BEAM. 13 and 28 are blocked here. Either beam-lisp
   needs a way to dispatch a protocol method through `.method` syntax, or
   this is the same Java-interop wall as slices 08/29.
5. **`mutable-cell` + `compiled-traverse*` + `NONE`** (30) — blocked on
   slice 29 (can't read as `:clj`) plus the compiled-traversal engine.

**Non-vendored upstream deps (a different and larger kind):**

6. **Non-vendored navs helpers** — `n/PosNavigator`, `n/get-last`/
   `update-last` (25), `eachnav` + `n/keypath*` (27), `n/all-select`/
   `all-transform` (23), `n/map-vals-transform` (24). Meaningful only
   after the engine (#3) exists, since they are built on it.

**Correct-by-construction (no work, by design):**

7. **Slice 29** — `#?(:bb … :cljs …)` with no `:clj` branch *should*
   fail to read; on `:clj` it is a Java class. **Slice 08** — the
   `:clj` branch is `(instance? clojure.lang.PersistentQueue …)`, Java
   interop untestable on the BEAM. Neither is a beam-lisp gap.

**The honest trajectory.** The macro stack is done at the beam-lisp
level; this wave proved it (05 behaves, 23/24 load). **The remaining
distance is now essentially all Specter's own impl machinery** —
`i/direct-nav-obj`, the compiled-path cache, the exec interop, and the
non-vendored upstream navs — plus the one newly-found beam-lisp gap
(syntax-quote qualification) that only the canonical layout exposes.
**Adding further core forms to beam-lisp will no longer move this
measurement's numbers.** The next behave jump, if one comes, comes from
building Specter's engine, not from more of beam-lisp's stdlib. That is
the single most useful sentence this document can contain, because it
tells a future reader where the real work is.

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
  failed a genuine call, with the exact blocker named. Co-loads are
  noted where they occurred (04/05/23/24 co-load the macro stack;
  17 co-loads 31 into `com.rpl.specter.impl` and aliases `i`).
- **The phantom-sentinel caveat stays withdrawn.** Unresolved qualified
  names fail loudly, so every `i/*` verdict is a clean failure — no
  vacuous sentinel, no silently-wrong behavior.
- **The measurement convention is the honest caveat of this wave.** The
  same-ns macro-stack co-load works around the syntax-quote
  non-qualification gap. The doc states both: the headline numbers use
  the established convention (comparable across all four waves), and the
  prediction-vs-outcome section names what the canonical layout would
  actually hit.

**Newly-identified beam-lisp gap (reported, not fixed — measurement
only):**

- ~~**syntax-quote does not namespace-qualify symbols**~~ — **BUILT, same
  wave.** `` `nav `` in a macro defined in ns A now becomes `A/nav`, as in
  Clojure. The canonical cross-ns `defnav`/`defrichnav` stack loads:
  01, 02, 03, 04, 05, 23 and 24 all load, and 15/26 now stop inside
  Specter's `i/direct-nav-obj` instead of in beam-lisp. It was correctly
  ranked highest-leverage — it was the last beam-lisp gap standing
  between the measurement's co-load convention and a real user's layout.

**With that closed, there are no known beam-lisp gaps left in this
measurement.** Every remaining failure is Specter's own impl machinery, a
non-vendored upstream dependency, or correct-by-construction. Adding
language features will not move this number further; see FUP-001, which
exists to decide whether implementing Specter's engine is worth doing at
all.

## FUP-001 — the engine spike, and its recommendation

FUP-001 was filed during wave 27 and deliberately held BLOCKED. Its question:
Specter's remaining distance is its own *compiled-path engine* — should
beam-lisp **implement** it faithfully, **approximate** it behind the same
user-facing API, or **decline** and record Specter as measured-and-bounded?

It was gated because this project had already been burned by ranking a feature
without checking the wall in front of it: `reify` was predicted to unlock six
navigator slices, was built, and unlocked zero. A spike into an *engine* on the
same reasoning would be that mistake with a much larger budget.

**Recommendation: implement — scoped to the engine core, and explicitly not to
the JVM fast paths.**

### Where the wall actually is

The full canonical stack loads, and then every entry point dies in the same
place:

```
ALL                     → {:bl_reify, #Reference<…>}   ← navigators CONSTRUCT
(select [:a] {:a 1})    → undefined var: com.rpl.specter/path
(transform [:a] inc …)  → undefined var: com.rpl.specter/path
(setval [:a] 9 {:a 1})  → undefined var: com.rpl.specter.impl/compiled-setval*
```

That is one wall, not a diffuse absence. Navigator *construction* works;
navigator *execution* has no engine to run on. Across all 31 fixtures only
**11 distinct internals** are referenced, and `NONE` is 6 of the uses.

### The four assumptions the spike was filed on — all four refuted

FUP-001 listed the host capabilities the engine was *presumed* to need. Reading
upstream refutes each one. This is the substance of the recommendation.

| Presumed blocker | What the source says | Verdict |
|---|---|---|
| `i/NONE` needs object identity | `(def NONE ::NONE)` — a namespaced keyword (`impl.cljc:24`) | **Safer here.** A BEAM atom is globally interned, so `identical?` holds by construction |
| `MutableCell` is a Java class | It is; but the `:bb` branch is `(MutableCell. (volatile! v))` (`impl.cljc:231-238`) | beam-lisp already has `volatile!` |
| Runtime codegen (`eval+`) is intrinsic | `:clj`-only. The `:cljs` branch uses late-resolution closures instead (`impl.cljc:939-945`) | Not required |
| `.select*` direct dispatch | Three branches; `:bb`/`:cljs` use a plain protocol call (`impl.cljc:101-128`) | A speed hint, not semantics |

No `definterface`, `proxy`, or `gen-class` anywhere in the source. `:inline`
appears only in comments and one TODO.

**ClojureScript is the proof.** Specter already runs on a host with no JVM, no
class generation and no `eval`. That branch is the closest available analogue
to the BEAM, and it is a supported, shipping target — not a degraded mode.

### What the engine IS

Continuation-passing over a two-method protocol. `combine-two-navs` nests
continuations so that `[ALL :a]` becomes a navigator whose `select*` invokes
`ALL` with a continuation that invokes `:a` on each yielded subvalue
(`impl.cljc:185-196`). Closures and protocols. The BEAM has both.

Measured size: the engine core (`impl.cljc` 282-441 — traverse, select,
transform) is **~138 non-blank lines**. The `path` macro and entry points are
another ~138. `magic-precompilation` and the dynamic-path layer are a further
~131, and are separable — see the staging below.

### Host capability probe

Every primitive the engine needs, checked by running it rather than assuming:

| Requirement | Probe | Result |
|---|---|---|
| Sentinel with stable identity | `(identical? :x/NONE :x/NONE)` | ✓ true |
| CPS nesting | 3-deep `next-fn` chain | ✓ |
| Closure capture of `vals` | ✓ | ✓ |
| Early termination | `reduced` / `unreduced` / short-circuiting `reduce` | ✓ |
| Within-call mutable cell | `volatile!` / `vreset!` / `@` | ✓ |
| Protocol dispatch on a `reify` | navigator roundtrip | ✓ |

Genuinely missing, and small: **`keyword`, `namespace`, `satisfies?`**, and
`extend-protocol` against primitive type tags.

### Why not the other two routes

**Approximate — rejected, and the reason is the trap FUP-001 itself named.**
A beam-lisp-native engine behind `select`/`transform`/`setval` would give a
working Specter-shaped API and *barely move the measurement*, because **15 of
the 31 fixtures call `i/` internals directly**. It would also buy something
this project already ships: `priv/optics.bl` provides lenses and traversals
natively. Paying an engine's cost for an API we have, while the number stays
put, is the worst of the three.

**Decline — defensible, but on a premise now known to be false.** The case for
declining was "this is JVM-intrinsic machinery, a port project in its own
right." Every specific instance of that claim is refuted above. Declining would
mean stopping in front of ~140 lines of CPS on a host that has each primitive
it needs.

### Staging, and the two real risks

Order matters, because the last third of the engine is where the `:clj`/`:cljs`
branches diverge most — which is exactly where a prediction is most likely to
be wrong.

1. **Prims** — `keyword`, `namespace`, `satisfies?`, `extend-protocol` on
   primitive tags. Independently useful; unblocks everything below.
2. **Engine core** — `NONE`, `comp-paths*`/`do-comp-paths`/`combine-two-navs`,
   `compiled-traverse*`, `compiled-select*`/`-any*`, `compiled-transform*`,
   `compiled-setval*`, `srange-transform*`, `doseqres`. Port the `:bb`/`:cljs`
   shape throughout.
3. **Re-measure, then decide about the dynamic-path layer.** Do not plan step 3
   in detail before step 2's number is in hand.

**Skip `magic-precompilation`'s caching at first.** It is explicitly
*performance-only*: omitting it recomposes the path per call and changes no
semantics. That also defers the single most dangerous design question —

- **Cache lifetime.** Specter's cache is a var-interned mutable cell. "Global"
  on the BEAM is either ETS or per-process, and choosing wrongly is a
  *correctness* bug, not a slowdown. Not building the cache avoids the question
  until there is a reason to answer it.
- **Erlang term order.** Map iteration order differs from Clojure's. It does
  not affect the navigation algebra, but it will affect assertions over
  map-valued results, and tests must state contracts (roundtrip, agreement with
  `seq`) rather than literal orders — the same discipline `keys`/`vals` already
  follow.

### What this buys beyond the number

The honest answer FUP-001 demanded. Every prior measurement surfaced a class of
latent bug, and the engine exercises paths nothing else does: deep continuation
nesting, a sentinel threaded through every return, and early termination across
composed protocol calls. On present form that finds compiler bugs. If it does
not, the fallback position is still an improvement — Specter stops being
"bounded by someone else's internals" and becomes bounded by a number we chose
not to chase.

## Wave 28 outcome — the engine was built, and what it moved

FUP-001 recommended implementing. PLAN-018 did. This section records what
that bought, including the part that did not move.

### The number

**Load stays 25 of 31.** Predicted, and worth being explicit about: the
engine adds no *syntax*, and load measures whether a slice's forms compile.
An engine cannot move a load score, and a wave that claimed it would have
been measuring something else.

**Behaviour is where it moved.** Three vendored slices now run against the
port — not "load", but compute verified answers, with upstream's own code
calling our `NONE`, our `doseqres` and our `compiled-select-any*`:

- **slice 07 (`all-select`)** — the full reduction contract: a NONE result
  does not clobber a sibling's, a non-NONE result wins over surrounding
  NONEs, and a `reduced` terminates the walk after exactly two of five
  elements.
- **slice 06 (`selected?*` / `not-selected?*`)** — answers through
  `compiled-select-any*`.
- **slice 14 (`do-keypath-transform`)** — rebuilds a map around a new value,
  leaving everything else untouched.

They are registered in `specter_compat_test.exs` under "verbatim slices
running on beam-lisp's ported engine". The engine is published as
`com.rpl.specter.impl`, which is where a vendored slice's `i/` alias
points — the fixture is not adapted to us, we are adapted to it.

### What the port found that the tests did not

**Slice 06 found a missing arity.** `compiled-select-any*` has two forms
upstream; the port shipped only the 2-arity one, and every hand-written test
passed because they all called the arity we had written. `selected?*` calls
the 3-arity form that threads `vals`. This is the argument for measuring
against someone else's code in one line: our tests could only ever test our
understanding.

**`doseqres` had to become a macro.** It was ported as a higher-order
function, which is the better shape for beam-lisp — and vendored code writes
`(doseqres NONE [e structure] (next-fn e))`, a binding form. Both surfaces
now exist, `doseqres` the macro and `doseqres-fn` the function, and both are
tested, because a macro that disagrees with the function beneath it is a
trap.

**`println` was 0/1-arity.** Found while writing the example: every caller
reaching for `(println (str "x: " v))` was working around a missing arity
rather than choosing a spelling. Now variadic, as Clojure's is.

**A refer does not transit, and two things cannot be re-exported at all.**
Names referred into `specter.navs` are not referred on to its consumers. A
protocol cannot be re-exported by `def` (it names a registry entry, not a
var), and neither can a macro (binding the name captures what it evaluated
to, not the expander). Both are now written down in `priv/specter/navs.bl`
where the next person will look.

### The four predictions FUP-001 made

| Prediction | Outcome |
|---|---|
| `NONE` ports as a keyword; identity holds on the BEAM by interning | **Held.** It also survives a message send, which copies every other term — there is a test for exactly that |
| `MutableCell` is a within-call accumulator, replaceable by a fold | **Held.** `compiled-select*` is a `volatile!` collector; nothing needed shared mutation |
| No runtime codegen required — the `:cljs` branch proves it | **Held.** No `eval`, no module generation, nothing deferred to runtime compilation |
| ~140 lines of CPS | **Held.** `engine.bl` is the algebra, `exec.bl` the entry points, and the composition core is the ten lines it was measured to be |

Four for four is unusual here, and the reason is worth recording: these
predictions were made by READING the source rather than by reasoning about
the ecosystem. The one that was wrong in wave 27 (`reify` unlocking six
slices) was made the other way.

### What remains, and what will not move it

Six slices still fail to load. All six are Specter's own missing internals
(`PosNavigator`, `direct-nav-obj`, `eachnav`, `srange-transform*`'s callers)
or slice 29's reader conditional, which has no `:clj` branch and **must**
fail to read. None is a beam-lisp gap.

The `magic-precompilation` cache remains deliberately unbuilt. It is
performance-only, and it carries the one genuinely dangerous design question:
Specter's cache is a var-interned mutable cell, and "global" on this host is
either ETS or per-process, where choosing wrongly is a correctness bug rather
than a slowdown. Nothing has yet forced the choice.

`priv/optics.bl` remains the recommended native optics library. The engine is
a measurement instrument and a demonstration that the host can carry a hard
macro-and-protocol-heavy design; it is not a replacement for optics that
needed no compiler changes to exist.
