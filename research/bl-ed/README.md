# bl-ed research: what building a real editor taught the JS target

These notes come from building bl-ed (`apps/bl-ed`), the first real application
compiled by the JS sync profile (`priv/lib/js`). PLAN-161 holds the plan and
the decisions D1–D7. This file holds the findings and the next steps. Every
number here was measured on this host on 2026-10-03.

## Findings

### 1. The engine profile matters more than anything else

| work | actor profile (generator machine) | sync profile |
|---|---|---|
| keystroke in an editor-shaped app | 43–144 ms (PROOF.md:77, outline search) | 0.31 ms BL / 4.6 ms full frame p50 |
| one edit on a 10k-line persistent vector | — (O(n) copy per assoc) | 22–40 µs |

Generators, a step object per non-tail call, a trampoline, and copy-on-write
collections are the right price for preemptible processes. For UI work they
are a 100–1000× tax. One BL source can be compiled by either profile. The
choice belongs to the BUILD, per namespace, not to the language.

### 2. "Same language on both sides" needs a differential, not good intentions

The BEAM ↔ JS differential (`test/js/diff/run-diff.sh`, about 230 expressions)
found these on its first runs. Each one would have been a silent divergence:

- `(= 1 1.0)` is **true** on BEAM (numeric `=`), yet `1` and `1.0` are distinct
  map keys. An earlier JS implementation followed `=:=` and got it wrong.
- String `count`, `subs` and `index-of` are **grapheme**-indexed on BEAM
  (`(count "é👍🏽")` is 2). They are not codepoints and not UTF-16.
- `(nth v 99)` past the end of a vector is **nil**, not an error. `(get v 9 :d)`
  is also nil (the default is ignored for vectors).
- `(str :k)` is `"k"`.
- The compiler emits runtime calls in their OWN argument conventions:
  - `Rt/drop` is (coll, n);
  - `(map f a b)` is `Rt.map_multi(f, a, (b))`;
  - `(apply f a … coll)` is `Rt.apply_variadic(f, a, rest)`;
  - variadic `__bl_v` clauses take one trailing rest list;
  - `Refs.swap!/2` has no rest list but `/3` does.
- BEAM core has no `vector`, `parse-long`, `bit-and`, `hash` or `partition-all`.
  Portable code must not assume Clojure's full core.

The fix pattern held up: one semantics, a native implementation per target,
and a differential holding them together (PLAN-161 D5). The actor profile's
alternative, a parallel BL prelude re-deriving core over host leaves, needed
the same differential and still drifted.

### 3. Lenient structure beats authoritative parsing for editing

The BEAM reader stops at the first error, which is right for compiling. An
editor reads half-typed code all the time, so `ed.forms` never fails: stray,
mismatched and unclosed delimiters become nodes with flags, and the render
paints them as errors. The authoritative reader stays authoritative for
evaluation, which bl.doc does on the BEAM.

### 4. Purity made the hard parts easy

The editor is one value, and every command is `(fn [ed] ed')`.

- **Undo** is a vector of snapshots. Persistence makes each snapshot a pointer.
- **Dirty** is derived (`text ≠ saved-text`), so undoing to the saved text
  makes the file clean again. A stored flag got this wrong, and screenshot 07
  caught it.
- **Effects** (save, eval, clipboard) are data, so the core runs headless in
  Node for 17 drive tests, and `ed.selftest` runs the same 44 checks on BEAM
  and in JS.
- **Incremental structure** is safe because it can be compared against the
  from-scratch derivation. A property test does exactly that over 450 random
  edits on real documents.

### 5. Where the time went (and how it went away)

On a 1,161-line document, a typed character started at 31.5 ms p50 / 52 ms
p95 and ended at 4.6 / 11. Profiling, not guessing, found each step:

1. Every edit re-derived the whole org partition and every cell's forms
   (7.7 ms). Fix: re-read only the edited cell when no line changes its
   structural class.
2. `render` asked "which block is row r" by a linear scan, 40 times a frame.
   Fix: binary search; the partition is ordered and total.
3. `subs` re-segmented each string into graphemes on every call. A scanner
   calls it once per character, so this was 1,232 calls and 13 ms per frame.
   Fix: an LRU of grapheme arrays keyed by the string. Strings are values,
   so the cache cannot go stale.
4. The DOM was rebuilt per frame. Fix: slot reconciliation by line signature.

## Next steps (proposed)

1. **Make the sync profile a first-class `bl` verb.** Replace the env-variable
   CLI with `bl js build <entry> [--out] [--host fn,…]`, add `bl js watch`, and
   add the profile to `bl test` (run the Node tests and the differential).
2. **Grow the differential into the core spec (FUP-141).** Generate cases
   instead of hand-writing them: property-based expressions over the core
   surface, compared on BEAM and JS. Pin the BEAM answer for each core fn as
   the spec.
3. **Retire the actor profile's prelude.** `research/js-actors/runtime.bl`'s
   700-line prelude re-implements core. It should call `priv/lib/js/core.mjs`
   instead and keep only the actor runtime (mailboxes, scheduler, links). That
   is one core and two execution models.
4. **In-browser BL evaluation (FUP-134).** `ed.lisp` is a stopgap interpreter.
   The real answer is the self-hosted compiler compiled to JS. Its blockers
   are listed in FUP-134: the host-op registry, deterministic fresh names, and
   macro-expansion-time eval.
5. **Placement for bl-ed itself.** Evaluation is a BEAM effect today. Pure
   cells (the analyzer says so: `system.analyze` footprint `{}`, terminates)
   could run in the browser instantly through the sync profile, with only
   effectful cells going to the BEAM. That would be split-by-default
   (PLAN-157) applied to a notebook.
6. **Structural editing depth.** Add slurp and barf, convolute,
   transpose-forms, and select-by-type (all strings, all keywords in a form).
   The lenient forest already carries what they need.
7. **Real IME and large-file checks.** Test the input sink with a CJK input
   method. Add horizontal virtualization for very long lines. Measure a
   100k-line document.
