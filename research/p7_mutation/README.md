# P7 — mutation: per-swap! invariants, reload, defserver: findings

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p7_mutation")
      BeamLisp.run_file("research/p7_mutation/run.bl")'
```

## The questions

(a) per-swap! invariants at tag tier? (b) what does hot reload do to
type tables? (c) defserver state typing?

## Answers

1. **Atoms carry per-var inner-tag invariants** — an atom table built
   from `(def a (atom init))`. `swap!` requires the fn's ret to meet
   the inner type; `reset!` the value; `deref`/`@a` YIELDS the inner
   type (that's the payoff: `@counter` is `(:int)` downstream).
   **nil-init → any**: the "set later" idiom; warning there would be
   an FP factory.
2. **Reload = re-derivation, keyed exactly like Env.** Re-checking a
   file after its `(def a (atom …))` changed REPLACES the table entry;
   warnings computed under the old inner type simply don't reappear.
   No invalidation machinery needed beyond "rebuild from source on
   load" — because type tables are derived, never owned. (Contrast
   P4/P5, where the RUNTIME owns the method set and fingerprints were
   needed. Atoms are re-created by reload; multis persist.)
3. **defserver state typing works at tag tier**: init's body gives the
   state type; every `reply`/`noreply` state position in every handler
   must meet it. `(noreply "not-a-map")` under a map state warns at
   the exact form (6:8).

## Demonstrated

- clean atom use (swap! inc, @counter, nil-init + reset!): 0 warnings
- violations: `swap! counter2 str` and `reset! counter2 "nope"` each
  warn with both sides named
- reload: v1's warnings gone after `(def counter2 (atom "s"))`
- defserver: state mismatch caught; guard-tolerant clause parsing

## Deferred / limits

- Spike checks top-level mutation forms; graduation hooks the atom
  table into `typed/walk-call` so body-level `swap!` (the real case —
  atoms.bl does it inside a `loop`) is checked too. No research risk:
  the walk is recursive, the table is global.
- future/promise/pids stay `any` (no lattice tags for them; a future's
  deref could be body-typed — v2).
- Effect lattice (purity: which fns swap!/spawn/send at all) is P15c.
