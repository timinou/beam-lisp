# P4 — multimethods, sealed vs open: findings

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p4_multimethods")
      BeamLisp.run_file("research/p4_multimethods/run.bl")'
```

## The question

Sealed-world vs open-world: what does EXTENSION invalidate?

## Answer — demonstrated, not asserted

World v1: `area` has two int-returning methods; `(shout (area …))` with
`shout` declared `^{:args [string]}` warns (ret `#{:int}` disjoint from
`string`) — **sound in v1**. Then a string-returning `:default` method
arrives (the classic open-dispatch move from examples/multimethods.bl).
Re-checked: the warning is **revoked** — union widened to int|string,
meet non-empty. Fingerprint grew 2 → 3.

**The rule**: a check that consumes a multi's return is valid only at
the method-set fingerprint it was computed under. Adding a method
invalidates every dependent check. Warnings can only ever be REVOKED by
extension (widening kills provability), never created — but a revoked
warning is a wrong warning, and the contract forbids those.

## Consequences for the design

- **Open world is the default; sealing happens at DAG-end** (L7's
  require-DAG) and at AOT time: when the load graph closes, method sets
  are exact and multi-consuming warnings become sound. This is the same
  shape as deferred constraints — unify them.
- **Fingerprint = the set of (multi, dispatch-val) pairs.** Cache keys
  (FEAT-002) for any analysis consuming a multi ret must include it.
- **The checker needs runtime truth**: methods can be added dynamically
  (hot reload). `BeamLisp.Multi` stores tables in ETS with no public
  reader — implementation plan adds `Multi.method_table/2` (tiny; the
  checker and P7's reload rules are both consumers).
- **defmethod has no annotation surface** — method bodies are walked
  with params at `any`. A `^{:args …}` on the method name is the
  natural extension; compiler support is a plan item.
- Dispatch-value coverage ("is `:pentagon` handled?") needs keyword-set
  analysis — P8-adjacent, v2.

## Deferred

- Hierarchy-aware dispatch (derive/isa?) at the type level.
- Multi-argument dispatch (`collide`) — same union rule applies, spike
  demonstrated the 1-argument case.
