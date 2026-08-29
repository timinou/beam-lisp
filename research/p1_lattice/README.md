# P1 — core tag lattice: findings

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p1_lattice")
      BeamLisp.run_file("research/p1_lattice/run.bl")'
```

## The question

Can a tag-lattice inferencer over beam-lisp data forms stay small, run
fast, and catch real bug shapes with **zero false positives** on clean
code?

## Answers (all measured, not asserted)

- **LOC: 182** non-comment lines (`lattice.bl`) — under the 500 budget
  with room to spare.
- **Speed: ~800 µs warm for a whole file**, including re-parsing the
  source AND re-querying Env meta for signatures. The lattice ops
  themselves (set meet/union over ≤11 tags) are single-digit µs. Cold
  first run is ~27 ms (module/JIT warmup, not the checker).
- **Caught, one clear warning each**:
  1. disjoint argument — `(double "seven")` into `^{:args [int]}`
  2. unreachable branch — `(if (int? x) … (if (int? x) …))`, the inner
     then narrowed to `never`
  3. keyword called on a provably-not-map — `(:opts (double 5))`
- **Zero false positives** on the clean corpus (narrowed calls, let
  bindings, `some?` else-branches, annotated defs).

## Design confirmations

- **Tags as plain sets** (union = the type, meet = intersection, `never`
  = ∅) are enough. No bitmask needed at this scale; keep the repr until
  P10 says otherwise.
- **The P0 pipe carries real signatures**: `sigs-from-env` reads
  `^{:args :ret}` from `Env.meta` — the demo never re-declares anything
  for the checker's benefit. This is the invariant-8 loop closing.
- **Complement narrowing is sound for exact tags**: `else` narrows by
  set difference because the whitelist maps each predicate to its EXACT
  partition. Unlisted guard → no narrowing, no warning (contract holds).
- **`(U a b)` unions and `number`** parse from annotation data; fn types
  stay shallow (tag `:fn`, columns later).
- Warnings print the offending form with `pr-str` — delaboration (L12)
  is free when the internal repr IS source data.

## Deferred by design

- **Positions**: `read_all_data` strips FormMeta, so warnings name the
  form, not file:line:col. P2 owns position fidelity (reader with meta →
  evidence table, L1).
- **Deferred constraints** (L7): unknown callees are silently `any`
  today; the retry-after-load list lands with the real checker.
- **Deep fn types** (`(fn [int] bool)` columns), map shapes (P8),
  multimethods (P4): later rows.
