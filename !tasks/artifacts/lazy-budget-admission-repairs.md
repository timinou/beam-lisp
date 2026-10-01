# Lazy cache byte-budget admission + constant-size state peek

PLAN-154 clusters **B** (enforce lazy cache byte admission at every value
publication, including folded results; concurrent publishers cannot jointly
exceed the ceiling) and **D** (constant-size memo tag/version peek, retained-byte
counter, direct dirty-lane routing for known new dependencies).

Anchors repaired: `performance-review.md` §5 (P1 correctness/resource — fold
publication bypasses cache admission) and §7 (P2 native state/graph copy
amplification — full-term export for tag-only decisions; a stats map per claim;
a blind fast-lane attempt on a known-new dependency list). Companion detail:
`performance-lazy-review.md` §C4 and §P1/P2/P3/P7, whose proposed repairs are
**R1** (admit fold publication), **R2** (peek), **R3** (dirty-lane routing) and
**R5** (`retained_bytes` instead of `stats/0`).

Status: **production + tests written; nothing was executed by this worker.** No
VM was started, no native build, no seed, no publication, no git staging — only
reader/static checks (see §6). The runtime gates below are the orchestrator's.

---

## 1. The defect, restated as an invariant

`lazy_cache_budget_bytes` is documented (PLAN-092) as a *soft occupancy check
taken before a new attempt claims a cell*. Three consequences followed:

1. **The fold path never took it.** `publish_folded` → `exchange_version` →
   native commit; only `LazySeq::claim_attempt` called `admit!`. With
   `lazy_cache_budget_bytes = 0`, `(count (map inc (range 40)))` returned **40**
   while `first` on the same producer threw `{:lazy_cache_budget_exceeded, 0}`
   (review §5; `performance-runtime-probes.bl`).
2. **Occupancy is not admission.** A publisher that starts below the ceiling can
   commit an arbitrarily large result (or N concurrent publishers can each
   start below it), so the ceiling never bound the retained set.
3. **Tag-only decisions exported the whole state.** The second
   `(count (map inc coll))` learned "not `:pending`" by copying the published
   n-element list onto the caller's heap; `admit!` built a 25-field stats map
   per claim; a publish whose dependency list was visibly non-empty paid a
   fast-lane crossing that could only answer `:reroute`.

The invariant this change establishes:

> At every LazySeq **value** publication, the bytes the publication ADDS to the
> retained set are reserved ATOMICALLY against `retained + reserved`, and the
> applicable budget; a reservation is committed with the state or released on
> every path that does not commit. Therefore `retained_bytes <= budget +
> (ungated control overhead)` always, and two publishers that each start below
> the ceiling cannot jointly exceed it.

## 2. The contract, precisely

### 2.1 What counts (the counted overheads — `estimate_bytes/1` + native)

Every state is charged `size_of::<MemoCell>()` (native, per live state) plus
`estimate_bytes/1`:

| state | charge | why |
|---|---|---|
| `{:running owner attempt waiters}` | **constant 64** | a pid, a ref, a waiter list; the list is the only growable element and a per-element walk on an O(1) transition is exactly what this constant exists to avoid |
| `{:terminal reason}` | **constant 64** | control state |
| `{:pending thunk recipe}` | **measured** | the thunk and recipe are what keep the producer alive |
| `{:completed value}` | **measured** | the retained value |
| `{:failed thunk kind reason stack}` | **measured** | the thunk plus the RECORDED failure — class, unnormalized reason, full frame list (this is what makes replay bit-for-bit) |

A publication **replaces** the state its cell held, so admission charges the
DIFFERENCE:

```
delta = accounted(replacement) - accounted(previous)   (saturating, >= 0)
```

`delta == 0` is **never refused**: a non-growing transition cannot raise the
ceiling. That is deliberately load-bearing — it is what lets a claim, a waiter
registration and a terminal un-strand commit at *any* budget, so a refused value
publication can never strand an owner or a waiter.

### 2.2 The atomic reservation (native, `native/lazy_memo/src/lib.rs`)

```
RESERVED_BYTES: AtomicUsize      // new
admission:  retained + reserved + delta <= budget   ->  CAS reserved += delta
commit:     RETAINED += new ;  RETAINED -= old ;  RESERVED -= delta
abandon:    RESERVED -= delta            (cycle, fast-lane reroute)
```

* `reserve_loop` (dirty lane) retries the CAS until it wins or the ceiling says
  no; `reserve_once` (fast lane) makes a SINGLE attempt and answers `Contended`
  so a regular-scheduler NIF can never spin under a global counter.
* The **commit order is load-bearing**: `RETAINED` is credited before `RESERVED`
  is debited, and the add precedes the subtract, so a concurrent admission that
  races the window observes the total too LARGE, never too small. Releasing (or
  subtracting) first would let two publishers each pass the check and jointly
  overshoot.
* A *refusal* changes nothing: the cell keeps its state, the version does not
  move, and nothing is left reserved. A refused attempt can be retried after
  the deferred off-heap reclaim has run.

### 2.3 Where admission is applied (LazySeq only)

| publication | path | on `:over_budget` |
|---|---|---|
| `publish_folded` (`{:completed elems}`) | **admitted** | raises `ForceError({:lazy_cache_budget_exceeded, budget})`; the cell stays exactly as it was (still `:pending` — no owner, no waiter) |
| `publish_attempt` (`{:completed v}` / `{:failed …}`) | **admitted** | publishes the constant-size TERMINAL `{:terminal {:lazy_cache_budget_exceeded budget}}` through the same wrapper; a `delta == 0` transition, so it is admitted at any budget and wakes every registered waiter with the same reason the owner replays |
| `claim_attempt` (`:pending`/`:failed` → `:running`) | **admitted** (after the pre-existing `admit!`) | raises before the thunk runs |
| `wait_for_attempt` (waiter registration) | **not** admitted | provably `delta == 0` (running → running, charged the constant); gating it could only strand a waiter |
| `owner_lost` (`:running` → `:terminal`) | **not** admitted | provably `delta == 0`; same reason |
| `LazyMemo/exchange_version` (refs/atoms/promises/volatiles) | **not** admitted | reference cells are not subject to the lazy cache policy; `Atom`/`Refs` `swap!`/`reset!`/`deliver` behaviour is unchanged |
| `LazyMemo/create` / `create_ref` / `put` (cell creation, volatile writes) | **not** admitted | the recalled contract: `LazySeq/new` under pressure must not raise (the legacy suite constructs a node under budget 0 and expects the *force* to be refused). The pending descriptor it publishes is covered by the pre-claim `admit!` before any producer runs |

`admit!` keeps its exact semantics (budget 0 ⇒ refuse; at/over budget ⇒
`erlang:garbage_collect/0` then a bounded 25 ms poll) but now reads the
one-load counter instead of the stats map. `exchange_version_admitted/5,6`
repeats that bounded grace on `:over_budget`, so a refusal first gives the
deferred reclaim a chance to make room (the `admission-collects-unreachable-
handles` contract).

### 2.4 Fold/force parity (why this is exact, not approximate)

For a producer whose head is `{:pending thunk recipe}`:

* fold: one publication, `delta = completed - pending`;
* force: claim `delta_c = running - pending`, then publish
  `delta_p = completed - running`; `delta_c + delta_p == completed - pending`.

Both are admitted against the same running total, so the two paths reach the
same verdict. (The intermediate claim can itself be refused, in which case the
refusal happens *before* the producer runs — the legacy "thunk must not run"
property.)

### 2.5 The peek (PLAN-154 D)

`nif_peek/1` answers `{tag, version}` by reading the state tuple's leading atom
in place (`rustler::types::tuple::get_tuple`, no `enif_make_copy`) plus the
atomic publication counter, under the same state lock. Both elements are
immediate: **constant size whatever the payload**. `tag` is `:pending`,
`:completed`, `:failed`, `:running`, `:terminal`, a bare atom state's own atom,
or `:other`.

* The public full-state API is untouched: `nif_read`, `nif_read_versioned`,
  `LazyMemo/read/1`, `read_versioned/1` and `LazySeq/memo_state/1` still promise
  the whole logical state.
* Used for **tag-only** dispatch in `LazySeq/pending?` (peek only) and
  `LazySeq/pending_recipe` (peek, then a full versioned read ONLY when the tag is
  `:pending`, **validated against the peeked version** — a version that moved
  answers `nil`, i.e. "no usable recipe", and the caller falls back to the memo
  walk). This is the `(count (map inc coll))`-twice sharp case from review §P2:
  the second count now learns `:completed` from an atom + an integer.
* `peek` does **not** set the collector's `touched` flag: nothing was handed to a
  process, so the cell stays reclaimable if it is unreachable. The `:pending`
  path of `pending_recipe` still does a full read (the recipe is handed out) and
  therefore still marks it.

### 2.6 Lane routing (R3)

`LazyMemo/exchange_version/4,5` and the admitted wrapper now route a **known
non-empty dependency list** straight to the dirty lane: such a publish may add
an edge, and a new edge is not fast-lane work (the cycle walk is unbounded), so
the fast attempt could only answer `:reroute`. `:keep` and `()` keep the fast
attempt — they may be a SUBSET of the edges the cell already holds, which is
exactly the fast case the lane split exists for. Reference cells pass `:keep`
unconditionally, so their behaviour is byte-identical.

## 3. File-by-file change map

| file | change |
|---|---|
| `native/lazy_memo/src/lib.rs` | `RESERVED_BYTES`; `OP_PEEK`/`OP_BUDGET` + `op_peek`/`op_budget`/`reserved_bytes` in `MemoStats`; `growth_of`, `Reserve`, `reserve_loop`, `reserve_once`, `release_reserved`, `tag_of`, `State::tag`; `exchange_version_impl` gains `budget: Option<u64>` with reserve/commit/release and the add-before-subtract commit order; new NIFs `nif_exchange_version_admitted{,_fast}`, `nif_peek`, `nif_retained_bytes`, `nif_reserved_bytes`; 7 new unit tests |
| `priv/host/lazy_memo.bl` | `cache_budget/0`, `retained_bytes/0`, `reserved_bytes/0`, `peek/1`, `admitted_call/7`, `exchange_version_admitted/5,6`; `admit!`/`await-budget` now read the counter; R3 routing in `exchange_version/4,5`; stubs for the five new NIFs; `estimate_bytes/1` docstring states the counted overheads |
| `priv/host/lazy_seq.bl` | `pending_recipe`/`pending?` via the peek (version-validated); `publish_folded`, `publish_attempt`, `claim_attempt` admitted (+ refusal handling and the terminal un-strand); `owner_lost`/`wait_for_attempt` documented as not-admitted with the `delta == 0` proof; header section "THE CACHE BUDGET" |
| `priv/boot/rt.bl` | docstring only: `lazy-fold-pending` records that a budget-refused publication raises out of the fold and leaves the node pending. No logic change. |
| `test/bl/lazy_budget_test.bl` | **new**: 10 tests — zero-budget fold/force parity, publication-boundary parity, no-strand, concurrent ceiling, reservation cleanup, cached-failure replay shape, peek constant-size + unchanged full-state API, cheap counter agreement, peek-not-read dispatch, peek-version recipe guard |

## 4. Tests added

Native (`cargo test`, no BEAM):

* `the_cell_overhead_is_charged_with_the_payload` — the per-cell overhead is in
  every accounted size.
* `growth_is_only_the_excess_over_the_state_replaced` — saturating delta.
* `a_non_growing_publication_is_never_refused` — over-ceiling cache, `delta == 0`
  still commits (the un-strand property).
* `admission_reserves_only_while_the_total_fits_the_budget` — reserve, refuse
  (no leftover), commit-order window, then the ceiling is tight.
* `a_released_reservation_returns_the_room_it_held` — abandon path.
* `the_fast_lane_answers_over_rather_than_contending` — `Over` is a ceiling
  verdict, not a lane verdict.
* `concurrent_reservations_never_jointly_exceed_the_budget` — 16 real threads,
  one ceiling, the sum never exceeds it.

BL (`test/bl/lazy_budget_test.bl`): the ten above-named regression tests, i.e.
actual refusal on the fold path, fold/ordinary-force parity at both ends of the
boundary, non-stranded failure with a live owner AND waiter, concurrent
publishers under one ceiling, reservation cleanup, replayed cached failure with
a stable frame list, peek constant-size, `memo_state` unchanged, and
peek-not-read dispatch.

## 5. Acceptance mapping

| requirement | where |
|---|---|
| budget 0: `count (map inc (range 40))` refused like `first` | §2.3 + test 1 |
| 16 k rooted memo must respect the limit | §2.2 (delta reservation, absolute ceiling) |
| overlapping concurrent publishers; CAS-loser releases | `reserve_loop`/`reserve_once` + native concurrency test + BL test 4 |
| no recompute of effectful recipes; no `acc`-only shortcut | §2.4: the recipe runs once and the completed state is published; the fold still returns `{acc elems}` |
| budget change takes effect while forcing | `cache_budget/0` is read per admission |
| errors/throws/exits cached, replayed with a stable frame list | untouched `:failed` path + test "a-cached-failure-replays-with-a-stable-frame-list" |
| cycle collection / notification / dirty-fast-lane counters preserved | notification and reclaim order unchanged; `op_reroute`/`op_cursor*`/`op_lane` untouched; only `op_peek`/`op_budget` are new |
| reference cells keep their behaviour | §2.3 (refs, atoms, promises, volatiles not admitted) |
| optional collector fail-open remains | `collector::*` untouched |
| peek is constant size; full `memo_state` API retained; version validated | §2.5 + tests 6–8 |
| counter cheaper than the stats map | §2.2/§6 (`nif_retained_bytes` = one `AtomicUsize::load`; `admit!` no longer builds a 25-field `NifMap`) |
| direct dirty routing for known new deps | §2.6 |

## 6. Verification actually performed by this worker

**Run (static only, no VM, no compiler):**

* Delimiter balance (comments and string literals skipped) on all four `.bl`
  files, compared against `git show HEAD:` — the delimiters I added are balanced
  in every file, and `priv/boot/rt.bl`'s deltas are zero (docstring only).
* `rustfmt --edition 2021 --emit stdout native/lazy_memo/src/lib.rs` → exit 0,
  empty stderr: the crate root **and** its `mod collector`/`mod seen` parse
  cleanly (rustfmt is a parser pass; it is not a type check).
* Reader audits: the five new NIF names/arities in the Rust registration match
  the five new BL stubs exactly (`nif_peek/1`, `nif_retained_bytes/0`,
  `nif_reserved_bytes/0`, `nif_exchange_version_admitted{,_fast}/7`); every
  `release_reserved` call site is guarded by `if reserved` so an *unadmitted*
  publication (references) can never debit another publisher's reservation.
* Outline/diff reads of every touched region; no other file modified.

**NOT run (orchestrator gates).** This means: no runtime proof exists in this
artifact. In particular these claims remain unverified by execution —
`cargo test` green, the BL tests green, byte-approximation tolerances in tests
2–4, and the exact behaviour under a shared/`--async` image.

### Exact gate commands

```sh
# 1. native unit tests (pure Rust; no BEAM needed)
cd native/lazy_memo && cargo test --offline

# 2. rebuild the NIF and the source-generated floor, then regenerate the seed.
#    REQUIRED: priv/native/lazy_memo.so is gitignored and the committed seed
#    predates these NIFs; without this the new stubs stay bound and every
#    LazySeq publication fails with :nif_not_loaded.
bin/bl build --native
bin/bl seed

# 3. focused BL gates (fresh VM per file by default)
bin/bl test test/bl/lazy_budget_test.bl
bin/bl test test/bl/lazy_fold_test.bl test/bl/lazy_producers_test.bl \
            test/bl/lazy_scaling_test.bl test/bl/legacy_wave23_lazyseq_test.bl \
            test/bl/memo_bounds_sunset_port_test.bl test/bl/host_lazy_memo_test.bl \
            test/bl/host_lazy_seq_test.bl test/bl/deferred_test.bl
bin/bl test test/bl/host_refs_test.bl test/bl/host_refs_heap_test.bl test/bl/ref_cycles_test.bl
```

Bounded, as the review ran things:

```sh
systemd-run --user --scope --collect -p MemoryMax=4G -p MemorySwapMax=1G \
  env ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8' \
  bin/bl test test/bl/lazy_budget_test.bl
```

Coherence (the review's own negative proof; this change requires a regenerated
image anyway):

```sh
BEAM_LISP_AOT_STRICT=1 bin/bl version
bin/bl seed --check --ebin ./build
```

### Falsifiable expected observations

* budget 0: `(count (map inc (range 40)))` raises a `ForceError` whose message
  contains `lazy_cache_budget_exceeded` (today it returns 40).
* the same budget refuses `(first (map inc (range 40)))` and
  `(reduce + 0 (map inc (range 40)))`.
* a ceiling ~300 bytes above the retained total refuses BOTH the fold and the
  equivalent force, and a ceiling ~8 KiB above admits both.
* the completion of a *running* attempt refused by the ceiling leaves the cell
  `:terminal` and wakes the owner and every waiter with
  `{:lazy_cache_budget_exceeded budget}` — no timeout.
* after eight concurrent forces under a one-publication ceiling,
  `retained_bytes <= budget + 512` and at least one publisher was refused;
  `reserved_bytes` settles back to its pre-operation value.
* `estimate_bytes(peek cell) == 3 * wordsize` for a cell holding a 512-element
  list, while `estimate_bytes(memo_state cell)` is >100× that.
* stats `:retained_bytes`/`:reserved_bytes` equal `retained_bytes/0` /
  `reserved_bytes/0`; `:op_peek` grows on `pending?` while the read counters do
  not.

### Tolerance notes for whoever tunes the tests

Tests 2–4 use approximate byte sizes (a 40-element small-integer list ≈ 672 B, a
128-element one ≈ 2080 B, `size_of::<MemoCell>()` charged on both sides and
cancelling in the delta). The assertions are deliberately structural
(decision equality, at-least-one-refused, a 512 B slack over the ceiling), so a
different `size_of::<MemoCell>()` or word size changes the *reason* a refusal is
reached (pre-claim `admit!` vs publication admission) without changing the
verdict. If a runner reports test 4 admitting zero publishers, raise `extra` in
that test — never the ceiling logic.

## 7. Risks and precision limits (honest)

1. **The native rebuild is mandatory.** `priv/native/*` is gitignored and the
   committed seed carries the old `.so`; until `bin/bl build --native` +
   `bin/bl seed` run, `nif_peek`/`nif_exchange_version_admitted*` resolve to the
   BL stubs and raise `:nif_not_loaded`. This is the single largest handoff
   risk.
2. **Creation is not admitted (deliberate).** `LazyMemo/create` publishes the
   pending descriptor ungated, because the recalled contract requires
   `LazySeq/new` to succeed under pressure (the legacy suite builds a node under
   budget 0 and expects the FORCE to be refused). The pending descriptor is
   charged to the retained set once created and is covered by the pre-claim
   `admit!` before any producer runs. Residual: N concurrent `new`s add N
   pending descriptors without admission (bounded, small, and exactly the old
   behaviour).
3. **Reference/volatile stores stay ungated** (`put`, `compare_exchange`,
   `create_ref`). A ref-heavy workload can push `retained_bytes` above the
   lazy-cache budget; admission therefore treats the budget as a ceiling on
   lazy value growth from the retained baseline, not on the whole native heap.
   That matches "reference cells … may not be subject to lazy cache policy".
4. **A refused fold publication leaves the node `:pending`.** The fold raises
   loudly (that is the required parity with `force`), and since there is no
   owner or waiter there is nothing to strand — but a later consumer of that
   shared node recomputes the producer. This is the pre-existing semantics of a
   non-published fold (a `reduced`-halted fold already "publishes nothing and
   the node stays `:pending`"); publishing a TERMINAL budget state instead would
   permanently poison a shared producer on one consumer's resource verdict, so
   it is rejected for the fold path. The FORCE path has an owner and waiters,
   so there the refusal is terminal (no hang, no recompute of a producer that
   already ran).
5. **A budget refusal is terminal for an attempt.** A *transient* refusal (other
   cells temporarily retaining the budget) permanently marks that one cell
   terminal with the budget reason; a later force fails fast with the same
   reason rather than re-running a producer that already ran. Chosen over
   leaving `:running` (strand) or publishing `:failed` (the failed state is
   itself gated and would need the recipe/stack admitted).
6. **Fold/force parity is exact for the same published value, not for
   different ones.** The two paths charge the state each actually replaces; a
   fold replaces the pending recipe descriptor while a force replaces a running
   control state, so their *intermediate* deltas differ by a constant (the
   pending capture). Their total equals `completed - pending` on both paths, and
   the tests compare the verdict at ceilings far from that constant.
7. **`force_state` and `Deferred/realized?` were not converted to the peek.**
   `force_state` must export the value/owner/waiter state anyway, so the peek
   buys it nothing; `priv/host/deferred.bl` is outside this worker's file set.
   Both remain on the unchanged full-state API.
8. **Precision of the ceiling under an `--async`/`--shared` run.** The native
   counters are per-VM; a shared run lets unrelated files retain bytes that
   count against the same budget, so a focused assertion can see a different
   baseline. The tests measure their baseline immediately before the operation
   and assert *relative* bounds; a full-suite run with a corpus already near
   512 MiB could now refuse a publication that previously (silently, and against
   the documented contract) grew past the ceiling.

## 8. Remaining optimizations, classified

**Done in this change**

* R1/C4 — admission at every LazySeq value publication incl. `publish_folded`,
  with reservations, releases and the non-stranding refusal contract.
* R5 — `nif_retained_bytes/0` (one atomic load) replaces `stats/0` in `admit!`;
  `nif_reserved_bytes/0` is the second half of the admission reading.
* R2 (partially) — `nif_peek/1` + `LazyMemo/peek/1`, used by `pending?` and
  `pending_recipe` with version validation; public full-state API untouched.
* R3 — direct dirty-lane routing for known non-empty dependency lists.
* `op_budget` gives a cheap refusal sentinel for the "budget refused" ratio.

**Deferred, with the exact next step (each is a separate, measurable change)**

* **Bounded/streaming fold publication (review §P1, the retention half).**
  `lazy-fold-pending` still builds the whole element list before publishing, so
  one `(count (map inc coll))` retains `16n + 24` bytes while the node is rooted.
  The sound next step is chunked publication: publish `{:completed [e1 … e32 |
  tail-node]}` per chunk through the SAME admitted path (each chunk is a
  `delta`-reserved publication), so a fold's retained cost is bounded by the
  chunks the consumer actually reaches, while realise-once and the `{acc elems}`
  return are preserved. It needs its own concurrency/replay tests; do not fold
  it into this change. `prim/fold`'s accumulator-only variant is a separate
  design (it must be explicitly non-memoizing).
* **R2 for `force_state`/`Deferred/realized?`** — `deferred.bl::realized?` could
  dispatch on `peek`; it needs that file (out of scope here) plus the same
  version guard.
* **R6 — move `save` out of the global `GRAPH` lock window** with a two-phase
  copy and, after reacquiring the lock, revalidate version AND recompute
  `edge_plan` AND rerun `would_cycle` atomically with insertion. Not attempted:
  a fresh global reachability check after reacquiring the lock is required for
  soundness, and getting that wrong trades a serialization cost for a cycle
  bug. Local version/added-edge checks alone are insufficient (another cell's
  newly published reverse edge is invisible to them).
* **R7 — `edge_plan` membership by `HashSet`** (currently O(prev·new)); purely
  local, no lock-scope change, safe to land alone.
* **R8 — cheaper cursor positions** over shared backing storage (must preserve
  immutable replay, sharing and collector references; destructive in-place
  advancement is not a drop-in).
* **R9/R10/R11/R12** — direct-call materialisation walks, `own` module read out
  of `new`'s happy path, single source of truth for the chunk width,
  a fold recipe for `for`.
* **Collector (P8)** — `State::census` serialises each cell's whole state to ETF
  under the state lock, once per state; unchanged here. A tag/retained-bytes
  census would need the collector's own reference census, not this peek
  (soundness rests on the ETF occurrence list).

**Out of scope for this worker** (owned by disjoint workstreams): build plan /
scoped-build pruning, publication tests, and `system.analyze` / `veritas`
coverage — see `finding-8-analysis-and-shrink-repairs.md`.

## 9. Lineage

Linked org item: `PLAN-154-complete-clustered-performance-repairs-w`
(lineage only, non-gating). No org/memory mutation was performed by this worker;
no seed, image, git state or other worker's files were touched.
