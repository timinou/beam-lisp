# Engines over bl-ANF — prototype

**Question:** if the proof engines (`system.footprint`, `system.model`,
`system.smt`, `typed`, `termination`) read the bl-ANF the backend emits instead
of surface reader-node trees, what is gained, what does it cost, and what must
consumers change?

**Method:** `fp-anf.bl` re-expresses `system.footprint/fp-walk` over bl-ANF with
the *same* output contract (`{resource → mode}`), so `rung`, `pure?`,
`monotone?`, `commute?`, `frame-independent?` apply unchanged. A differential
corpus runs both engines over the same source. `cost_and_model.bl` measures walk
cost and proves an `:ann`-annotated node still validates, emits and runs.

Run:

```
mix beam_lisp.run --path priv --path . research/anf-engines/fp-anf.bl
mix beam_lisp.run --path priv --path . research/anf-engines/cost_and_model.bl
```

## Results (measured 2026-09-06)

### Precision: 9 of 28 corpus forms go from `:opaque-world` to exact

| form | surface | ANF |
|---|---|---|
| `(-> a deref inc)` | `{:opaque-world :W}` | `{"a" :R}` |
| `(-> a (swap! inc))` | `{:opaque-world :W, "inc" :W}` | `{"a" :W}` |
| `(doto a (swap! inc))` | `{:opaque-world :W, "inc" :W}` | `{"a" :W}` |
| `(->> tx (datom/transact! conn))` | `{:opaque-world :W, "conn" :A}` | `{"conn" :A}` |
| `(if-let [v (deref a)] v 0)` | `{:opaque-world :W, "a" :R}` | `{"a" :R}` |
| `(as-> (deref a) v (inc v))` | `{:opaque-world :W, "a" :R}` | `{"a" :R}` |
| `(some-> a deref)` | `{:opaque-world :W}` | `{"a" :R}` |
| `(cond-> x (> n 0) inc)` | `{:opaque-world :W}` | `{}` |
| `(for [x xs] (inc x))` | `{:opaque-world :W}` | `{}` |

Every surface `:opaque-world` here is a *macro the walker never expanded*.
The surface engine is not wrong — it is conservative because it re-implements
a fraction of the compiler. `(-> a (swap! inc))` is notable: surface also
reports `"inc" :W` — a **wrong resource name** (it treated the threaded arg
position naively). ANF names the right resource.

16/28 agree exactly. 3 differ in the other direction, all **ANF more sound**:

| form | surface | ANF | why |
|---|---|---|---|
| `(let [r (pick)] (swap! r inc))` | `{:opaque-world :W, "r" :W}` | `{:opaque-world :W}` | surface names a *local* as a resource; it is a computed value |
| `(let [r a] (swap! r inc))` | `{"r" :W}` | `{"a" :W}` | ANF alias env resolves the local to the global it stands for |
| shadowed `r` | `{…, "r" :W}` | `{:opaque-world :W}` | ANF respects scope |

The ANF engine needs one thing the surface engine never needed: an **alias
environment** (let-bound local → global it aliases; anything computed →
opaque). ~15 lines. This is the concrete cost of ANF naming every intermediate.

### Cost (µs per walk, mean of 2000, one 6-line body)

| step | µs |
|---|---|
| surface `fp-walk` | ~105 |
| `compile-node` → ANF | ~210 |
| `fp-anf` over ready ANF | ~250 |
| compile + `fp-anf` | ~550 |

≈5× per form when compiling on demand. Absolute numbers are microseconds; every
consumer that matters (`verify-process`, veritas) is dominated by z3 (ms). When
the engine runs *inside* the compiler pipeline the ANF is already built, so the
marginal cost is the ~250 µs walk. Not a concern; noted for honesty.

### Write-back: `:ann` is free real estate

`annotate` writes `{:footprint … :rung …}` into every node's `:ann`.
`anf/module` validates, `lower/descriptor->beam` emits, the module loads and
returns the right value. `lower.bl` reads only `:ann :line/:file`. **No backend
change is needed for engines to write proofs onto the IR.**

One real gate hit: `annotate` first produced a `LazySeq` for `:args` and
`anf/module` refused it (`must be a proper list`) — FEAT-039's eager contract
working as designed. Engines writing onto the IR must produce eager data.

### What the compiler already hands `system.model`

`compile-defserver` builds `:defn-clause` maps with `:params` (patterns),
`:guard` (ANF), `:body` (ANF) — exactly the `{:label :pattern :guard :next}`
tuple `model/extract-defserver` re-parses by hand in two dialects. The
descriptor for `__invariant__` is a clause too. The extractor collapses to a
projection over the descriptor.

## Tradeoffs (honest)

1. **Resource names are strings from author symbols in both engines.** ANF
   `:global` keeps `:ns` — the engine *could* key on `ns/name` and stop
   confusing two `balance` atoms in two namespaces. Surface cannot. Opt-in
   improvement; changing the key changes `frame-independent?` answers for
   consumers that compare across namespaces.
2. **ANF is post-macro.** Engines lose the ability to see *that* a `->` was
   used. Nothing in the current engines wants that. `system.model` wants
   `reply`/`recur`/`noreply` heads — in ANF those are `RT.invoke` of a global
   named `reply` (the server-body ctor-binding only applies inside
   `compile-defserver`). Model's next-state extraction must match on the
   ANF shape instead of a symbol head. Small, mechanical.
3. **Engines depend on the compiler.** Today `system.*` requires only `typed`
   + `reader-node`. After: `compiler`. Boot order: `compiler` is in the seed,
   so this is safe, but the engine tier now cannot be loaded on a raw reader
   alone. Acceptable — the point is *one* meaning.
4. **Pattern theories in `typed`.** `sum-types-are-shapes` binds solver sorts
   to surface shapes (`{:on 7}` literal maps, keyword variants). In ANF those
   are `:map`/`:lit`/`:pstruct` nodes — the same information, different
   accessors. Re-expression is mechanical but touches every rule.
5. **`smt/translate` is a source→SMT translator over reader nodes**, reused
   by veritas as "the same translator verify-process means". Moving it to ANF
   means veritas properties (authored as source strings, `pr-str`'d) must
   also be compiled first. Coherent, but veritas is the widest consumer.

## Consumer impact

Every consumer reaches the engines through one of two doors:

- **`typed/parse-clause` / `read1` → engine.** ~60 files (examples, tests,
  veritas, reload/ward/migrate, mcp tools, effects). They hand a *reader
  node*. After: they hand a *form* and the engine compiles it, **or** the
  engine keeps a reader-node entry that compiles internally. Choosing the
  latter makes the migration invisible to consumers: `fp-walk` keeps its
  signature, becomes `(fp-anf (compile-node node env))`.
- **`system.model/extract-*` → core/veritas.** The transition-graph shape
  `{:label :pattern :guard :next}` is the contract. Keep it; change only how
  it is derived (descriptor projection).

∴ Consumers need **no behaviour change** if the engines keep their entry
signatures and internalise compilation. Their *answers* change in exactly
the 12/28 cases above: 9 become precise, 3 become sound. Any test asserting
`:opaque-world` for a threaded/macro form is asserting a limitation and must
be updated — that is the acceptance criterion, not a regression.

## Not verified

- `termination` and `typed` re-expression (not prototyped; shapes inspected).
- Full-suite behaviour after cutover.
- Whether `system.model` next-state extraction over `RT.invoke reply` covers
  the `defmethod`/raw-`receive` dialects identically.
