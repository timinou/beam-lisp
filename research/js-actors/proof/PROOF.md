# Proof log — the split showcase, track by track

Each entry says what was claimed, how it was checked, and the observed result.
Commands run from the repository root with
`BEAM_LISP_Z3=/usr/bin/z3 ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8'`. Screenshots are
real browser captures of `node research/js-actors/split-server.mjs`.

## Track 1 — higher-order client code (PLAN-149)

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
| `node research/js-actors/verify-order-parity.mjs` | `ORDER PARITY PASS (29 answers identical to BEAM)` — 11 new combinator/prelude cases (30 after the main merge: + sequential family) |
| all 20 Node suites (`verify.mjs` + `verify-*.mjs`) | 20/20 pass |
| native suites | termination 26, analyze 50, footprint-anf 28, explain 41, native-eligible 11, incremental 11, check 49, prove 13, lsp 59, lsp-position 531, lsp-cli 8, growth 15, rewrite 52, smt 7+5+15+8+17 |
| independent probe of the gate (a separate agent, ~90 programs in 13 categories: capture through data/HOF/loops/rest lists; first/rest/lookup/guard/rebinding/swap/maps/vals/get-default attacks; runtime-model scan) | **no admitted non-terminating program**. One model gap found — `rt-spawn`/`rt-run-pid` hand functions to host leaves that call them — unreachable from client code, and closed anyway (`calling-host-leaves`) |

**Found by the differential, fixed.** `(apply f v)` with a vector raised on the
JS target (`listToArray`); `keep`/`mapcat` returned vectors where BEAM returns
seqs. **Documented divergence:** an empty lazy result is `=` nil on BEAM and
`()` here.

## Merge — main's bootstrapped runtime (`3b48176f`)

**Claim.** The JS target follows main's runtime move to `priv/boot/rt.bl`
(`BeamLisp.Ns.Rt`) with no loss.

**Checks.** The parity differential caught the two semantic changes the merge
brought — lists and vectors are one sequential family under `=`/`compare`
(map keys stay distinct), and empty `sort`/`take` are `()` — and a frontend
change (`__STACKTRACE_RAW__` bound around catch bodies) broke 11 Node suites
until the JS catch block bound it. After the fixes: build exit 0, 53 OK, SPLIT
PASS, PORTABLE HELPER PASS, 20/20 Node suites, `ORDER PARITY PASS (30 answers)`
with a new `sequential-family` case.

## Track 2 — recursion over data (PLAN-149)

**Claim.** An app may declare a recursive snapshot type and walk it with
ordinary recursion in both halves; every admitted walk terminates, the wire
stays bounded, and the app is a real product: a nested project plan.

**App.** `apps/outline.bl` — phases → tasks → steps. Progress roll-ups
(`tally`), search that keeps the ancestors of a match and highlights it
(`prune`, `marked-text`), fold/expand and inline "+ step" run in the browser
with no network; add, tick (the whole branch at once) and remove go to the
server, which rebuilds the path to one item.

| Check | Result |
|---|---|
| split build (`JS_ACTORS_SPLIT_ONLY=1`) | `SPLIT PASS outline: 14 placements, 12 recursion proofs, 5 refusals named` (walk on itself, re-wrapped item, growing search text, list-less recursive type, 25-deep type) |
| `node research/js-actors/verify-outline.mjs` | `OUTLINE PASS (22 checks)`: recursive contract + digest, placements and `structural` proofs, no server code in the client bundle, codec depth bound (24 ok / 25 refused, BL = JS), the bound equal in three files, HTTP adds/refusals (`no-such-item`, `too-deep`), subtree toggle both ways, subtree removal, SSE fan-out, BL client: tally text, fold with no proposal, search keeps ancestors + `em` highlight, empty search, inline add proposes and commits, toggle proposes |
| real browser, port 8792 | fold/expand, search `magic` → Build › Sign-up flow › Magic link with `Magic` highlighted; inline add focused on open, Enter commits rev 1; ticking Research ticked its 6 descendants; search-render latency 43–144 ms per keystroke. Screenshots: `track2-outline.png`, `track2-outline-search.png` |
| **found in the browser, fixed** | while searching, roll-ups counted only the matching branches ("Build 0/2"); they now count the whole branch (`Build 1/5`) |
| independent red-team (a separate agent, ~60 programs: lookups of call results, map-as-fn, keyword in a local, `get-in`, defaults, mutual :part/:le cycles, arity mixes, loops in cycles, case patterns) | **no admitted non-terminating program**. Soundness of ":part counts as :le": every read `sub-rel` recognizes returns a subterm or nil; anything that can grow (`conj`/`assoc`/`cons`/`into`/literals/`str`) carries no relation and refuses the edge. Found and FIXED: a non-recursive type nested past the bound was admitted though no value could pass (now refused); `(nth coll i default)` was read as a lookup (only 1–2 argument reads count now). Reported and REJECTED on inspection: "a `case` symbol pattern is read as a binder". The compiled ANF shows `(case (conj it []) it (cand it) 0)` tests equality against the LOCAL `it` (`{:op :var :name "it_…"}`) — no binding happens, and `(cand it)` recurses on an element, which is genuinely structural |
| full build + all Node suites | build exit 0, 53 OK, SPLIT PASS (showcase + outline), PORTABLE HELPER PASS, parity 30, 22/22 Node suites |
