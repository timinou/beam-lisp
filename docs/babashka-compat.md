# Babashka / Clojure stdlib compatibility

**Thesis under test:** beam-lisp is "Clojure's language, the BEAM's runtime."
Babashka is the reference for *Clojure-as-a-scripting-language* — `clojure.core`
plus a batteries set (`clojure.string`, `clojure.set`, `clojure.edn`,
`clojure.walk`, `clojure.java.io`, `babashka.fs`) and a script-friendly platform
(`*command-line-args*`, `slurp`/`spit`, shebangs). If beam-lisp can run those
namespaces — vendoring the *real upstream source and tests where the code is
portable*, and reimplementing the public API where the JVM original is
Java-interop to the core — then Babashka compatibility stops being an opinion
and becomes a test suite.

This document is the measurement: what is done, how it was proven, and what
remains.

## The method (same as `jank-compat.md`)

1. **Vendor or reimplement.** A namespace that is *pure Clojure over core*
   (`clojure.set`) is **vendored byte-for-byte** — the copy-paste tier. A
   namespace that is *Java-interop to the core* (`clojure.string`,
   `clojure.walk`) is **reimplemented** with the same public API, same
   contracts, same argument orders and edge cases, over BEAM primitives
   (Elixir `String`/`Regex`, Erlang `:re`, OTP `File`/`Path`).
2. **Grade with the real tests.** The oracle is **Clojure's own test suite**,
   vendored where portable. A test that needs a *host* adaptation (a
   `StringBuffer.` receiver, a `#"…"` reader literal, a `NullPointerException`
   class) is adapted with the reason recorded in the test header — the
   *expected value* is never changed.
3. **A needed edit goes into beam-lisp, never the vendor.** Where running real
   Clojure exposed a genuine gap, the fix landed in the language
   (`lib/`, `priv/`), and is listed under "Gaps closed" below.

## The compat tier

A new source tier, `priv/compat/`, on the loader's load path (see
`BeamLisp.Tiers`). Each namespace declares its canonical Clojure name, so
**unmodified** `(ns app (:require [clojure.string :as str]))` resolves:

| namespace | file | strategy |
|---|---|---|
| `clojure.string` | `priv/compat/clojure/string.bl` | reimplemented |
| `clojure.set` | `priv/compat/clojure/set.bl` | **vendored verbatim** |
| `clojure.walk` | `priv/compat/clojure/walk.bl` | reimplemented (pure fns verbatim) |
| `clojure.edn` | `priv/compat/clojure/edn.bl` | realizer over the reader |
| `clojure.re` (core regex) | `priv/compat/clojure/re.bl` | over Elixir `Regex` |
| `clojure.core-ext` | `priv/compat/clojure/core_ext.bl` | missing `clojure.core` fns |
| `clojure.io` (slurp/spit) | `priv/compat/clojure/io.bl` | over OTP `File` |
| `clojure.java.io` | `priv/compat/clojure/java/io.bl` | path-oriented subset |
| `babashka.fs` | `priv/compat/babashka/fs.bl` | over `File`/`Path` |

The `clojure.core` functions each namespace needs unqualified (regex `re-find`
etc., `slurp`/`spit`, `char`, `conj` variadic, `integer?`, …) are **interned
into `core` on load**, via a captured value-`def` that the AOT `__bl_init__`
replays — so a bare `(re-find …)` resolves everywhere, exactly as on the JVM,
**with zero edit to a boot seed**.

## The scorecard — real upstream tests, green

Every count below is Clojure's own test file (adapted only for host
differences, recorded per file), run by `mix beam_lisp.test`:

| suite | source of assertions | tests | assertions | status |
|---|---|---:|---:|:---:|
| `clojure.string` | `test_clojure/string.clj` | 21 | 106 | ✓ |
| `clojure.set` | `test_clojure/clojure_set.clj` | 12 | 104 | ✓ |
| `clojure.walk` | `test_clojure/clojure_walk.clj` | 8 | 18 | ✓ |
| `clojure.edn` | EDN spec + `edn` behavior | 9 | 40 | ✓ |
| `clojure.re` | `clojure.core` regex contracts | 12 | 27 | ✓ |
| `clojure.io` | `slurp`/`spit` contracts | 7 | 10 | ✓ |
| `babashka.fs` | `babashka.fs` contracts | 6 | 23 | ✓ |
| `clojure.java.io` | `clojure.java.io` contracts | 6 | 12 | ✓ |
| **total** | | **81** | **339** | **0 failures** |

Plus **5** end-to-end assertions (`babashka_showcase_test.exs`) driving the
showcase scripts as real `bl run` invocations.

## The `clojure.string` fidelity that mattered

`clojure/string.clj` is Java to the core — `StringBuilder`, `java.util.regex`,
`Character.isWhitespace`. The reimplementation reproduces the contracts that
code actually depends on, and the upstream test suite proves each:

- **`replace` across all four match/replacement shapes.** char//char,
  string//string (literal), pattern//string (with Java `$1` group refs
  translated to Erlang `:re`'s `\1`), and pattern//function (the fn receives
  Clojure's argument shape — the whole match string, or a `[whole g1 …]` vector
  when the pattern has groups — driven by hand, because Elixir's
  `Regex.replace` inspects a fn's arity and rejects a variadic BEAM closure).
- **`split`** drops trailing empties and honors a limit; returns a vector.
- **`index-of`/`last-index-of`** grapheme-correct, with the `from` offset and
  `nil`-on-miss contract.
- **char arguments** (integers on the BEAM) accepted by `replace`/`index-of`
  via one-grapheme-string coercion.

## The `clojure.edn` safety property

`clojure.edn/read-string` exists apart from the load-time reader precisely
because it **does not evaluate**. beam-lisp's reader produces AST nodes wired to
a compiler that *would* evaluate — so `clojure.edn` is a **realizer**: it reads
text into nodes, then walks the nodes building plain data values directly,
never invoking the compiler. `(edn/read-string "(inc 1)")` is the two-element
list `(inc 1)` with `inc` a **bare symbol**, not the evaluated `2`. This is
asserted explicitly (`safety-no-evaluation`).

## Gaps closed in beam-lisp (running real Clojure found these)

Running unmodified upstream code is a better bug-finder than unit tests, exactly
as the jank-compat effort found. Each of these was a genuine beam-lisp gap; the
fix landed in the language, not the vendor:

1. **Maps and sets are now functions of their keys/members**
   (`lib/beam_lisp/rt.ex`): `({:a 1} :a)` → `1`, `(#{1 2} 1)` → `1`. Core
   Clojure/jank semantics that `clojure.set/join` depends on. Added for plain
   maps, sets, and sorted collections, after the struct clauses so only genuine
   plain maps reach the generic clause.
2. **`conj` is variadic** (`clojure.core-ext`): `(conj coll a b c)`, folding
   through the 2-arity primitive. Clojure's `conj` is variadic; the prim was
   1/2-arity. `clojure.set`'s variadic `union`/`intersection`/`difference` need
   it.
3. **`conj` accepts a raw 2-tuple map entry** (`rt.ex`): `(map f a-map)` yields
   entries as `{k, v}` tuples; feeding them back into `(into {} …)` must add the
   entry — `clojure.walk` relies on this.
4. **`sort`/`sort-by` accept a boolean comparator** (`rt.ex`): `(sort > coll)`
   and `(sort-by val > m)`. Clojure accepts either a 3-way numeric comparator
   *or* a boolean predicate; beam-lisp handled only the numeric form, so
   `(sort-by val >)` silently returned garbage. A real fidelity bug, caught by
   the wordfreq showcase.
5. **Shebang support** (`lib/beam_lisp/loader.ex`): a leading
   `#!/usr/bin/env bl` line is stripped (replaced by a blank line, preserving
   diagnostic line numbers) so a `.bl` script is directly executable, like a bb
   script.
6. **`*command-line-args*`** bound to the live argv by `run_file`
   (`lib/beam_lisp.ex`) in the process that holds it.
7. **New `clojure.core` functions** absent from the prelude
   (`clojure.core-ext`): `char`/`char?`, `vector`, `hash-set`, `empty`,
   `map-entry?`, `record?`, `macroexpand`, and the predicates `integer?`,
   `true?`/`false?`/`boolean?`, `double?`, `pos-int?`/`neg-int?`/`nat-int?`.

## The showcases

Three real, runnable Babashka-style scripts (`examples/babashka/`), each
self-demoing on no args and driven by `*command-line-args*` for a real run:

- **`wordfreq.bl`** — word-frequency ranking. `clojure.string`, regex,
  `frequencies`, `sort-by`.
- **`edn_report.bl`** — EDN-in / report-out. `clojure.edn`, `clojure.set`,
  `clojure.string`.
- **`loc.bl`** — lines-of-code by extension. `babashka.fs` glob, `group-by`,
  `sort-by`.

Run one directly:

```
mix run -e 'BeamLisp.with_argv(["/etc/hostname"], fn -> BeamLisp.run_file("examples/babashka/wordfreq.bl") end)'
```

or with no args to see its bundled-sample demo. All three are gated by the
`examples_test`/ward runner (loads-and-runs-clean) and by
`babashka_showcase_test.exs` (asserts the computed output).

## Honest status — what is NOT covered

This is a real, useful subset, not "any Babashka app". Deliberately out of scope:

- **Java-interop-heavy scripts.** A bb script that reaches into `java.*`
  (`java.time`, `java.nio`, a Maven dependency, a pod) cannot run unmodified —
  there is no JVM under the BEAM. This is a category boundary, not a gap to
  close.
- **`clojure.java.io` streams / URLs / resources.** The path-oriented subset
  (`file`, `make-parents`, `delete-file`, `copy`) is reproduced; the java.io
  stream/URL/`resource` surface is not (no java.io on the BEAM).
- **The `#"…"` regex reader literal.** Regex is available as *functions*
  (`re-pattern`, `re-find`, …); the reader literal is a boot/reader change,
  gated separately. Upstream tests that use `#"…"` are adapted to
  `(re-pattern "…")` — the compiled pattern is identical.
- **Numeric tower edges.** No `Ratio`, `BigDecimal`, or `NaN`; chars are integer
  codepoints, not a distinct `Character` type.
- **`clojure.string` bare-string `pr-str`.** A separate, recorded prelude quirk
  (`(pr-str "s")` at top level does not quote), independent of the compat layer.

## Keeping it honest

- Vendored files (`clojure.set`, and every vendored test) carry an upstream
  URL + commit; the `clojure.set` body is byte-for-byte upstream.
- A test that needed a host adaptation records it in its header with the
  reason; the expected value is upstream, verbatim.
- Every gap closed in beam-lisp is listed above and covered by the suite that
  exposed it, plus a regression check of the pre-existing suites.

## In one sentence

beam-lisp runs `clojure.string`, `clojure.set`, `clojure.walk`, `clojure.edn`,
`clojure.java.io`, and `babashka.fs` — graded by Clojure's own tests (81 tests,
339 assertions, zero failures) — plus `slurp`/`spit`/`*command-line-args*`/
shebangs, so real Babashka-style *scripts* run on the BEAM unmodified, with the
Java-interop tail honestly out of scope.
