# P2 — positions × macros: findings

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p1_lattice")
      BeamLisp.Env.push_load_path("research/p2_positions")
      BeamLisp.run_file("research/p2_positions/run.bl")'
```

## The question

Do FormMeta positions survive the checker pipeline through macro-shaped
code — without macroexpanding the common cases?

## Answers

- **Positions survive everywhere**: the reader wraps every composite
  node in `{:meta, node, %{line col file}}`. Warnings carry line:col of
  what the user wrote — including through `->>` (warns at the `(double)`
  STEP, 8:26), `when` (15:11) and `cond` (23:19).
- **The whitelist that covers the corpus**: `when`, `when-not`, `cond`,
  `and`, `or`, `->`, `->>` — walked structurally, never expanded.
  Unknown macros go through `Compiler/macroexpand_1` (the compiler's own
  oracle: expansion ≠ input ⟺ it was a macro), keeping the OUTER
  position; generated nodes honestly carry none.
- **Evidence table works** (L1 preview): 17 entries keyed `[line col]`,
  `hover` delaborates `#{:int}` → `(:int)` (L12: never print the
  internal repr raw). Synthesized threading nodes are recorded at the
  step the user wrote — the InfoTree move.

## Hard-won mechanics (these cost real debugging)

1. **Meta wraps composite nodes only** — and helpers must peel it.
   First version missed every bug because `walk-if`'s test and each
   `->>` step arrive meta-wrapped; `node-items` on a meta node returns
   the inner tuple, not its items. Fix: `node-form` peel + meta-
   transparent `node-items`.
2. **Synthesized nodes need INJECTED positions**: desugared thread calls
   are bare tuples; each is wrapped in `{:meta, _, step-pos}` so
   warnings and evidence point at the user's step, not nowhere.
3. **bl has no tuple literal**: `[:list …]` is a Vector STRUCT (erlang
   fns reject it), `{:symbol …}` is a MAP. Nodes are built via
   `erlang/list_to_tuple` over a real list. (`identical?` against a
   freshly rebuilt tuple is always false — compare against the ORIGINAL
   object, or macroexpansion loops forever on non-macros.)
4. **Soundness lesson, demonstrated**: an annotated defn in a
   NEVER-RUN file has no sig in Env — the contract correctly stays
   silent. Bugs must be provable from literals or loaded namespaces.
   (This is exactly the L7 deferred-constraint shape: check the file,
   defer what its own annotations would resolve, retry after load.)

## Deferred

- Whitelist growth policy: cover corpus macros by frequency (P10 survey),
  expand the rest; expansion nodes stay position-orphaned until macros
  learn to stamp `{:meta …}` themselves (a macro-authoring convention
  worth adopting in core).
- `loop`/`recur` bodies (P1 covers `let`; termination is P15d).
- defmulti/defmethod dispatch (P4).
