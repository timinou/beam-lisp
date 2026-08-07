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

> **`load` ≠ `behave`.** All 21 slices read+compile ("load"). Only some
> run correctly when called. The verdicts below are behavioral.

## The checklist — 21 attempted slices

Verdicts: **✓ pass** (loads and behaves) · **◐ partial** (common arities
pass, higher arities fail) · **✗ fail** (a recorded gap).

| # | slice | core.jank lines | defines | verdict | blocker |
|---|-------|-----------------|---------|:-------:|---------|
| 01 | constantly | 1048–1052 | `constantly` | ✓ | — self-contained |
| 02 | identity | 1054–1057 | `identity` | ✓ | — also in prelude |
| 03 | complement | 1059–1067 | `complement` | ✓ | needs `apply`(2-arity) + `not` |
| 04 | comp | 1186–1201 | `comp` | ◐ | 2-arity ✓; 4-arity needs `list*`/`next` |
| 05 | juxt | 2084–2118 | `juxt` | ◐ | 2-arity ✓; 4-arity needs `list*`/`next` |
| 06 | partial | 2120–2147 | `partial` | ◐ | ≤3 fixed ✓; 4+ fixed needs variadic `apply` |
| 07 | fnil | 2149–2170 | `fnil` | ✓ | needs `apply`(2-arity) |
| 08 | some | 2172–2180 | `some` | ✗ | `next` (only hit when first selector is falsy) |
| 09 | not-any? | 2262–2263 | `not-any?` | ✗ | → `some` → `next` |
| 10 | `->` | 2265–2279 | `->` macro | ✗ | `loop*`, `next`, `seq?`, `with-meta`, `meta` |
| 11 | `->>` | 2281–2295 | `->>` macro | ✗ | same as `->` |
| 12 | key/val | 2298–2307 | `key`, `val` | ✓ | `first`/`second` |
| 13 | if-let | 2608–2626 | `if-let` macro | ✗ | → `assert-macro-args` |
| 14 | when-let | 2628–2641 | `when-let` macro | ✗ | → `assert-macro-args` |
| 15 | if-not | 2662–2667 | `if-not` macro | ✓ | pure |
| 16 | dotimes | 2686–2701 | `dotimes` macro | ✗ | → `assert-macro-args` |
| 17 | doseq | 2703–2756 | `doseq` macro | ✗ | → `assert-macro-args` |
| 18 | doto | 2927–2941 | `doto` macro | ✗ | `with-meta`, `seq?`, `meta`, `next` |
| 19 | trampoline | 6999–7013 | `trampoline` | ✗ | `fn?`, `#()` fn literals |
| 20 | while | 7015–7022 | `while` macro | ✓ | pure (`loop`/`when`/`recur`) |
| 21 | memoize | 7024–7036 | `memoize` | ✗ | `if-let` → `assert-macro-args`, `find` |

## Counts — the headline

> **7 of 21 slices** load **and** behave correctly (8 definitions:
> `constantly`, `identity`, `complement`, `fnil`, `key`, `val`, `if-not`,
> `while`). A further **3 are partial** (comp, juxt, partial — they pass
> their everyday arities and only fail the variadic ones). **11 fail** on
> recorded gaps. **All 21 read + compile** — the reader and compiler never
> rejected a form; every failure is a missing runtime facility, not a
> syntax rejection.

The 7 passing slices are the ones exercised by `test/beam_lisp/jank_compat_test.exs`
(accepted only) and demonstrated end-to-end by `examples/jank_slice.bl`
(unmodified jank `while`/`constantly`/`complement`/`fnil`/`key`/`val`
running on the BEAM, exit 0).

## Gap classification

### 1. Missing prims (the dominant blocker)

| prim | blocks | notes |
|------|--------|-------|
| `next` | some, not-any?, comp/juxt variadic, assert-macro-args | **highest-value single prim**; `rest` exists but Clojure's `next`→nil-on-empty distinction is absent |
| `list*` (+ `spread`) | comp-4a, juxt-4a, assert-macro-args | variadic cons, built on `next` |
| `with-meta` / `meta` | doto, keys/vals, set, threading macros | metadata layer entirely absent |
| `fn?` | trampoline | fn-dispatch primitive |
| `seq?` | `->`/`->>`, doto | |
| `boolean` | every-pred, some-fn | |
| `find` / `contains?` | select-keys, memoize | map entry lookup |
| `namespace` | simple-ident?/qualified-ident? | |
| `symbol?`/`keyword?`/`string?`/`vector?`/`list?`/`map?` | keyword, ident?, set, set? | type-predicate layer absent |
| `transient`/`persistent!`/`conj!`/`assoc!` | keys/vals, set, zipmap | transient collection API |
| `cpp/*` runtime interop | the primitive layer of core.jank | nth/get/contains?/hash-set/peek/pop/bit-*/set ops are all `(cpp/jank.runtime.*)`; beam-lisp has no `cpp/` namespace, so any slice built on primitives is unreachable until beam-lisp supplies equivalents |

### 2. Semantic differences

- **`apply` is arity-2 only.** Clojure/jank `apply` is variadic
  (`(apply f a b … args)`); beam-lisp's `RT.apply` is fixed-arity-2.
  Blocks partial's 4+-fixed-arg path (`(apply f arg1 arg2 arg3 …)`), and
  would block complement/fnil/spread-based variadic apply. Smallest fix:
  make `RT.apply` variadic.
- **Ratio `1/2` mis-reads.** The reader produces `{:"$remote", "1", "2"}`
  (a qualified remote call) instead of a numeric ratio — so the head of
  `core.jank`'s numeric layer is unreachable.

### 3. Reader-level (syntax beam-lisp cannot read as intended)

- **`#(...)` fn literals + `%`/`%1` args** — `#` reads as a bare symbol.
  Blocks juxt-4a, trampoline-2a, every-pred, some-fn, run!, and a large
  fraction of idiomatic Clojure.
- **`^:kw` / `^{:map}` metadata** — `^` reads as a bare symbol. The very
  head of `core.jank` (`(def ^:dynamic *ns*)`) is unreadable for this
  reason — why whole-file load is out of scope.
- **char literals `\a`** — read as a symbol `\a`.
- **regex `#"…"`** and **`#_` discard** — `#` dispatch unsupported.
- **`&form`** — not specially bound in macros (resolves as a free symbol).

### 4. Missing special forms / ns naming

- **`fn*` / `loop*` / `let*`** (raw forms). jank's head uses `fn*`; the
  threading macros use `loop*`. beam-lisp has `fn`/`loop`/`let` only.
- **`clojure.core/` qualified refs.** `assert-macro-args` emits
  `clojure.core/when-not`, `clojure.core/*ns*`, etc. beam-lisp's core ns
  is named `core`, so `clojure.core/…` never resolves. jank names its ns
  `clojure.core` for Clojure compatibility; beam-lisp would need an alias
  (`clojure.core` → `core`) to read such code.

### 5. Requires laziness / protocols / transducers

- **Laziness.** beam-lisp's `map`/`filter` return *realized* lists for
  realized inputs (lazy only for lazy inputs); `(range)` no-arg is lazy.
  jank implements `map`/`filter`/`take-while`/… as lazy seqs, so slices
  built on the seq layer assume lazy composition. Not hit by the 21 leaf
  slices, but it will gate `concat`/`map`/`filter`/`take-while` slices.
- **Protocols / transducers.** jank's `transduce`/`completing`/`cat`/
  `preserving-reduced`/`reduced` depend on the `reduced` protocol;
  beam-lisp has no `reduced`/`reduced?`. Not exercised by the 21.

## What to build next (by unlock count)

1. **`next` (+ `list*`/`spread`)** — unlocks `some`, `not-any?`,
   comp/juxt variadic paths, and `assert-macro-args`. Every recursive seq
   function in the file leans on it. Biggest single lever (~5 slices now,
   and unblocks the whole recursive-seq style of `core.jank`).
2. **`#()` fn literals (+ `%` args), reader-level** — unlocks juxt-4a,
   trampoline-2a, run!, every-pred, some-fn, and the idiomatic fn-literal
   body of the file. Gates the largest fraction of readable forms.
3. **The let-macro family via `assert-macro-args`** — needs `meta`/`list*`/
   `next` + a `clojure.core` alias + `&form`. Unlocks the *six*-slice
   family `if-let`/`when-let`/`if-some`/`when-some`/`dotimes`/`doseq` —
   the largest single family in the measurement.
4. **`with-meta` / `meta`** — unlocks doto, keys/vals, set, and the
   metadata pattern the head of core.jank is built on.
5. **Variadic `apply`** (semantic) — unlocks partial's variadic path and
   the spread-based `apply` idiom.
6. **Predicate prims** (`fn?`, `seq?`, `boolean`, `find`, `contains?`,
   type predicates) — unlock trampoline, select-keys, memoize, keyword/ident.
7. **`cpp/*`-implemented primitives** — to escape the pure-Clojure leaf
   band, beam-lisp must supply the primitive layer (nth/get/contains?/
   hash-set/bit ops/set ops) that jank implements via runtime interop.
   This is the long tail that makes the *rest* of core.jank loadable.

## Keeping this honest

- The vendored fixtures carry a sha256 of their code portion; the test
  asserts it so any local edit silently voids the fidelity claim.
- If a slice ever *needs* an edit to load, that is a FAIL with the reason
  recorded — the fix goes into beam-lisp (`lib/`), never into the vendor.
- Big-bang loading of all 7795 lines is explicitly out of scope; the value
  is the per-slice, per-gap measurement above.
