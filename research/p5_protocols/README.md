# P5 — protocols, the checked-interface story: findings

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p5_protocols")
      BeamLisp.run_file("research/p5_protocols/run.bl")'
```

## The question

What is the checked-interface story for defprotocol/extend-type?

## Answers (all demonstrated in run.bl)

1. **Dispatch tags ≠ lattice tags.** Protocol dispatch runs on
   `Multi.type_of/1` (:integer, :binary, :seq, :tuple, :pid, struct
   modules…). The checker needs a TAG MAP; the map is deliberately
   partial — :list/:seq/:tuple/:pid/:reference/struct-modules have no
   lattice tag and claim NO coverage (sound, silent). Lattice-v2
   question surfaced: does the lattice grow :set/:list? (walk now
   handles set literals as `#{:set}`.)
2. **No-implementation warnings work**: `(area #{1 2})` with impls on
   :vector/:integer warns `3:4 area: no implementation of Shape for
   (:set)`.
3. **Precision when arg-1 is precise**: the ret is the union over only
   the impls whose dispatch tag meets arg-1's tagset — protocol calls
   type BETTER than multimethods (dispatch narrows the union).
4. **Completeness is structural**: `extend-type :integer Shape` missing
   `perimeter` warns `5:4 … missing methods: ["perimeter"]`.
5. **Open-world revocation, again**: an `extend-type :map` arriving
   later revokes a prior "no implementation for (:map)" — same
   fingerprint rule as P4, keyed (protocol, type-tag).

## Consequences for the design

- The **fingerprint/invalidation rule is now confirmed across both open
  dispatch mechanisms** — one mechanism (method-set fingerprint in the
  FEAT-002 cache key, sealing at DAG-end) covers multis AND protocols.
- The spike only pre-passes TOP-LEVEL protocol calls; the real checker
  hooks `walk-call` so nested calls type too (plan item, no research
  risk — the walk is already recursive).
- extend-protocol (multi-type form) follows the same walk as
  extend-type; not separately spiked (same rule shape).

## Deferred

- `satisfies?` as a guard that narrows to "has impl" (P15c-adjacent).
- Hierarchy/isa? is multis-only; protocols dispatch on exact tags.
