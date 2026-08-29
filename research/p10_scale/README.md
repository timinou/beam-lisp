# P10 — scale: findings

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p10_scale")
      BeamLisp.run_file("research/p10_scale/run.bl")'
```

## The question

Full-repo check < 1s cold, ~0 on cache hit?

## Numbers (datom closure: 31 files, real production code)

| | time | warnings | evidence entries |
|---|---|---|---|
| cold | **354 ms** | **0** | 5 789 |
| warm (content-hash skip) | **5 ms** | — | — |

Per-file spread: 1–58 ms (engine.bl, the 700-line query engine, is the
outlier). Well under the 1s bar at 31 files; linear extrapolation puts
a 300-file repo at ~4 s cold and ~0 warm — acceptable for a
check-on-save / pre-commit shape, with the FEAT-002 cache keying
analysis (L8 .olean precedent) rather than re-walking.

## The warnings audit was the real work

The first run reported **11 warnings on production code** — every one
audited, every one a CHECKER bug, all fixed at root:

1. **6× `(:require …)` FP** — keyword-headed lists in ns-DSL position
   aren't calls. The P8 fix had landed on the wrong branch of the
   top-level dispatch (ns fell THROUGH to walk); now skipped outright.
2. **2× `get` on a vector** — the seed declared arg1 `#{:map}`; bl's
   `get` is index-access on vectors and sets too. Widened.
3. **2× `mapv :kw`** — keywords are callable (kw-call); all HOF seeds
   now accept `#{:fn :kw}`.

Lesson for the seed discipline: a seed that is too narrow is an FP
factory on real code. Sound-conservative cuts BOTH ways — over-narrow
declared args are as wrong as over-wide ones. (This is the P14
substrate connection: smells' :when guards have the same shape.)

## Consequence

P9 ✓ + P10 ✓ ⇒ **MVP-B (codebase as database) graduates next.**
