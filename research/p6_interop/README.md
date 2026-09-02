# P6 — interop precision: findings

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.run_file("research/p6_interop/run.bl")'
```

## The question

Does a ~50-entry seed table recover the 90% case? Corpus:
examples/interop.bl + spell's apps/interface/src/interface/seam.bl
(286 lines of real seam-walking code).

## Answers (measured over evidence-table entries still `any`)

| corpus | bare | with seeds | warnings introduced |
|---|---|---|---|
| interop.bl | 12/27 any | 7/27 | 0 |
| interface.seam | 106/27… 106/113 (94%) | 63/113 (56%) | 0 |

## The hypothesis shifted — and that IS the finding

The plan expected the leak at *Elixir-stdlib* calls. The corpus says
otherwise: seam.bl makes almost no `Module/fn` calls — its precision
leak is **unseeded CORE fns** (map/keys/sort/name/keyword/boolean…).
The seed table that matters is core-first; the ~20 host seeds cover the
interop.bl shape.

**Verdict: YES for call-shaped precision** — 49 anys eliminated on
seam, 0 warnings introduced (both files are clean; any warning would
have been a seed-induced FP).

## The residue is not seed-shaped — it is the next two matrix rows

Every remaining `any` on seam.bl decomposes into:
1. **`(get m :k …)` results** — map VALUES are unknown at tag tier.
   This is exactly P8's question (map shapes, go/no-go). P6 supplies
   P8's motivation with numbers.
2. **Calls to the file's OWN unannotated fns** — the P0 annotation pipe
   already fixes these; seam.bl simply has no `^{:args :ret}` yet.
3. A handful of cores whose honest ret IS `any` (get-in, reduce,
   apply) — seeded as such, correctly.

## Artifacts

- **Seed-table format** (in priv/std/typed.bl): the P1 map, extended —
  `core-seeds-v2` (41 fns) + `host-seeds` (22 fns), every entry
  verified against the runtime before seeding (sound-conservative:
  doubtful ⇒ unseeded ⇒ any ⇒ silent).
- **Lattice grew :seq and :list** (verified: keys→LazySeq, sort→list,
  mapv→vector); `list?`/`seq?` narrowings added.
