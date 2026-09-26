# Proof log — the split showcase, track by track

Each entry says what was claimed, how it was checked, and the observed result.
Commands run from the repository root with
`BEAM_LISP_Z3=/usr/bin/z3 ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8'`. Screenshots are
real browser captures of `node research/js-actors/split-server.mjs`.

## Track 1 — higher-order client code (PLAN-148)

**Claim.** Client code may create, store, compose and call function values
(`comp`, `partial`, `juxt`, `complement`, `constantly`, `apply`, lambdas that
return lambdas, predicates folded into one), and recurse over data, while every
admitted client call chain provably terminates.

**Mechanism.** `compiler.bl` "function values: closure flow": 0-CFA over the
app's ANF with a runtime model derived from `runtime.bl`; every call cycle must
pass *capture order* or *structural descent* (README, "Client code is higher
order"). Supporting soundness fixes, each with native tests:

| Commit | Fix | Test |
|---|---|---|
| `9417427e` | a loop bound must be loop-INVARIANT (`(let [n (count xs)] (if (< i n) (recur (inc i) (conj xs 1))))` was accepted) | `termination_anf_test` `a-bound-must-be-loop-invariant` |
| `6e9de4d2` | `rest`/`next` shrink only under a non-empty guard (`(loop [s [1]] (recur (rest s)))` was accepted; confirmed to run forever on BEAM) | `a-sequence-step-needs-a-non-empty-guard` |
| `a77a356a` | footprints are the LEAST fixpoint (a recursive fn was opaque by its own first guess) | `analyze_test` `recursion-converges-to-its-real-effects` |

**Checks.**

| Check | Result |
|---|---|
| full build `./bin/bl run research/js-actors/compiler.bl` | exit 0, 53 OK diagnostics, PORTABLE HELPER PASS |
| split fixtures (`JS_ACTORS_SPLIT_ONLY=1`) | `SPLIT PASS placement derived, 13 refusals named, 4 higher-order fixtures admitted` — refused: omega, Y-combinator-style knot through `comp`, mutual recursion, recursion rebuilding its input, number recursion, effects in created lambdas; admitted: rank-two lambda, computing value, `juxt`/`comp`/`partial`/`complement`/`apply`, recursive tree walk |
| `node research/js-actors/verify-split.mjs` | `SPLIT PASS (23 checks)` incl. refine chips (open / open∧long / long / none) computed in the client with no proposal |
| `node research/js-actors/verify-order-parity.mjs` | `ORDER PARITY PASS (29 answers identical to BEAM)` — 11 new combinator/prelude cases |
| all 20 Node suites (`verify.mjs` + `verify-*.mjs`) | 20/20 pass |
| native suites | termination 26, analyze 50, footprint-anf 28, explain 41, native-eligible 11, incremental 11, check 49, prove 13, lsp 59, lsp-position 531, lsp-cli 8, growth 15, rewrite 52, smt 7+5+15+8+17 |
| independent probe of the gate (a separate agent, ~90 programs in 13 categories: capture through data/HOF/loops/rest lists; first/rest/lookup/guard/rebinding/swap/maps/vals/get-default attacks; runtime-model scan) | **no admitted non-terminating program**. One model gap found — `rt-spawn`/`rt-run-pid` hand functions to host leaves that call them — unreachable from client code, and closed anyway (`calling-host-leaves`) |

**Found by the differential, fixed.** `(apply f v)` with a vector raised on the
JS target (`listToArray`); `keep`/`mapcat` returned vectors where BEAM returns
seqs. **Documented divergence:** an empty lazy result is `=` nil on BEAM and
`()` here.
