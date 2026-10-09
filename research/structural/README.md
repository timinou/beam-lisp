# Logic-backed structural efficiency spikes

**Verified research, not production defaults.** Five independent agents authored the mechanisms; integration review and executable/adversarial gates hardened them. No `priv/` code, seeds, application code or deployment was changed.

- Branch: `perf/structural-efficiency-spikes`
- Worktree: `/home/user/.cache/bl-structural-spikes`
- Pinned base: `54e4c6134565d5aa921e6d55ec0e7c57bd429f62`
- Origin/execution: PLAN-165 / PLAN-166
- **Measured record:** [results.json](results.json)
- **Final production strategy:** [strategy.md](strategy.md)
- **New prerequisite:** BUG-115, bulk Env deletion does not advance the lookup epoch.

## Results

| Spike | Observed result | Decision / boundary |
|---|---|---|
| [Dependencies](dependencies.md) | A two-column projection reads 12 store rows initially, **0 after an unrelated write**, 14 after a relevant write. | Promote a single dependency-certified projection mechanism. Current adapter is a closed single-store read plan, not arbitrary-function tracing. |
| [Bounded data](bounded.md) | Native Fjall rank page reads/returns **2 rank rows**; unrelated corpus growth does not change posting-restricted work. Sparse permissions, cursor/retry/retraction boundaries and wide ETS fallback refusal are checked. | Promote capability/admission contracts and maintained ordered/authorized indexes. General multikey scoring is still posting-wide; visibility/authorization point reads are separate work. |
| [Lookup](lookup.md) | Stable traversal makes **1 refresh instead of 4,000**, but wrapper takes **3.09–3.39× more reductions** than baseline. | **Reject this extra cache layer.** Improve the existing Env/kernel path only after complete mutation/stamp coverage. |
| [Consumer](consumer.md) | Across 200 runs, baseline **1,289,037** versus lowered **74,146** caller reductions (**17.39×**), both returning 4. | Extend the existing central optimizer with a checked private-consumer law; current closed adapter is not a shipped rule or proof of live callee resolution. |
| [Realm AOT](realm.md) | A real BEAM compiles once, then loads from cache; initialization is once per open generation. Isolation, key changes, corruption fallback, marker replay, segment ownership and purge are checked. | Implement FUP-155 per-segment AOT in the real loader. Current adapter is sequential and descriptor-based, not arbitrary namespace/macro/race coverage. |

“Impossible by design” is an **admission property**, not a blanket performance promise: unsupported/unknown cases keep the authoritative path or explicitly refuse/incomplete. A partial, stale or unauthorized answer is never a substitute for an expensive exact one. A bounded/idealized model theorem is not a universal runtime certificate.

## Logic instruments

The spikes genuinely exercise `veritas` finite exhaustive queries, `smt`/`z3` obligations and modal verdicts, existing `system.ir` self-scaffold recognition, `system.footprint`, and central optimizer explanations/refusals. They also use actual datom stores/counters, authoritative Env operations and descriptor-to-BEAM/AOT cache APIs.

Negative controls include omitted empty-read dependencies, last-commit-only coalescing, frozen/epoch-only lookups, fixed `6*k` post-filtering, false/nil consumer results, observable predicate overscan, segment-blind AOT keys and repeated initialization. Unknown/truncated/undecided is not proven. Large finite Cartesian generators must not be mislabeled symbolic proofs; explicit symbolic obligations now use SMT directly.

## Verification receipt

**1,030 assertions collectively passed:**

- Research: dependencies 91; bounded 133; lookup 61; consumer 88; realm 72; metrics 14.
- Existing regressions: Env fetch memo 12; reduce kernel cutover 134; optimizer lexical prototype 336; realm namespace 15; datom cost 74.

Evidence:

- `artifact://1598ead9f02e4261/main/bash/371.txt`: combined gate, metrics and five existing regression files. Ten files passed; realm had an old-code inspection API typo (`code/check_old_code`).
- `artifact://1598ead9f02e4261/main/bash/373.txt`: corrected to the Erlang BIF, final realm **72 assertions passed**, exit zero.
- `artifact://1598ead9f02e4261/main/bash/378.txt`: final conservative totality gate, consumer **88 assertions passed**. Pure strict boolean BIFs are refused without operand type proof; their valid-first-call/raising-tail cases are checked.

The original combined command did not exit zero; do not cite it as a clean run. The final corrected realm run completes the collectively passing set. No full-repository suite or new Knowledger render benchmark was run. Wall times are not app performance evidence: host RAM/swap/load varied heavily.

## Reproduce

Use this checkout's `bin/bl`. Inspect memory first; never stop unrelated VMs. Run one capped process for the batch, not one VM per file:

```sh
scripts/bl-mem
systemd-run --user --collect --wait --pipe --working-directory="$PWD" \
  --setenv=BL_DAEMON=off \
  --property=MemoryMax=8G --property=MemorySwapMax=2G \
  --property=RuntimeMaxSec=1200 \
  ./bin/bl --cold test -p . \
  research/structural/dependencies_test.bl \
  research/structural/bounded_test.bl \
  research/structural/lookup_test.bl \
  research/structural/consumer_test.bl \
  research/structural/realm_test.bl \
  research/structural/metrics_test.bl \
  test/bl/env_fetch_memo_test.bl \
  test/bl/reduce_kernel_cutover_test.bl \
  test/bl/optimizer_lexical_prototype_test.bl \
  test/bl/realm_namespace_test.bl \
  test/bl/datom/cost_test.bl
```

`metrics_test.bl` loads [run.bl](run.bl), emits `STRUCTURAL-SPIKE-RESULTS` once and checks result/work mechanisms without demanding an invented speedup. The driver can also run as `./bin/bl --cold run -p . research/structural/run.bl` under the same cap.

Current `z3/open` is a supervised oracle handle, not a private raw OS port. Use existing lease/conversation APIs; there is no fabricated `z3/close` API. Verification VMs and their solver resources terminate; no server/daemon is started by these spikes.

## Production sequence

1. Close mutation/read-certificate invariants and introduce admitted work contracts.
2. Cut over dependency-aware projections and ordered/authorized data reads using existing datom facilities.
3. Integrate certified live relevance with a sticky dirty/flush protocol; unknown still renders.
4. Add the checked consumer law inside the central optimizer, not the research adapter as a second pass.
5. Ship realm-local AOT as an independent startup/DX track.
6. Revisit lookup generated/kernel fast paths only when matched work measurements improve.

Rebase onto current main and re-gate before production integration. Preserve pinned snapshot consistency, current permissions/expiry and egress checks, live rebinding, lazy cycle/admission behavior, target-env initialization and active module leases. See strategy.md for precise implementation seams and outstanding obligations.
