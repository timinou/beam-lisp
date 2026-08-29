# P12 — optics as the rule language: verdict

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("priv/specter")
      BeamLisp.Env.push_load_path("research/p12_optics")
      BeamLisp.run_file("research/p12_optics/run.bl")'
```

## Verdict: SPLIT, with optics owning shape

**Optics (specter navs) own SELECTION.** `[(codewalk*) (head* "recur")]`
replaces ~40 LOC of bespoke walker with a one-line path — parity
demonstrated (2=2 recurs). Even SCOPE CUTS are expressible as navs:
`within* #{"loop" "fn"}` visits a boundary form but never enters it —
exactly termination's "recurs of THIS loop" query (1=1, the inner
loop's recur correctly excluded). The cut is a descent decision, and
descent is what a navigator IS.

**Walkers own FLOW.** Guard narrowing, let-envs, clause order — anything
where the answer depends on an environment accumulated along the path —
stays in typed/promote/effects walkers. A pred nav sees a node, not a
context.

**Rewriting stays rewrite's.** codewalk/within are selection-only navs
(their transform* throws deliberately): rebuilding meta-carrying reader
nodes needs splice-aware reconstruction; deodorant's pattern→replacement
already owns that layer.

## Mechanics discovered (encoded in p12-code-navs.bl)

- Literal children are UNTAGGED values (`0`, `"s"`, `:kw` appear bare
  inside :list/:vector items); composites are `{:tag items}` tuples;
  meta wraps composites only. A code nav must handle all three shapes.
- `read_string` returns a LIST of nodes, not a node: codewalk descends
  bare collections without visiting them.
- The root of a select is always walked whole; cuts govern descent.
- Navs compose with the full specter vocabulary (`pred*`, etc.) —
  the rule language inherits it for free.

## Plan item

Graduate p12-code-navs → priv/code_navs.bl when the first consumer
refactors (termination's find-recurs is the natural first client).
Until then the navs live here as the measured answer.
