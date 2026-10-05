> **Final verified record:** 61 assurance assertions plus the shared metrics gate passed. The wrapper makes one refresh over 4,000 stable steps but is 3.09–3.39x MORE reductions than baseline: reject this wrapper as a performance implementation. The bulk-delete probe found BUG-115: an exposed low-level mutation does not advance the epoch and both lookup caches retain their prior binding. Model theorems assume complete write-stamp coverage; that production prerequisite is not established.
>
> See [results.json](results.json), [strategy.md](strategy.md), and [README](README.md). Source-only authoring expectations below are historical and superseded by this final record where they disagree.


# Lookup — traversal-local, epoch-guarded callable cache (PLAN-166 Q3)

**Status: research prototype. All execution results below are UNRUN.** The
orchestrator runs the test on a single capped VM after join; nothing here is
measured yet. Files: `research/structural/lookup.bl`,
`research/structural/lookup_test.bl` (this note is the third scoped file).

## The question

Can a traversal reuse a callable it resolved from a var — while the environment
is unchanged — and still observe exactly the same rebinding, provider
initialization, error and terminal behavior as authoritative late lookup
(`Elixir.BeamLisp.Env.fetch/2`)?

## The mechanism

`deref!` returns the same `{:ok value}` / `:error` shape as `Env.fetch/2`, from a
process-dictionary slot created per traversal (`new-cache`, keyed by a fresh
ref). The guard is the environment identity `(epoch, chain)` sampled from the
REAL Env:

- **hit**: the cached `(epoch, chain)` equals the current one. Return the cached
  result. No authoritative fetch, no mutation.
- **miss**: invalidate the slot, call `Env.fetch/2`, then re-store only if the
  epoch and chain were stable **across** the call. A loader initializing a
  provider (or a concurrent writer) bumps the epoch mid-fetch, so the unstable
  case stores `:fresh false` and the next deref refetches. This is the same
  "sample the epoch before the walk, cache under that epoch" discipline
  `fetch_fresh/3` uses, lifted one level up.

No second registry: no Agent, no ETS table, no cross-process state. The slot is
process-local scratch and is erased by `destroy-cache`. Every refresh is the
authoritative `Env.fetch/2`; the cache only chooses *when* to call it.

### Why the chain is part of the identity

The epoch is bumped by every **write** (`put_key`, `delete_key`, `destroy`,
`match_delete_own`, `^:per-env` materialization) but **not** by a pure
environment **switch** (`with_env` / `bind` / `attach`). Two envs in one chain can
bind the same `{ns, name}` differently — a fork's shadow interned before a base
re-def — so a hit needs `epoch == since` **and** `chain == since`. An epoch-only
guard is a wrong design and is pinned as a negative control.

## Integration seam

- `env.bl` is unchanged. The cache reads the pinned Env beam's exported
  `current_epoch/0` (the pinned emitter does not privatize `defn-`; documented in
  `priv/host/env.bl` and `priv/host/refs.bl`).
- **The probe must load the module first.** `erlang/function_exported/3` returns
  `false` for an *unloaded* module, so a cold worker can read `false` even though
  the running image exports the counter. `epoch-api?` therefore tries the cheap
  loaded check first, then `Code/ensure_loaded?` (the guard `BeamLisp.AOT` uses)
  under a `try`; a capability-refused or unavailable `Code` degrades to the
  conservative `false`. Confirmed against the staged image: the running Env beam
  (`…/ebin/Elixir.BeamLisp.Env.beam`) exports `current_epoch/0`, `epoch_ref/0`
  and `bump_epoch/0`. If a build ever privatizes the counter, `epoch-api?`
  returns false and `deref!` degrades to **always refresh** — correct, slower,
  never stale.
- Production should expose a supported `Env/epoch/0` (the JS runtime already
  ships `epoch()` for exactly this: `priv/lib/js/env.mjs`). Then this module
  needs no private-export dependency.
- A production integration point is the central optimizer / traversal seeding
  (PLAN-166 Q3): a fold that resolves a callable per element consults one cache
  for the traversal's dynamic extent, not a per-call fetch.

## Fallback / refusal

- **No epoch observable** → `epoch-api?` false → every deref refetches. The
  result is always authoritative; only the cost changes.
- **Unbound var** → `:error`, identical to `Env.fetch/2`. (The cache stores
  `:error` under a stable epoch, so a later `intern` bumps the epoch and the
  next deref refetches.)
- **Raising refresh** → the slot is invalidated *before* the fetch runs, so a
  raise can never leave a servable stale binding. The exception propagates,
  exactly as `Env.fetch/2` would.
- **Never cache an unstable observation** → if the epoch/chain moved during the
  fetch, the slot is left `:fresh false`; no value is served from it until a
  later stable refresh.

## Proof scope (model vs runtime)

The pure model (`world-step`, `model-step`, `model-step-frozen`) is checked three
ways in the test:

1. **Finite exhaustive veritas** over a declared domain: 3 modes
   (`:stable` / `:rebind` / `:switch`) × 3 steps × initial binding ∈ {0,1} = 54
   trajectories. `:engine :enumerate` — exhaustion is a real ∀, not a sample.
   - guarded predicate → `:proven`;
   - frozen predicate → `:refuted` + witness;
   - epoch-only predicate → `:refuted` + witness.
2. **Symbolic z3** (soft): an unbounded-integer obligation proving guarded
   soundness *under the explicit write axiom* `(same epoch ⇒ same binding)`, and
   refuting the unguarded variant. If the solver is missing or answers
   `unknown`/`witnessed`, the test records UNVERIFIED — it never reads an
   unknown as a proof.

**Model / runtime boundary.** The model proves parity *given* the axiom that
every mutation bumps the epoch and that `current_epoch` is the counter
`fetch/2` reads. That axiom is a property of `env.bl`; this spike does **not**
prove it — the executable parity tests are evidence for it, not a theorem. The
finite domain is not a universal theorem over unbounded epochs (the symbolic
obligation is the only attempt at that, and is explicitly soft).

**Not used, and why.** `system.model/step` extracts transitions from a
process/loop (receive/loop-recur/defserver); the cache is a pure value function
with no message transitions to extract, so veritas is the correct affordance.
`system.prove`/`system.footprint` annotate effect/termination facts on bl-ANF
nodes; this obligation is a relational state property, not an effect fact. Both
were inspected and are out of scope here.

## Executable evidence (UNRUN)

Test command (matches `research/structural/README.md`):

```sh
systemd-run --user --collect --wait --pipe --working-directory="$PWD" \
  --setenv=BL_DAEMON=off \
  --property=MemoryMax=8G --property=MemorySwapMax=2G \
  --property=RuntimeMaxSec=1200 \
  ./bin/bl --cold test -p . research/structural/lookup_test.bl
```

What the test asserts, and the expected shape:

- **Positive parity** across rebind, undefine, a fork's chain switch, a
  **mid-fold self-rebind** (the callback rebinds the very var being resolved),
  a **predicate that rebinds itself** mid-call, an **empty traversal** (zero
  resolutions, zero fetches), and a **terminal deref** after a rebind. Expected:
  cached resolution equals `Env.fetch/2` at every step; the mid-fold case
  switches to the new fn after element 1 (final accumulator 30 for `1 2 3 4`).
- **Negative witness (frozen)**: cache once, rebind, and the frozen value
  `{:ok :old}` differs from the live `{:ok :new}`. Passing means the witness
  appeared.
- **Negative witness (epoch-only)**: build the cache at base after a child
  shadow exists, switch to the child at an unchanged epoch, and the epoch-only
  guard returns `{:ok :base}` where the oracle is `{:ok :child}`.
- **Cost**: an unchanged 4000-element traversal makes **1–3** authoritative
  fetches (vs 4000 for the baseline) — *this* is the asserted win. Process
  reductions for the cached fold vs the baseline are **reported** by
  `lookup/report`, not asserted `<=`: the baseline `Env.fetch/2` is already
  memoized, so the cached path can legitimately lose on a reduction count while
  winning on authoritative fetch count. A traversal whose binding is written
  every step makes **n** fetches and stays correct.
- **Error timing**: a fetch that raises (non-binary name) leaves the slot
  `:fresh false`; an unbound var is `:error`.
- **Scope/cleanup**: every runtime test runs in a fresh CHILD of the current env
  (never `:global`, which drops the research namespace bindings), destroyed in
  `finally`; `lookup/report` creates, uses, and destroys every cache it makes,
  and `report-destroys-every-cache-it-creates` asserts the process dictionary is
  slot-free after a probe.

`lookup/report/4-5` is the reusable metrics entry point for the orchestrator
driver: it returns `:result :steps :fetches :misses :refreshes
:cached-reductions :baseline-reductions :best-of :epoch-api? :reduction-ratio
:agrees`, creates no leak, and takes reductions best-of-N (the minimum).

Expected metrics to record after the run (currently UNRUN, so unnumbered):
authoritative fetch count (cached vs baseline), the reported process-reduction
counts and ratio, wall time if useful. Do not infer any of these from this note.

## Remaining unverified

- The environment axiom (every mutation bumps the epoch; `current_epoch` is the
  counter `fetch/2` reads) is assumed, not proven.
- **Epoch ABA / rollover**: the guard compares epoch equality. The Env epoch is
  a signed 64-bit atomics counter; wraparound at 2^63 is not reachable in
  practice, but a *fresh* `epoch_ref` (persistent_term erased and recreated,
  e.g. an app restart) restarts at 0 and is a theoretical ABA window. `Env`'s
  own memo shares this exact assumption, so this cache is no weaker than the
  baseline — but neither is proven under restart.
- **Realms**: realms are not on `main` (they live on the `realm` branch), so the
  realm-change variant of the chain test is not executable here. The mechanism
  treats a realm change as a chain/env-id change; that mapping is unverified.
- **Concurrency**: the epoch/chain guard is read without a lock; a write racing
  a hit is handled by the same monotone-epoch argument `Env` relies on, but no
  multi-process stress test is included (the runtime is single-process per the
  traversal setting).
- **Compiler evidence**: no emitted-IR evidence is gathered. This spike makes no
  claim that the optimizer eliminates lookups in `lookup.bl` itself; the
  measured quantity is runtime fetch count and process reductions.
