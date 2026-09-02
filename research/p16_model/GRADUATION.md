# P16 graduation — verification results

## Priv modules shipped
- `priv/footprint.bl` — effect-as-footprint {resource → mode}; refinement 1
  (pure ops name no resource); `rung` reproduces effects.bl's ladder; `op-rung`
  bridges to effects.
- `priv/model.bl` — transition extraction (5 forms → 1 graph) + naming
  trichotomy (binding / annotation / content-hash) + `system-model`.
- `priv/lib/system.bl` — the guarantee engine: prove-box · abduce ·
  all-senders-guarantee? · deadlocked · find-lasso + guarantee-catalog ·
  simulates? · migration-preserves? · footprint-in-caps? · spawn-footprint
  (refinement 2).
- `priv/std/effects.bl` — retrofitted onto footprint (one effect model, not two);
  output byte-identical to baseline; demo 06 still PASS.

## Tests (the assurances)
- `test/bl/system/model_test.bl`  — 4 tests / 10 assertions, PASS
- `test/bl/system/system_test.bl` — 15 tests / 30 assertions, PASS

## Demos
- `examples/system/01..08` — all run clean on the graduated priv APIs.

## Suite regression
Non-auth suite: **626 tests / 1705 assertions / 0 failures / 0 errors**
(includes the new system+model tests). The effects retrofit regressed nothing.

Pre-existing, OUT OF SCOPE: 64 errors in `auth.*` tests
(`undefined var: auth.biscuit.datalog/encode-block*`, defined at datalog.bl:528).
Reproduces in ISOLATION with none of the graduation changes loaded; the auth
commits (aadd592 …) are ancestors of the merge base 400d5d8. A foreign-session
load-order issue in the auth/biscuit module, not a graduation regression.

## Measured numbers (warm, bundled z3, direct harness)
| operation | time |
|---|---|
| extract a defserver → SystemModel | 21 ms (cold-ish; includes reader) |
| footprint of one form | 0.08 ms |
| inductive prove-box (2 transitions, z3) | 12 ms |
| abduce (400 candidates, z3 per candidate) | 111 ms |
| simulate one step (z3) | 3.6 ms |

z3 per-query ~2–6 ms (MVP-C's measured p50), so the arithmetic guarantees scale
with the number of transitions, not the state space — the whole point of proof
over search.

---

# P17 — the checker seam (2026-08-29)

The tier is now ONE package (`priv/lib/system/`, ns `system.*`) and a point-and-verify
checker, not a set of libraries you hand-feed.

## Package
- `priv/lib/system/footprint.bl` → `system.footprint`
- `priv/lib/system/model.bl`     → `system.model`
- `priv/lib/system/smt.bl`       → `system.smt`   (source→SMT-LIB translator)
- `priv/lib/system/step.bl`      → `system.step`  (:~step as a defrelation)
- `priv/lib/system/core.bl`      → `system.core`  (guarantee engine + the seam)

## The seam
- `(system/verify-process port node)` — annotate a defserver name with
  `^{:invariant …}`, get `{:name :holds :checked :warnings}`. No hand-written SMT.
- `(system/verify-file port file src)` — every process form → rendered
  `file:line:col` + caret warnings (via errors/render).
- message coverage: `handled-labels` / `unhandled-messages` / `sent-to-labels`.
- dispatch determinism: `guards-overlap?` / `nondeterministic-pairs` (z3).

## Tests
- `test/bl/system/seam_test.bl` — 9 tests / 25 assertions, PASS.
  (model_test 4/10 + system_test 15/30 + seam_test 9/25 = 28 tests / 65 assertions.)

## Demos
- `examples/system/09_point_and_verify.bl` — the flagship: annotated server
  proves true, buggy one renders a caret'd warning, unhandled message caught.
  All 9 examples/system demos run clean.

## Regression
Non-auth suite: **635 tests / 1730 assertions / 0F 0E** (auth still pre-broken,
out of scope). The package reorg + seam regressed nothing.

## Numbers (P17)
| operation | time |
|---|---|
| verify-process (full seam, 2 transitions, z3) | 24 ms |
| smt translate one compound guard | 1 ms |

Bugs fixed at root: extract-defserver dropped :when guards; verify-process
conflated init-establishment with preservation; state-vars picked the operator
symbol (>=) instead of the state var; abduce's double check-sat (earlier).

---

# P18 — richer state models (2026-08-29)

State is no longer one integer. verify-process reads each field's z3 SORT from
the init state and proves the invariant over the whole shape. The whole ladder
graduated, each rung as tests + a demo.

## The ladder (all shipped)
| rung | state model | function | warm |
|---|---|---|---|
| 1 · multi-var | tuple of ints, relational invariant (balance ≥ reserved) | verify-process | 21 ms |
| 2 · records | mixed-sort record (int × bool), (frozen ⇒ balance=0) | verify-process | 23 ms |
| 3 · collections | capacity via length abstraction (count ≤ 10), EXACT | verify-capacity | 19 ms |
| 4 · sum types | phase-coded variant, session-type conformance (send ⇒ open) | verify-process | 17 ms |
| ★ discovery | invariant from nothing, Houdini fixpoint | discover-invariant | 99 ms |

## Mechanism
- `system.core/state-shape` reads field order + per-field sorts from the init
  state: vector → positional Int (Rung 1); map → named fields, false/true → Bool
  else Int (Rung 2); bare symbol → one Int. N=1 all-Int is the special case.
- `inv-define-fun` / `preserves-joint?` / `establishes-joint?` declare each field
  (and its primed copy) at its own sort; the invariant is a z3 define-fun, so
  priming the whole state needs no textual substitution.
- `system.smt/translate-len` abstracts a collection to its length: (count c)→c_len,
  (conj c x)→(+ c_len 1), (rest c)→(- c_len 1), (empty? c)→(= c_len 0), []→0.
  Capacity is EXACT; content (no-duplicate) stays untranslatable → the bounded
  Rung-3(b) companion. guarantee-catalog keeps exact vs approximate apart.
- `discover-invariant` is a Houdini fixpoint over candidate-invariants: establish
  filter (holds-at-init, also makes the seed consistent) BEFORE induction. State
  vars without an invariant come from the transitions — a message INPUT is bound
  by its pattern, a STATE VAR appears in guards/nexts but no pattern.
- A sum-typed variant is a phase = integer-coded enum; protocol conformance is
  Rung 1 over the phase var, through the same verify-process (no new checker).

## Root-fixed bugs (found by a rung disagreeing with an obvious case)
- errors/delaborate had no :map / :keyword case → record :next rendered as a raw
  {:map,…} tuple. Added both.
- free-syms declared the boolean literals true/false as Int inputs, shadowing
  SMT's true/false and silently breaking any transition assigning a bool literal.
  Excluded them (they are VALUES). Hardened Rung 2 as well.

## Tests + demos
- test/bl/system/seam_test.bl grew 9 → 21 tests (25 → 55 assertions).
- examples/system/10–15 (multivar, record, collection, protocol, discover,
  type-directed) — all 15 system demos run clean.

## Regression
Non-auth suite: **647 tests / 1760 assertions / 0F 0E** (auth still pre-broken,
out of scope). All rungs regressed nothing; N=1 stayed a true special case.

## Infra note
priv/*.bl compile into ebin at build; a prelude ns (errors, typed) or a lazily
required ns edit needs `mix compile.beam_lisp` (and MIX_ENV=test for the suite)
before the direct-elixir harness sees it. Learned the hard way when a delaborate
edit appeared inert.

---

# P19 continuation — sum types, gfp, clause facts, synthesis (2026-08-29)

Built out the whole remaining PLAN-051 ladder. Five capabilities, each graduated
as tests + a demo, all through the checker.

## R1a/R1b — sum types are shapes (one unified scheme)
The tag is structural, not a reserved key. A variant value is read by shape:
`:paused` (nullary arm, the tag is the keyword), `{:on 7}` (payload arm, the key
is the tag). A field holding either is a sum type; the enum (R1a) is the
all-nullary special case. Sum-vs-product falls out of field-shape heterogeneity.
- z3 datatype: `(declare-datatypes () ((E_mode E_mode-paused (E_mode-on (E_mode-on.val Int)))))`.
  No-junk axiom fences the field to exactly its arms — no phase=99 leak an Int allows.
- Discriminate/access are ordinary bl map ops that ALSO translate: `(= x :paused)`
  → nullary test, `(some? (:on x))`/`(is? (:on x))` → `((_ is E_mode-on) x)`,
  `(:on x)` → `(E_mode-on.val x)`. An invariant evaluates as bl AND verifies as z3.
- Root fix: RT.get is now nil-safe on non-associative values (Clojure-compat) so
  `(:on :paused)` is nil, making the discriminant total in plain bl. `is?` added.
- Constructors excluded from z3 inputs; an input feeding a variant field is a
  payload scalar (default Int), never the datatype (two false-positive bugs fixed).
- Demos 13 (enum protocol + datalog phase graph), 19 (payload dimmer).

## R2 — the greatest-fixpoint primitive (system.gfp)
The dual of datom's least-fixpoint recursion: seed full, shrink to the largest
stable set. One driver hosts Houdini discovery (z3 decision), CTL safe-regions
(pure relation), bisimulation/minimization (structural). gfp + gfp-delta
(semi-naive, counts checks) + gfp-explained (provenance log). Ready-made
safe-region + bisimulation wrappers over a transition system. Demo 20.
Soundness obligation (survives? monotone in the set) documented, not checked.

## R4 — clause topology as datom facts (system.facts)
model.bl's clauses projected into datom facts so the STRUCTURAL invariants are
datalog queries, not hand-walks (engine split: datom owns structure). handled-
labels / always-fireable (unguarded = total handler) / guarded-only (partial) /
guard-preconditions (the precondition spec read from :when, not annotated).
Dependency-injected like the coverage helpers. z3 never runs. Demo 21.

## R5 — capacity synthesis (the verifier backwards)
verify-capacity CHECKS an annotated (count c ≤ k); synthesize-capacity DISCOVERS
the smallest inductive k. k-inductiveness is monotone, so the smallest inductive
k is the exact capacity. Guarded queue → synthesized 5; unguarded → honestly
:unbounded (never a wrong number). The annotation becomes an output. Demo 22.

## Also: the string-round-trip smell + docs
- model.bl clauses now carry reader NODES; the SMT path translates them directly
  (no delaborate→re-read round-trip — the source of the earlier quoting bug).
  Dead single-var string helpers deleted (inv-fn/replace-var/parse1/keep-
  translatable/input-decls).
- The demo/test defserver-as-STRING is NOT the smell: `quote` yields a
  position-less scalar (no file:line:col, name→content-hash), so read_string is
  the only source of the position-bearing reader nodes the checker needs.
- Docs rewritten timeless per docs/AGENTS.md (how-it-is, not what-was):
  how-state-picks-its-theory.bl.md, sum-types-are-shapes.bl.md.

## Regression
Non-auth suite: **680 tests / 1833 assertions / 0F 0E** (P19 start 647/1760).
All 22 examples/system demos run clean. New system tests: gfp_test (9t), facts_
test (5t), seam_test grew to 40t/105a.

## Commit chain (P19 cont)
9f5d08b(is?/nil-safe get) → 342011b(R1b) → b573316(R2 gfp) → 451bc23(R4 facts)
→ af2c7c7(R5 synth). Prior R1a: 0451a8e.
