# Model checking over bl-ANF (the last surface-coupled engine)

`system.smt/translate` was the last engine reading surface syntax
(`typed/node-*`) instead of the IR. This prototype translates **bl-ANF** to an
SMT formula — and inlines proven-pure helpers into the formula, closing the
Phase-4 soundness hole generally.

## Two costs of translating surface syntax

1. **Re-implements operator resolution.** `(>= balance 0)` is matched by NAME
   against a surface list. A macro that expands to the same arithmetic, or a
   qualified `erlang/>=`, is a different surface shape and is missed. The
   compiler already resolved every operator to a `[mod fun]` in ANF.
2. **Cannot see through a call.** A guard `(safe? balance)` where `safe?` is a
   pure helper is opaque to the surface translator — `:untranslatable`. A
   transition whose next-state is computed by a helper is silently dropped, and
   `verify-process` reports a bare `holds=true` (the Phase-4 hole).

## The ANF translator (research/model-anf/anf-smt.bl)

Operators arrive pre-resolved as `:remote [mod fun]` → one small total table. A
user call is a clear `(RT/invoke (:global f) args)` — so if `f` is **proven
pure** (`system.analyze` footprint = ∅), we look up its ANF body and **inline
it**, substituting the arguments.

### Measured: inlining pure helpers into the formula

| predicate | surface SMT | ANF-SMT |
|---|---|---|
| `(>= balance 0)` | `(>= balance 0)` | `(>= balance 0)` — agree |
| `(safe? balance)` | **`:untranslatable`** | **`(>= balance 0)`** — helper inlined |
| `(>= (margin balance reserved) 0)` | untranslatable | **`(>= (- balance reserved) 0)`** — nested inline |

### Measured: an invariant PROVEN through a helper (via Z3)

A server whose safety margin is a pure helper `margin(b,r) = b - r`, invariant
`I(b,r) := margin(b,r) ≥ 0`, transition `withdraw amt` guarded by
`amt ≤ margin(b,r)`:

| obligation | z3 | meaning |
|---|---|---|
| `I ∧ amt≥0 ∧ amt≤margin ∧ b'=b-amt ⇒ I[b']` | **unsat** | invariant **preserved** through the helper |
| same, guard dropped (negative control) | **sat** | invariant **can break** — z3 finds it |

The surface translator returns `:untranslatable` for the helper-computed
predicate and would drop the transition. The ANF translator proves it. This
turns the one-off Phase-4 completeness fix (`:complete`/`:unmodelled` signal)
into a **general** capability: any pure helper composes into the proof.

## Why this unlocks more (point 6, explained)

Effect summaries make SMT helper-inlining sound AND general because the inline
is *gated on the footprint proof*. A pure helper's body has no effects to model,
so substituting it into the formula changes nothing about the world — it is a
pure value computation, exactly what SMT reasons about. An impure helper is
correctly NOT inlined (it stays `:untranslatable`, honest). So the same
`system.analyze` summary that gates native offload (footprint = ∅) also gates
SMT inlining. One proof, two payoffs:

- **native**: a pure helper's callers become offloadable (whole tree native).
- **verification**: a pure helper's callers become *provable* (helper inlined
  into the SMT formula).

Both were blocked by the same wall — an opaque callee — and both are opened by
the same key: the inter-procedural footprint closure.

## The cutover this enables (no-mercy, point 5)

Once the ANF translator covers the model fragment, `system.model` /
`system.core`'s surface `delaborate` round-trips and the surface `translate`
walk are redundant: `verify-process` reads the defserver's compiled ANF, and
guards/next-states translate from `:remote`/`:if`/`:lit` directly. The
`delaborate`-for-DISPLAY use stays (rendering a guard for a human); the
`delaborate`-then-translate PATH dies. This is the same shape as the termination
and subst-sym cutovers already landed.
