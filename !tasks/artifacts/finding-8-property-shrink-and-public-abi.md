# Finding 8, follow-up — property-module domain shrink and the `shrink-coords` ABI

Scope: `PLAN-154` cluster **F**, the two honest limits left open by
`!tasks/artifacts/finding-8-analysis-and-shrink-repairs.md`:

- §6.2 — `veritas.property`'s *own* shrink was still generator-blind;
- §7 — the public symbol `veritas/shrink-coords` had been deleted ("no in-repo
  callers"), leaving one ABI surface shrunk.

Files touched: `priv/lib/veritas.bl`, `priv/lib/veritas/property.bl`,
`test/bl/veritas/shrink_domain_test.bl`, `test/bl/veritas/property_shrink_domain_test.bl`
(new), this artifact. No global build, no seed, no org/memory/staging, no
unowned file touched (the tree carries a large amount of uncommitted foundation
work; it is exactly as it was).

---

## 1. What was wrong, precisely

### 1a. `veritas.property` shrank with a ladder that never saw the generator

`priv/lib/veritas/property.bl` `hypothesis` draws its domain from
`v/samples gen n`, then shrank a refutation with its **own** `smaller`/`shrink`:

```clojure
(defn- smaller [cand]
  (if (vector? cand)
    (into [] (mapcat (fn [i] (map (fn [s] (assoc cand i s)) (v/shrink-candidates (nth cand i))))
                     (range 0 (count cand))))
    (v/shrink-candidates cand)))
```

`v/shrink-candidates` is the *generator-blind* value ladder ("walk toward 0").
So `hypothesis` over `(v/int-of 5 100)` could report `:shrunk 0` — a value the
generator can never produce, i.e. **not a counterexample of the query that was
asked**. Same class as the core defect the previous worker fixed, on a second
surface the previous worker explicitly left open ("a follow-up file change").

### 1b. `shrink-coords` was deleted as "no in-repo callers"

`git show 94adf656 -- priv/lib/veritas.bl` introduced it (public):

```clojure
(defn shrink-coords
  "Shrink a TUPLE `v` coordinate-wise, keeping its arity — a tuple witness is a
   point in a product domain, and dropping a coordinate would leave the domain."
  [fail? v] …)
```

The finding-8 cutover replaced the `shrink-fail` branch that called it with a
`GenShrink`-based walk and removed the symbol. It was public (`defn`, not
`defn-`); "no in-repo callers" is not evidence that no caller exists — the whole
point of the source-free tier is that consumers live outside this repo.

---

## 2. Changes

### 2.1 `priv/lib/veritas.bl`

**Restored `shrink-coords`** — verbatim body, original public signature
`[fail? v]`, so the ABI surface is whole again. Its docstring now states its
contract explicitly: it is **generator-blind** (it holds no generator) and a
caller that *does* hold one must use `shrink-in-domain` instead, whose
candidates come from the generator's own `GenShrink`.

**Publicised the domain-preserving walk** — the private `shrink-fail` became
public **`shrink-in-domain`** `[gen fail? v]` (same body, same fuel 200). It was
already the walk `run-sample` uses; it had to become public so
`veritas.property` could reuse it instead of duplicating `in-domain?` /
`gen-candidates` / the loop in a second module. Rename only — the symbol was
private, so nothing external observes the change. Comments that referenced
`shrink-fail` (`shrink`'s docstring, the `SHRINK` header, `shrink-candidates`'s
docstring, `run-sample`'s call site) were updated in the same pass.

**Why `shrink-coords` is *not* wired into any generator-aware path.** The
assignment's constraint is exact: preserve the public signature *without*
reintroducing out-of-domain witness production in generator-aware paths. A
tuple candidate is a point in a product domain; `shrink-coords` is blind to the
product, so per-coordinate it can walk past a child's edge (`one-of 1 31 32 33`
→ 0). `TupleGen`'s `gen-shrink` already shrinks coordinate-wise *with each
child's domain*. So `shrink-coords` stays the generator-blind tuple walk for
callers that hold no generator, and is not a candidate source for
`shrink-in-domain`.

Public shrink surface after this change (all `defn`, all value-directed):

| symbol | holds a generator? | domain-safe? | use |
|---|---|---|---|
| `shrink-candidates` | no | n/a (candidate list only) | the raw ladder |
| `shrink` | no | no | generator-blind walk |
| `shrink-coords` | no | no (arity kept) | generator-blind tuple walk |
| `shrink-in-domain` | **yes** | **yes** (`GenShrink`) | quantifier core + `veritas.property` |

### 2.2 `priv/lib/veritas/property.bl`

`smaller` is deleted; the module's private `shrink` now delegates to the core's
domain-preserving walk:

```clojure
(defn- shrink
  [gen src params pred cand]
  (if (and (> (count params) 1) (not= :tuple (v/gen-tag gen)))
    cand
    (v/shrink-in-domain gen
                        (fn [c] (not (:holds (holds-at? src params pred c))))
                        cand)))
```

`hypothesis` passes `gen` in: `(shrink gen src params pred (:input failing))`.
`:witness` is still the original, unshrunk failing sample; `:shrunk` is now the
minimal **in-domain** counterexample.

Two deliberate decisions in that three-line guard:

1. **Multi-arg candidate whose generator is not a `tuple-of` → retain.** For
   `arity > 1` the candidate is an argument TUPLE, but only a `tuple-of` carries
   a domain *per coordinate*. Feeding the raw vector to a non-tuple `gen-shrink`
   would let the walk shorten it (`AnyGen` → `shrink-candidates` → element
   drops) and change the call's arity — producing a malformed call whose raise
   the property would then read as a "failure". Retaining is the conservative
   answer; the realistic multi-arg domain is `tuple-of`, which *does* shrink
   coordinate-wise and in-domain.
2. **Unknown generator (a `Gen` with no `GenShrink`) → retain.** Handled inside
   `shrink-in-domain` (`gen-candidates` returns `[]`), so property needs no
   second check; an unknown domain offers no known-simpler value.

The module's stale header comment ("the classic ladder toward 0") was replaced
with the domain contract.

### 2.3 Soundness argument (why the result is still a counterexample)

The walk starts at `cex`, which is in-domain (it was sampled/enumerated from
`gen`) and violating (`fails?` held when it was selected). Every accepted step
is a `gen-shrink` candidate — in-domain and strictly simpler by construction —
gated by `fail?`. The fixed point is therefore in the domain and still
violating. Termination needs no fuel guarantee (every candidate is strictly
smaller); the fuel is a belt-and-braces bound.

---

## 3. The public ABI decision (source-backed)

- The removal was **unnecessary** and is **reversed**: `shrink-coords`
  `[fail? v]` is public again with its original body and contract.
- No other public symbol changed signature. `shrink-fail` was private before and
  after (renamed on promotion to `shrink-in-domain`); `shrink-candidates`,
  `shrink`, `samples`, the `Gen` protocol, the gen constructors, `check`,
  `exists`, `for-all`, `covers`, `faults`, `hypothesis`, `prove`, `shape-of` are
  untouched.
- `hypothesis` changed *behaviour* (a shrunk value can differ) but not its
  signature or its returned keys — `{:holds :witness :shrunk :result :crash}` is
  unchanged, and `:witness` still holds the original failing input.

---

## 4. Acceptance mapping

| requirement | where |
|---|---|
| property module reuses domain-aware candidates, not a blind ladder | `property.bl` `shrink` → `v/shrink-in-domain`; `smaller` deleted |
| removed public `shrink-coords` preserved | `veritas.bl` `shrink-coords` restored, original `[fail? v]` |
| no out-of-domain production in generator-aware paths | `shrink-coords` not used by `shrink-in-domain`/`run-sample`/property; `TupleGen` `gen-shrink` is the tuple source |
| unknown generators retain the original witness | `gen-candidates` → `[]`; `unknown-domain-retains-its-produced-witness` + `unknown-generator-retains-its-produced-witness` |
| bounded numeric | `numeric-shrink-never-leaves-its-bounds`, `numeric-shrink-walks-while-falsifying`, `real-shrink-stays-in-its-bounds` |
| finite one-of including nonnumeric | `one-of-shrink-stays-in-the-set-across-types` (`100 → "bb"`) |
| tuple | `tuple-shrink-keeps-arity-and-child-domains` |
| collection | `collection-shrink-keeps-its-length-bounds` |
| tag | `tag-shrink-stays-in-the-enum` |
| custom `NarrowUnknown` domain `[7]` | `unknown-generator-retains-its-produced-witness` |
| errors | `crash-witness-is-shrunk-inside-the-domain` |
| shrunk ∈ domain ∧ still falsifies ∧ witness retained | asserted in each of the above |
| standalone veritas invalid-zero witness example | `invalid-zero-witness-cannot-be-produced-standalone` (public walk, no escalator; also shows the blind ladder *does* return 0) |
| regression tests cover property module | `test/bl/veritas/property_shrink_domain_test.bl` |
| no global builds/tests | this worker ran none (§6) |

---

## 5. Tests

### 5.1 New — `test/bl/veritas/property_shrink_domain_test.bl`
ns `veritas.property-shrink-domain-test` (no z3 port needed; `hypothesis` is
sampled).

| test | asserts |
|---|---|
| `numeric-shrink-never-leaves-its-bounds` | `int-of 40 100000`, always-false property ⇒ `:witness 40`, `40 ≤ :shrunk ≤ 100000` |
| `numeric-shrink-walks-while-falsifying` | `int-of 0 100000`, `< 50` ⇒ `:witness 100000`, `:shrunk 50` (a real descent that stops at the boundary) |
| `real-shrink-stays-in-its-bounds` | `real-of 40.0 100.0` ⇒ `:shrunk ∈ [40.0, 100.0]` |
| `one-of-shrink-stays-in-the-set-across-types` | `one-of 100 "bb" 5` ⇒ `:witness 100`, `:shrunk "bb"`, and `:shrunk ∈ {100 "bb" 5}` |
| `tuple-shrink-keeps-arity-and-child-domains` | `tuple-of (int-of 0 100000)²` ⇒ arity 2, each coord `∈ [0,100000]`, sum still falsifies |
| `collection-shrink-keeps-its-length-bounds` | `coll-of 2 6` ⇒ `2 ≤ len(:shrunk) ≤ 6`, still falsifies |
| `tag-shrink-stays-in-the-enum` | `enum-of :on :off` ⇒ `:shrunk :off`, `∈ {:on :off}` |
| `unknown-generator-retains-its-produced-witness` | `NarrowUnknown` (`Gen`, no `GenShrink`) ⇒ `:shrunk 7 = :witness` |
| `crash-witness-is-shrunk-inside-the-domain` | a raising target ⇒ `:crash true`, `:shrunk ≥ 40` |

### 5.2 Extended — `test/bl/veritas/shrink_domain_test.bl`
Existing tests unchanged. Added:

| test | asserts |
|---|---|
| `invalid-zero-witness-cannot-be-produced-standalone` | on the PUBLIC walk (no `for-all`): `(v/shrink fails? 1)` is `0` (the blind ladder leaves the set), while `(v/shrink-in-domain (one-of 1 31 32 33) fails? 1)` is `1` and `≠ 0` |
| `shrink-coords-is-public-and-keeps-arity` | `v/shrink-coords` exists, preserves arity, result still falsifies |

The predicate in the standalone test (`(not (= n 7))`) is chosen so `0` **does**
falsify — without that, the contrast with the blind ladder would be vacuous.

---

## 6. Verification

**Run by this worker (static only — no VM, matching the established
worker/orchestrator split):**

- Token-level paren/brace/string/comment balance check over all four `.bl`
  files — every one ends at depth 0 with no negative dip
  (`veritas.bl` 909 lines, `property.bl` 244, `shrink_domain_test.bl` 96,
  `property_shrink_domain_test.bl` 118).
- Grep audit: zero remaining `shrink-fail` references anywhere in `priv/`,
  `test/`; zero `smaller` references in `property.bl`; `shrink-in-domain`
  reachable from `property.bl` as `v/shrink-in-domain`;
  `shrink-coords` defined public at `veritas.bl:545`.
- Hand-trace of every test's sample order, first failing witness and shrink
  fixed point against the generator implementations (§2.3 argument applied
  case by case).

**Not run by this worker (orchestrator gate):** no VM was started, so no
*runtime* proof exists in this artifact. The warm harness MCP
(`beam-lisp-harness/eval`) was unreachable (`Unable to connect`) — the same
limitation the previous worker recorded.

**Exact commands for the orchestrator** (bounded; after the library image is
rebuilt):

```sh
# the two suites this change owns
bin/bl test test/bl/veritas/shrink_domain_test.bl test/bl/veritas/property_shrink_domain_test.bl

# the veritas band that shares these surfaces (regression)
bin/bl test test/bl/veritas
```

Under a memory-bounded scope, as the review used:

```sh
systemd-run --user --scope --collect -p MemoryMax=4G -p MemorySwapMax=1G \
  env ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8' \
  bin/bl test test/bl/veritas/shrink_domain_test.bl test/bl/veritas/property_shrink_domain_test.bl
```

**Falsifiable expected observations:**

- `(v/shrink (fn [n] (not (= n 7))) 1)` ⇒ `0`.
- `(v/shrink-in-domain (v/one-of 1 31 32 33) (fn [n] (not (= n 7))) 1)` ⇒ `1`.
- `(v/shrink-coords (fn [p] (>= (+ (first p) (second p)) 10)) [12 7])` ⇒ a
  2-vector that still satisfies the predicate.
- `(p/hypothesis "(defn ident [n] n)" '(> result 100000) (v/int-of 40 100000) 20)`
  ⇒ `:holds false`, `:witness 40`, `:shrunk 40` (never `0`).

---

## 7. Regression risk to watch

- **`test/bl/veritas/property_test.bl`** — `false-property-shrinks-to-minimal`
  (`:shrunk 0` over `int-of 0 100`; 0 is in-domain, unchanged),
  `shrink-finds-boundary-not-first-hit` (`:shrunk ≥ 50`, unchanged),
  `crash-is-reported-not-swallowed` (`int-of 1 10`; `:shrunk` moves from the
  blind ladder's out-of-domain `0` to the in-domain `1`; the test asserts only
  `:holds`/`:crash`, so it still passes), `any-of`/`tuple-of` tests
  (`tuple-domain-refutes-and-shrinks` asserts `vector? :shrunk` — the tuple walk
  is unchanged in shape).
- **`test/bl/veritas/hypothesis_symbolic_test.bl`** — the z3 path is untouched;
  only `prove`'s *sampled fallback* (`untranslatable-falls-back-to-sample`)
  routes through the new shrink, and it asserts the engine, not a `:shrunk`
  value.
- **`test/bl/veritas/model_test.bl`** and `veritas.model` still use
  `v/shrink-candidates` — intentionally unchanged (a model witness is a
  history, not a generator's value).
- **`examples/veritas/05-the-property-is-behaviour.bl`** calls `hypothesis`
  with a **string** predicate (`"(int? result)"`), which `v/pred-form` rejects
  inside a `try`; every such predicate therefore reads as "fails". That is a
  pre-existing defect on the example surface (`property_test.bl` and
  `veritas_test.bl` have the same shape) and is **not** touched here.

---

## 8. Honest remaining limits (not fixed, not claimed)

1. **`hypothesis` over a multi-arg function with a non-`tuple-of` generator no
   longer shrinks at all** (§2.2 decision 1). It retains the witness. This is a
   deliberate soundness trade; the documented multi-arg domain is `tuple-of`.
2. **`StringGen`'s sample can leave its own domain.** `gen-sample` emits
   `(str prefix "ABCDEF")`, which can exceed `maxlen` — so a `:witness` can be
   out-of-domain before any shrink runs. Pre-existing generator defect, adjacent
   to this change but a different fix (a generator fix, not a shrink fix); not
   touched, and no `StringGen` case is asserted in the new tests.
3. **`IntGen` over an all-negative range shrinks weakly.** `gen-shrink` filters
   the walk-toward-0 ladder by `[lo,hi]`; for `int-of -100 -50` every ladder
   candidate is out of range, so the witness is retained. Sound
   (`:shrunk = :witness`, in-domain, still falsifying), but not minimal. A
   dedicated negative-range ladder is future work.
4. **Symbolic-rung verdicts still carry no `:shrunk`** (unchanged from the
   previous artifact): z3's model is projected in-domain, and there is no
   bad-shrink to fix there.
5. **`CollGen`'s element domain is length-only** — element shrinking is
   unconstrained beyond the length bounds, consistent with the generator's own
   contract.

---

## 9. Scope / risk

- Files written: `priv/lib/veritas.bl`, `priv/lib/veritas/property.bl`,
  `test/bl/veritas/shrink_domain_test.bl`,
  `test/bl/veritas/property_shrink_domain_test.bl`, this artifact. Nothing else
  touched.
- ABI: one public symbol **restored** (`shrink-coords`), one private helper
  renamed on promotion (`shrink-fail` → `shrink-in-domain`), one private helper
  removed (`property/smaller`). No public signature changed.
- No new dependency, no build-system change, no seed/AOT/codegen change.
- Linked org item: `PLAN-154-complete-clustered-performance-repairs-w`
  (lineage only, non-gating).
