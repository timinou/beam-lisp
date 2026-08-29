# P8 — map shapes, go/no-go: findings

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p8_shapes")
      BeamLisp.run_file("research/p8_shapes/run.bl")'
```

## The question

Are literal map SHAPES (`{:ok int} | {:err string}`) worth it over
tag-level `:map`, and at what false-positive rate? (Motivated by P6:
kw-call/get results were the #1 surviving any on real code.)

## Verdict: GO — with the scoped rule set this spike validated

- **FP rate: 0** on the store corpus (store-map/overlay/ets, 415 lines
  of real protocol/store code) with shapes ON.
- **The mechanism pays where literals flow**: `{:ok (double 5)}` in one
  if-branch, `{:err "bad"}` in the other → union of shapes; downstream
  `(:err r)` types as `(:string :nil)` (nil because one member lacks
  the key — the sound rule); `(:missing r)` warns
  `7:6 key :missing is never present in [(:err) (:ok)]`.
- **The repr**: a shape is a first-class set element
  `[:shape {kw → tagset}]` beside the plain tags. Union = set union
  (several shapes = a union type). Meet merges per-key; a shape meets
  plain `:map` by surviving. Map literals keep `:map` too — the shape
  is EXTRA precision, so everything that worked still works.

## Soundness rules the spike pinned down

1. **Partial presence ⇒ nil in the union** (fixed mid-spike: the first
   version dropped it — unsound).
2. **"Key never present" warns ONLY on literal-derived shapes** —
   literal shapes are exact; anything param-bound has no shape, so the
   warning can never fire on unknown maps. Zero FP by construction.
3. **ns forms are not calls**: `(:require […])` is a keyword-headed
   list in DSL position and produced the spike's one FP — in BOTH the
   spike and `typed` (P3's corpus had no `:require`, so it hid).
   `check-source` now skips `ns` forms in both.

## The honest limit — and why P9 is the multiplier

Shapes originate at LITERALS. seam.bl's residue is param-bound maps
(`(get c :events {})` — `c` arrives from callers), which stay shapeless.
So shapes alone do NOT retire P6's residue; **shapes + the P9 schema
bridge do**: schema-known query results enter the checker WITH shapes,
and the union rules propagate them through user code. Also noted:
`^{:shape {:ok [int]} }` as an annotation surface is the declared-side
half of the same story (plan item).

## Deferred

- Shape elements through vectors/sets (`[:shape …]` inside collections).
- Shape-aware meet at fn-arg positions (declared-shape annotations).
