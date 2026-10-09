> **Final verified record:** 72 assurance assertions passed after the final lifecycle correction. Real BEAM compile once, cache load once, isolated init once per generation; changed compiler/closure and active segment aliasing refuse. Replay restores namespace markers; delete precedes purge. This sequential descriptor/cache adapter is not the production loader, full namespace/macro caching, concurrent initialization or cross-realm relocation.
>
> See [results.json](results.json), [strategy.md](strategy.md), and [README](README.md). Source-only authoring expectations below are historical and superseded by this final record where they disagree.


# FUP-155 step 1 — realm-local AOT cache adapter (spike)

**Status: UNRUN.** Every number, verdict and witness below is a prediction of
what the executable test *will* produce; the orchestrator runs it in the single
serial VM. Nothing here is wired into production, and no production file is
touched.

Files (research only, three):

| file | role |
|---|---|
| `research/structural/realm.bl` | the adapter: segment fold over the existing AOT cache, per-env init, lifecycle, logic checks |
| `research/structural/realm_test.bl` | the executable assurance (real BEAM, key sensitivity, isolation, corruption, lifecycle, logic) |
| `research/structural/realm.md` | this note |

Run:

```
./bin/bl test research/structural/realm_test.bl
```

(The runner adds the repository root to the code path if the research file is
not resolved automatically.)

---

## 1. What the spike demonstrates

FUP-155's measured problem: realm-local namespaces are compiled from source on
**every** load (≈1000× the cached path), because the shared AOT repair publishes
under `:global`. The chosen first step is smaller than the cross-realm beam
rename:

```
key := (compiler-key, resolved dependency closure, realm segment)
```

Compile the namespace **inside the realm's env**, so the emitted modules already
carry `R<key>`/`S<hash>`; the next load of the same closure in the same segment
fetches the beams and replays `__bl_init__` in the realm's env instead of
recompiling.

The adapter (`research.structural.realm`) drives only existing machinery:

- `BeamLisp.AOTCache/closure_key` — the resolved dependency closure
  (path + content hash of every transitive `:require` target).
- `BeamLisp.AOTCache/hash_parts` — the cache's own NUL-joined sha256, used to
  fold the segment into the closure slot. `hash_parts/1` is part of the pinned
  export set (`test/bl/aot_cache_host_test.bl` pins `:hash_parts 1`).
- `BeamLisp.AOTCache/store`, `fetch`, `entry_dir`, `run_init_modules` — the
  publication/link/validation/replay surface.
- `BeamLisp.Emit/module_for`, `descriptor_for`, `compile_descriptor`,
  `function_clause`, `lit`, `remote`, `sequence` — real ANF → Core → BEAM
  construction.
- `BeamLisp.Env/fork`, `with_env`, `put_key`, `lookup`, `destroy` — realm envs.

No hand-built beam, no cached integer standing in for AOT: `build!` compiles a
real module through the Core lowerer and the test calls the loaded module.

## 2. The contract, clause for clause

| clause | where | expected result (UNRUN) |
|---|---|---|
| (a) executable candidate | `build!`, test 1 | first `build!` → `:compiled`; real BEAM exports `who/0` and returns the baked value |
| (b) baseline oracle | test 1 | second `build!` → `:reused`; fetched beam materialized in a fresh dir; `compile-count` stays 1, `load-count` 1 |
| (c) positive invariants | `check-logic`, `smt-key-obligations`, test 6 | veritas: `:proven` / engine `:enumerate`; z3: `:unsat` |
| (d) adversarial negative | `naive-key`, test 2 + test 6 | segment-blind key: veritas `:proven` with witness; z3 `:sat` with a model; executably, B is served A's module |
| (e) work experiment | counters, test 1 | `compile 1`, `load 1`, `init 1`; `counters-map` printed with compile-us/load-us |
| (f) scope | this file | boundaries below |
| (g) sequential boundary | `build!`, test 2 | one namespace binds to one entry per open generation; a changed entry REFUSES before any side effect (reload unsupported, races unsupported); a changed closure is observed after close + reopen |

## 3. Expected observations (UNRUN — ratios, not absolutes)

- test 1: `:compiled` then `:reused`; `compile-count = 1`, `load-count = 1`,
  `init-count = 1`; `(erlang/apply mod :who ())` = `"A"`; the fresh `out-b` gains
  `<module>.beam`.
- test 2: `a` (realm 1) and `d` (realm 2) both `:compiled`, different
  module atoms; the segment-blind key's store/fetch returns A's module to realm
  2; a changed entry in the SAME open generation raises (message contains
  `reloading a changed entry`) with no beam written; after close + reopen, the
  changed bytes `b` and the changed compiler `c` each `:compiled`. `base`,
  `changed-bytes` and `changed-provider` are computed at ONE fixture path, so
  only content moves the closure key.
- test 3: realm A env reads `"A"`, realm B env reads `"B"`, global
  `Env/lookup` is `:error`.
- test 4: corrupted beam → `:miss` → `:compiled`; manifest removed → `:miss` →
  `:compiled`.
- test 5: `init-count` 1 (open+hit), close purges the module
  (`code/which` no longer a path), reopen `:reused`, `init-count` 2, module atom
  identical; a second open/close cycle `:reused`, `init-count` 3, `open-count` 3,
  the same atom — stable segment identity and no atom growth across repeated
  lifecycles.
- test 6: five veritas verdicts and two z3 statuses as tabled above.

## 4. Logic scope — what is and is not proved

**veritas (finite exhaustive).** Two declared finite domains:

- key domain: `{compiler, closure, segment} × {…} = 2⁶ = 64` pair vectors.
  - `key-separation` — `∀`. Expect `:proven`, engine `:enumerate`.
  - `naive-collision` — `∃` a pair with different segments and equal
    segment-blind key. Expect `:proven` with a witness.
  - `naive-refuted` — the `∀` separation claim for the naive key. Expect
    `:refuted` with a witness.
- lifecycle domain: 3-event traces over `{1 open, 2 close, 3 init}` = 27.
  The model state is `(open, inits)` and the counter is NOT clamped; the
  transition RELATION is what is checked.
  - `lifecycle-safe` — `∀` a realm generation is initialized at most once:
    `init` increments only while open and only if this generation has not yet
    initialized; `open` starts a generation (inits reset), `close` ends one,
    `init` in a closed realm is a no-op. Expect `:proven`, engine `:enumerate`.
  - `naive-lifecycle` — `∃` a NAIVE executor that increments on every `init`
    while open reaching two inits in one generation. Expect `:proven` with the
    witness trace `[1 3 3]` = open·init·init.

Because the generators are `OneOf` over compound vectors, veritas'
`gen-constrain` declines, so the escalator lands on the **exhaustive** rung — the
proof is by exhaustion, not sampling.

**z3 (symbolic).**

- `separation` — the negation of `key₁ = key₂ ⇒ components equal` over the
  component bounds. Expect `:unsat`.
- `naive-collision` — the segment-blind collision asserted satisfiable. Expect
  `:sat` (a model naming two distinct segments).

**Boundary (important).** The logic tools prove the **key algebra** and the
**lifecycle model** — the arithmetic stand-in `c·100 + cl·10 + s` and the
`(open, inits)` transition relation. They do **not** prove the runtime cache. The runtime BEAM
test (`realm_test.bl` tests 1–5) proves the implementation. **A solver
`:unknown` is never read as proven:** the tests assert the exact
`:unsat`/`:sat`/`:proven`/`:enumerate`, so an undecided solver fails loudly.

The arithmetic key is an abstraction of the hashed `entry-key`; the hash itself
is only trusted by the runtime tests (collision resistance is not proved here).

## 5. Proof boundary: adapter vs production loader

| concern | this spike | production |
|---|---|---|
| key | `(compiler-key, hash_parts(closure, segment))` in `build!` | `AOTCache.key_for_ns/1`, `entry_dir/2` gain the segment |
| compile env | pinned Emit + Core lowerer, module name via `Emit/module_for` under the realm env | `AOT/compile_and_publish` runs under the realm env |
| publish | `AOTCache/store` under the segment-folded key | same |
| fetch/load | `AOTCache/fetch` + `run_init_modules` under the realm env | `AOT/load_cached_entry` targets the realm env instead of `:global` |
| route | not wired | `Loader/load_route` returns `:aot-realm` for `:realm`/`:shadow`/`:shared`, not `:source` |
| lifecycle | ETS registry in the adapter (open/close/init-once) | `vm.realm`/`vm.manager` own it; the adapter's registry is a model |

### Exact production diff strategy (NOT applied)

All in boot-tier host files; one rebuild:

1. `priv/host/aot_cache.bl`
   - `key_for_ns/1`: fold the realm segment into the closure slot (or add a
     segment-aware sibling `key_for_ns/2`).
   - `entry_dir/2`: include the segment so two realms cannot share a path.
2. `priv/host/aot.bl`
   - `repair_library/1` (`repair_link_dir/1`, `compile_and_publish/4`,
     `load_cached_entry/3`) take the **target env**; run the compile and the
     `run_init_modules` replay under it instead of `with_env :global`.
3. `priv/host/loader.bl`
   - `load_route/1` answers `:aot-realm` for the `local_homes`
     (`:realm :shadow :shared`); `ensure_loaded_locked` dispatches
     `AOT/ensure_loaded` on that route.

The adapter's ETS lifecycle registry is a **model**, not the real owner
(`vm.manager` owns realm identity); the production change must bind the
generation to the manager's row, not add a parallel registry.

**Deferred (FUP-155 step 2):** canonical cross-realm *beam rename* so two realms
with identical closures share ONE entry. Step 1 deliberately gives one entry per
(realm segment) — restarts/reopens (the measured common case) are fixed; the
cross-realm duplicate compile remains. `Loader/segment_for` and the `S<hash>`
shared rule already exist, so the rename step keys on the same closure.

## 6. Fallback / refusal conditions

- **Entry corruption** — `AOTCache/valid_entry` re-hashes every beam against the
  manifest digest; a damaged beam is `:miss` (test 4), and `build!` recompiles.
- **Entry identity (boundary)** — the digest check covers BYTES, not identity:
  `valid_entry` does not parse the beam header or confirm the module atom
  matches the filename. A manifest and its beams rewritten TOGETHER would pass.
  This spike therefore claims corruption refusal, NOT tamper/identity proof.
- **Partial publish** — `store/4` is atomic (temp dir + rename); a missing
  manifest is `:miss` (test 4), and `build!` recompiles. `store` failures are
  swallowed inside the cache, so a read-only cache costs reuse, never
  correctness.
- **Key escape** — `entry_dir` refuses keys outside `[A-Za-z0-9_-]+` and
  generation symlinks; the adapter passes only hex/derived keys.
- **Closed realm** — `build!` raises (`require-open!`); no silent init of a
  closed generation.
- **Reload / races** — within one open generation a namespace binds to ONE
  entry; a changed entry raises before any compile/store/load (test 2).
  Reloading a live module and concurrent builds are unsupported and unmodelled;
  the adapter is a sequential boundary.
- **Corrupt/partial module** — `compile_descriptor` refuses a non-atom/non-binary
  result; `load_binary!` raises naming the module.

## 7. What remains unverified (explicit)

- No real VM run: all counts, timings, modalities and models are UNRUN.
- Absolute timings are meaningless on this host (FUP-155 was measured at load
  ~28); only compile-vs-load counts and ratios should be read.
- The `sha256-hex` stand-in inherits sha256's collision resistance unproved.
- The logic model uses a 2-element domain per component (2⁶ pairs, 3³ events);
  it is exhaustive over that domain, not over real hash values.
- Cross-realm dedup (one entry, two realms) is **not** demonstrated — deferred
  to step 2.
- The per-ns atom key (`bl-spike-init-<ns>`) is bounded by the number of loaded
  namespaces; a production version should reuse the namespace's own atom, not
  mint a new one. The test shows module atoms are stable across reopen; it does
  not measure total atom growth.
- Solver availability (`priv/z3/bin/z3`) and the supervised pool are assumed; a
  `:unknown`/`:error` status fails the z3 assertions by design.
- The one-entry-per-generation binding, the refusal path, and all reload/race
  behavior are NOT modelled by the logic checks; only key separation and the
  at-most-once lifecycle are.
- Corruption refusal is digest-based; beam module-identity/header and a
  coordinated rewrite of manifest + beams are NOT detected.
