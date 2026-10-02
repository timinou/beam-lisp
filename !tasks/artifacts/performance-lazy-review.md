# Performance review — source-free lazy engine (`13659b7d`, merged `801ebbbc`)

Read-only review of the integrated lazy implementation. No production edits, no global
builds or suites were run. Every claim below is either **read from source** (anchor given)
or **labelled measured/quoted** with its origin. Nothing here is inferred from wall-clock
numbers alone.

## Current lazy execution: save work without changing replay

1. **Claim before effects.** Force and trusted full-fold consumers share the
   same versioned attempt. A second reader waits or reads the saved result.
2. **Reserve growth atomically.** One occupied counter covers saved bytes and
   reservations. Failed publication releases credit; a post-production budget
   refusal is terminal rather than permission to repeat the producer.
3. **Keep a halted prefix.** Arbitrary reducers walk memoized chunks. Later
   consumers continue from that prefix; they do not start its recipe again.
4. **Read only the needed shape.** Peek returns tag/version. A full read after
   peek validates the version. Public full-state inspection stays available.
5. **Share positions.** One finite-input cursor root builds its index once.
   Immutable root/index tokens replay identically; each pull visits a chunk,
   not the entire prefix. Element count does not bound a giant element's bytes.
6. **Keep graph safety.** Dependency insertion retains fresh cycle checking.
   Structural reference census uses closure serialization only where needed;
   an uncertain collector census retains the candidate.

Final 16k lazy workload samples: **69.951 / 82.348 / 79.977 ms**.
Finite-input equivalents: **56.689 / 65.156 / 67.963 ms**. Raw Erlang remains a
lower-bound diagnostic, not equivalent sharing semantics. A held 16k memo
retained **256024 bytes** of memo state; the repeated count did not change its
native retained counter (**634928 bytes**, reservations **0**). Live roots
intentionally retain answers, and these counters are estimates, not process RSS.

[Final measurements](performance-final-measurements.json) contain every sample
and counter caveat. The sections below are the historical diagnosis, including
rejected optimization proposals; they are not claims about current code.

## 0. Scope and method

| Layer | Files |
|---|---|
| Host (pinned BL) | `priv/host/lazy_seq.bl` (675 L), `lazy_memo.bl` (511 L), `refs.bl` (573 L), `seq_cursor.bl` (100 L), `lazy_seq_enumerable.bl`, `seq_cursor_enumerable.bl`, `deferred.bl`, `reactive.bl` |
| Native | `native/lazy_memo/src/lib.rs` (1178 L), `collector.rs` (638 L), `seen.rs` (107 L) |
| Producers / folds | `priv/boot/core.bl` (`lazy-input` 556, `chunked-run` 575, `chunked-realise` 600, `chunked` 646, `distinct-realise` 828, `dedupe` 867, `for` 1305), `priv/boot/rt.bl` (`lazy-count` 1039, `lazy-map` 2474, `map-chunk` 2503, `lazy-filter*` 2572, `reduce-lazy` 3776, `reduce-cursor` 3889, `lazy-fold-source` 3902, `lazy-recipe` 3920, `lazy-fold-pending` 3929, `k-fold` 3976) |
| Lowering | `priv/host/aot.bl::compile_host_file` (141), `priv/boot/compiler.bl` (`self-apply` 946, `compile-recur` 959, named-fn lowering 2250), `priv/build/seed.bl` |
| Integration parent | `856d49c7` (source-free BL floor) → `13659b7d` (lazy engine) → `801ebbbc` (merge). Diff at `13659b7d`: `lazy_seq.bl` +801/−x, `lazy_memo.bl` +379, `refs.bl` +287, `core.bl` +556, `rt.bl` +361, `compiler.bl` +66, `lib.rs` +501, `collector.rs` +638, `seen.rs` +107. |

Evidence class used throughout:
- **[S]** source-read, anchored — high confidence.
- **[Q]** quoted from an in-repo artifact — evidence about *someone else's* run.
- **[?]** plausible but unverified this session — labelled as such.

### Environmental caveat (stated up front)

The pre-integration baseline numbers in `!tasks/artifacts/lazy-perf-integration-roster.md`
(`map-indexed` 13 467/56 807 ms at n=2000, `distinct` 27 075/105 426 ms) **[Q]** were taken
"under changing load/swap" and the roster explicitly refuses to call them a speedup factor.
I do **not** attribute those multi-second/multi-minute times to any single mechanism below.
What source *does* support is a set of mechanisms whose cost is proportional to something
the user controls (n, captured env, stack depth, live cell count); those are the findings.

---

## 1. Verdict, ranked

The steady-state chunked walk is structurally sound: 32 elements per memo cell, one
`force` per cell, `:keep` edges for claims/waiters, version CAS instead of term compare.
The defects cluster in five places:

| # | Finding | Class | Impact |
|---|---|---|---|
| **P1** | A completed fold publishes the **entire** element list into the cell, and that publication bypasses the cache-budget gate. | perf + invariant | O(n) allocation, O(n) retained, 5 passes, unbounded publication size and ungated admission (bytes are accounted by stats) |
| **P2** | `read_versioned`/`read` always export the whole state term; used in **dispatch-only** positions. | perf | O(\|state\|) copy for a tag test; a second `count` over a folded seq copies the whole list |
| **P3** | Every publish whose value reaches a resource the cell did not already hold answers `:reroute`; the dominant chunk value (`LazySeq/chain`) always does. | perf | 2 NIF crossings + a `DirtyCpu` hop per chunk publish; publishes pay reroute crossings and dirty-scheduler hops; graph locking is the shared serialization point |
| **P4** | Every create/non-`:keep` publish does 3 full passes (BL dep walk + `flat_size` + native `make_copy`), with 1 NIF crossing per embedded resource (F5). | perf | multiplicative constant on every node |
| **P6** | The single global `GRAPH` mutex is held **across the term copy**, and `edge_plan` is O(\|prev\|·\|new\|) with monotonically growing edge sets. | perf | serialises all publishes; O(publish) under one lock |

Plus: cursor churn (P5), per-claim `stats()` (P7), collector census serialising whole states
(P8), indirect-call-per-element in every materialisation/reduce walk (P9), and four
micro/consistency items (P10–P13).

**Corrected after a disproven premise.** An earlier draft of this review claimed the chunk
publish stayed on the *fast* lane because the dependency walk could not see the improper cons
`LazySeq/chain` produces. That premise is false — `erlang:is_list/1` is shallow and accepts an
improper cons (observed this session; see §2 C1, RETRACTED). Measured against this checkout, a
chunk value DOES contribute an edge (`dependencies` on `[e1 e2 | node]` → 1) while a published
fold value does not (`dependencies {:completed [scalars]}` → 0). So the dominant chunk publish
takes the `:reroute` path below, and P3 is the steady state, not an exception.

---

## 2. Correctness findings (separate from performance)

### C1 — RETRACTED: the dependency walk DOES descend an improper cons

**Claim as first written.** `deps_walk` (lazy_memo.bl:124) tests its cons branch with
`(and (erlang/is_list cur) (erlang/== false (erlang/== cur ())))`; the review asserted that
`erlang:is_list/1` "is **false for an improper list**", so a chunk's realised value
`[e1 e2 … e32 | node]` (the shape `LazySeq/chain`, lazy_seq.bl:181, produces) fell past the
cons branch and was discarded. Claimed consequences: `dependencies` answers `()` for every
chunk; `attempt_deps` returns an empty list; `would_cycle` is blind to the seq chain; and the
chunk publish stays on the fast lane for free. **All of that is withdrawn.**

**Observed this session — the premise is false.** `erlang:is_list/1` is SHALLOW: it tests for
a cons cell or `[]`, not for a proper list. Run:

```
erl -noshell -eval 'X = [1|foo], io:format("improper_is_list=~p proper_is_list=~p~n",
                    [erlang:is_list(X), erlang:is_list([1,2])]), halt().'
improper_is_list=true proper_is_list=true
```

and end-to-end against this checkout, one `bin/bl eval` (the CLI prints a staging preamble;
the value is the final line):

```
bin/bl eval '(let [n (BeamLisp.LazySeq/new (fn [] nil))]
               (tuple (erlang/length (BeamLisp.LazyMemo/dependencies
                         (BeamLisp.Ns.Rt/raw-cons 1 n)))
                      (erlang/length (BeamLisp.LazyMemo/dependencies
                         (BeamLisp.Ns.Rt/raw-cons 1 ())))
                      (erlang/length (BeamLisp.LazyMemo/dependencies
                         (BeamLisp.Vector/new (list n))))))'
{1, 0, 1}
```

`(dependencies (raw-cons 1 node))` answers **1** — the tail node's resource IS found;
`(dependencies (raw-cons 1 ()))` answers `0`; the vector control answers `1`. A second run:

```
bin/bl eval '(let [n (BeamLisp.LazySeq/new (fn [] nil))]
               (tuple (erlang/length (BeamLisp.LazyMemo/dependencies
                         (erlang/list_to_tuple (list :completed (list 1 2 3)))))
                      (erlang/length (BeamLisp.LazyMemo/dependencies
                         (erlang/list_to_tuple (list :completed
                           (BeamLisp.Ns.Rt/raw-cons 1 (BeamLisp.Ns.Rt/raw-cons 2 n))))))))'
{0, 1}
```

`{:completed, [scalars]}` has **0** edges; `{:completed, [e1 e2 | node]}` has **1**.

**Corrected reading.** `deps_walk`'s cons branch matches ANY non-empty cons, proper or not,
and `hd`/`tl` are defined on an improper cons (`hd([1|foo])` → `1`, `tl([1|foo])` → `foo`), so
the walk continues down the spine and reaches the `LazySeq` tail node, whose branch
(`deps_lazy_node?`, lazy_memo.bl:102 — a map carrying the `BeamLisp.LazySeq` struct tag)
records its resource. `deps_scalar_list?` (lazy_memo.bl:111) does answer false for the
improper cons — its own `is_list` guard is shallow too, so it walks to the non-list tail and
returns false — which is exactly correct: the term is NOT an all-scalar flat list and must go
to the walk. The two predicates are consistent; neither is buggy. The walk's error was mine,
not the module's.

**Consequence for the rest of the review.** The retraction does not preserve a fast-lane
exemption — it removes one. A chunk value carries an edge, so `added` is non-empty and
`exchange_version_impl` answers `:reroute` (lib.rs:735–742) on every chunk publish. The former
claim that C1 "masks" that reroute for the dominant shape had the polarity backwards: P3 is
the steady state. The fast lane is reached only by transitions that add no edge — a `:keep`
policy, or an empty dependency list (the published fold value, measured above).

Surviving, still true and re-verified:
- `deps_walk`'s map branch pushes keys AND values
  (`maps/fold (fn [k v acc] (erlang/++ (list v k) acc))`, lazy_memo.bl:202) — a safe
  over-approximation of the true edge set.
- Only genuinely new ids are cycle-checked; a `:keep` transition consults no graph at all.

Withdrawn with this section: the empty dependency set, the `Deps::Union([])` sequence, the
`:cycle`-unreachable claim, the fast-lane masking, and the dependent repair **R4** and probe
**PB5**.

### C4 — the cache-budget invariant does not hold on the fold path `[S]`

`admit!` (lazy_memo.bl:420) is the documented gate: "`:lazy_cache_budget_bytes` (default
512 MiB) bounds the bytes retained off-heap". It is called from exactly one place —
`LazySeq::claim_attempt` (lazy_seq.bl:361). `publish_folded` (lazy_seq.bl:236) →
`LazyMemo::exchange_version` does **not** call it. Since P1 makes the fold path the one that
retains O(n), the gate is absent precisely where the bytes are. See P1.

### C5 — improper-list input is silently accepted, then fails downstream `[S]`

`LazySeq::input` (159) rescues `erlang/length/1` on an improper list to `0` ("exactly as the
live `rescue ArgumentError` did") — `length/1` raises `badarg`/`ArgumentError` on an improper
cons while accepting a proper list and `[]`, so an improper list of 100 elements is classified
as short and passes through as a raw list. `LazySeq::cell`'s `(erlang/is_list x) x` branch
(601) then **accepts** it and returns it unchanged (`is_list` is shallow — the same observation
as §2 C1) — nothing normalises it — and the failure surfaces later: a walking consumer's
`(erlang/tl c)` eventually reaches the non-list tail: for a tail that is not itself seqable it
raises `badarg` (`erlang:tl/1` is undefined on a non-cons); for a seqable tail (a `LazySeq`
node, a map) `cell` normalises it and the walk *silently adopts it as the rest of the
sequence* — a wrong answer rather than an error. Behaviour preserved from the recalled Elixir
module; flagged as fragility, **not** a proven regression.

---

## 3. Performance findings

Each: anchor → mechanism → complexity → why it matters.

### P1 — fold realisation materialises and retains the whole sequence `[S]`

Anchors: `rt.bl::lazy-fold-pending` (3929–3974), `BeamLisp.LazySeq/publish_folded`
(lazy_seq.bl:236), `rt.bl::lazy-count` (1039), `lazy-fold` (3966).

```clojure
(fn [p x]
  (let [a2  (step f (erlang/element 1 p) x)
        buf (raw-cons x (erlang/element 2 p))]   ; ← one cons per element, unconditionally
    ... (tuple a2 buf false)))
```

`buf` grows with **every** element, whatever `f` is. On a non-halting fold:
`(erlang/apply :lists :reverse buf)` → `publish_folded` → `{:completed elems}`.

Cost of one `(reduce f init (map g coll))` or `(count (map g coll))` over n elements:

| pass | where | cost |
|---|---|---|
| 1 | `buf` accumulation | n cons (16 B each) + one 3-tuple per element |
| 2 | `lists:reverse` | n cons |
| 3 | `dependencies({:completed, list})` → `deps_walk` (the term is a 2-tuple, so `deps_scalar_list?` cannot fire) | O(n) BEAM walk |
| 4 | `estimate_bytes` → `erts_debug.flat_size/1` | O(n) |
| 5 | native `save` → `enif_make_copy` | approximately 2n list words copied into an `OwnedEnv` for small integers |
| retain | `RETAINED_BYTES += 16n + 24` for a completed small-integer list on this 64-bit VM | **Linear bytes held while the node remains rooted** |

`(count (map inc (range 10_000_000)))` is an extrapolation, not a measured run, and therefore allocates ~320 MB of BEAM list (transient),
copies about 160 MB into native memory per completed small-integer list, and **retains about 160 MB per such rooted memo** — for an operation whose answer is a
single integer. A streaming fold whose old head becomes unreachable can use bounded traversal storage; a caller that deliberately retains a memoized head necessarily retains realized values. No Clojure runtime comparison was measured in this review. The fold avoids a memo cell per element, but replaces those cells with a full list assembled before publication. Bytes are accounted by stats, but admission is not enforced on this publication path (C4).

Semantic constraint: deleting the buffer or skipping realization would violate the side-effecting-producer realize-once contract. Repairs must preserve that contract: bounded chunk publication with admission/reservation, or a separately explicit non-memoizing/purity-proven consuming fold. A tag-only peek must not change the existing `memo_state` API, which promises the full logical state.

Note the same `lazy-fold-pending` is used even when the recipe folds the *source*
(`lazy-reduce-source`, 3913): the `map`/`filter` recipes walk a `SeqCursor` in native memory
and then dump the whole result onto the BEAM heap to publish it.

Bounded probe: **PB2**.

### P2 — full-term export in dispatch-only positions `[S]`

`read_versioned_impl` (lib.rs:652) and `read_impl` (620) both call
`MemoCell::export` (140), which does `state.env.run(|owned| state.term.load(owned).in_env(env))`
— a full `enif_make_copy` of the cell's state term into the caller's heap. `Term::in_env`
(rustler 0.38, `src/term.rs:53`) copies whenever the env differs, which it always does here.

Callers that need only a **tag** or a **version**:

| caller | anchor | needs | pays |
|---|---|---|---|
| `pending_recipe` | lazy_seq.bl:203 | `:pending` tag + `element 1` | export of `{:pending thunk recipe}` / `{:completed value}` |
| `pending?` | lazy_seq.bl:218 | `:pending` tag | export (`read`) |
| `memo_state` consumers that inspect only its tag | lazy_seq.bl:508; e.g. Deferred | consumer needs tag; the existing public API itself promises full state | export; add a separate internal peek, do not narrow this API |
| `force_state` | lazy_seq.bl:455 | tag, then the value | export (the value case needs it; the `:running`/`:pending` cases do not) |
| `lazy-recipe`/`lazy-fold` | rt.bl:3920/3966 | `:pending` tag + version | export |
| `Deferred/realized?` | deferred.bl | `:completed` tag | export |
| `refs.update_watches` | refs.bl:158 | watch map | export (small) |

The sharp case: **the second `(count (map inc coll))`**. The first call materialises and
publishes an n-element list (P1). The second calls `lazy-count` → `lazy-recipe` →
`pending_recipe` → `read_versioned` → `export` → **copies the whole published list onto the
BEAM heap to discover that the state is not `:pending`** — then discards it and walks the
memo cells anyway. `(Deferred/realized? d)` on a delay holding a large value has the same
shape.

Complexity: O(|state|) per call, when O(1) suffices (a tag is one word in the cell).

Repair: **R2** (a `nif_state_tag/1` peek). Bounded probe: **PB3**.

### P3 — the fast lane is structurally bypassed by the publish path `[S]`

`exchange_version_impl` (lib.rs:694) self-guards:

```rust
if fast_lane && !added.is_empty() {
    drop(graph_lock); drop(cell);
    count(OP_REROUTE);
    return Ok(reroute());          // lib.rs:735–742
}
```

`added` is non-empty whenever the published state reaches a resource the cell did not
already hold. Two consequences:

1. The BL wrapper (`lazy_memo.bl::exchange_version`, 286) always tries the fast NIF first:
   `nif_exchange_version_fast` → `:reroute` → `nif_exchange_version`. So a publish that adds
   an edge costs **2 crossings plus a dirty-scheduler hop**, on every publish.
2. `DirtyCpu` adds scheduling/queueing latency, but does not inherently serialize all publications. This session measured the Elixir VM with 4 normal / 2 dirty-CPU / 1 dirty-I/O schedulers, and a plain Erlang VM with 16 / 16 / 10. The shared serialization point supported by source is the `GRAPH` mutex (P6); no dirty-scheduler contention attribution was measured.

The dominant shape hits it every time. A chunk value `[e1 … e32 | node]` (`LazySeq/chain`,
lazy_seq.bl:181) reaches the freshly-created tail node, so its dependency list is non-empty
(measured: 1 edge) and `added` is non-empty on every such publish — the fast attempt is a
crossing that cannot succeed. The shapes that DO stay fast are the ones with nothing new: a
`:keep` transition (claim, waiter registration, terminal state), or a dependency list that is
empty — e.g. the published fold value, a proper list of scalars inside `{:completed …}`
(measured: 0 edges). The BL side knows which of these it is passing (`attempt_deps`,
lazy_seq.bl:292, answers `:keep` or a list, and the list's length is visible) — it can route
without the wasted probe. See R3.

Repair: **R3**. Bounded probe: **PB1** (the `op_reroute` : `op_cas_fast` ratio).

### P4 — three full passes per create/publish, one crossing per handle `[S]`

`lazy_memo.bl::create` (227) and `exchange_version` (286) run, per call:

1. `dependencies(term)` (207) — a BEAM-side structural walk that allocates a `MapSet` for
   ids and crosses the NIF **once per embedded handle**: `nif_id` at `deps_walk` line ~160,
   `nif_dependency_resource` at line ~179 (`lib.rs:593`, `925`). The native file's own comment
   names this "the per-handle tax of the Elixir-side dependency walk (F5)" (lib.rs:47).
2. `estimate_bytes(term)` (386) — `erts_debug.flat_size/1 × wordsize`, an O(size) BIF at the
   ERTS, invoked through the BEAM.
3. native `save` (299) — `enif_make_copy` of the same term.

So a publish copies/traverses the value three times. The pre-checks that make this survivable
are real and worth keeping: `deps_scalar?` and `deps_scalar_list?` short-circuit a flat
produced chunk, and `estimate_bytes` special-cases control states to a constant 64
(lazy_memo.bl:386–410).

Complexity: O(size) × 3, plus O(#handles) crossings. The `MapSet` work in `deps_walk` is
O(#handles · log).

Bounded probe: **PB4**.

### P5 — a fresh cursor resource per 32 elements `[S]`

`lib.rs::cursor_chunk_impl` (541) creates a new sub-cursor for every chunk:

```rust
Some(Cursor::arc(state.env.save(remaining), cursor.source.clone(), cursor.dirty_chunks)?)   // 563
```

`Cursor::arc` (485) is `next_id()` + `ResourceArc::new` + `collector::register` (registry
`HashMap` insert under a **global mutex**, collector.rs:103). The consumed cursor's
destructor takes the same mutex to `unregister` (collector.rs:124). A 1 M-element walk creates
and destroys **31 250** cursors → ~62 500 global-mutex operations plus that much registry
churn (and `SINCE` counter traffic in the collector's scheduling).

Mitigating, verified: `state.env.save(remaining)` does **not** re-copy the tail. `remaining`
was loaded from `position` into a `Term` whose `Env` is the same `NIF_ENV` pointer as
`state.env` (`OwnedEnv::run` reuses `*self.env`, rustler `src/env.rs:214`; `in_env` returns
without `enif_make_copy` when the envs are pointer-equal, `src/term.rs:53`). So the chunk
walk is O(1) copy per chunk, not O(remaining). The per-chunk cost is the *resource*, not a
copy.

Bounded probe: **PB4** / `bench/memocell_bench.bl` `drain` row **[Q]**.

### P6 — one global graph mutex, held across the copy; O(prev·new) edge merge `[S]`

```rust
let mut edges = None;
if let Some(new_ids) = new_ids {
    let mut graph_lock = lock(graph());                       // lib.rs:731
    ...
    if would_cycle(&graph_lock, resource.id, &added) { ... }
    graph_lock.insert(resource.id, merged);
    edges = Some(graph_lock);                                 // guard kept alive
}
let replacement = save(replacement, retained_bytes);          // lib.rs:752 — O(size) under the lock
```

The same shape in `compare_exchange_impl` (848 → 871/872). `GRAPH` is a single
`Mutex<HashMap<u64, Vec<u64>>>` (lib.rs:278). Every non-`:keep` publish takes it, holds it
across `enif_make_copy` of the whole replacement term, and — because `edges` is never
dropped before the swap — across the state replacement too.

`edge_plan` (215–226):

```rust
for id in new_ids { if !merged.contains(id) { added.push(*id); merged.push(*id); } }
```

`merged.contains` is a linear scan → O(|previous|·|new|). Edges **never shrink** while a cell
is alive (documented, lib.rs:180–192), so a long-lived cell that repeatedly publishes values
embedding distinct resources grows its edge vector monotonically, and each publish clones it
(`previous.to_vec()`).

Complexity: publish latency = O(size) copy + O(|prev|·|new|) + BFS over the reachable set,
all under one global lock. That makes publish a serialisation point.

Repairs: **R6**, **R7**.

### P7 — `admit!` builds the 23-field stats map on every claim `[S]`

`lazy_seq.bl::claim_attempt` (361) calls `BeamLisp.LazyMemo/admit!` **before** the CAS, so it
runs on the retry path too. `admit!` (420):

```clojure
(when (erlang/>= (maps/get :retained_bytes (stats)) budget) ...)
```

`(stats)` is evaluated on every claim → one NIF crossing (`lib.rs:939`) that builds a
`NifMap` with 23 fields, plus `Application/get_env :beam_lisp :lazy_cache_budget_bytes` and
an integer validation. Per realised node — i.e. per chunk, not per element, since chunking
amortises it over 32.

At/over budget the path is worse: `erlang/garbage_collect/0` on the *forcing* process, then
`await-budget` (412) polls `stats()` in 1 ms `Process/sleep` steps for up to 25 ms, then
raises `ForceError(:lazy_cache_budget_exceeded)`. Every forcer does this independently, so a
budget-exhausted workload becomes a herd of sleep-polling processes.

Repair: **R5**.

### P8 — the collector serialises each cell's whole state to ETF under the state lock `[S]`

`State::census` (lib.rs:89) memoises once per `State` via `OnceLock`:

```rust
self.env.run(|env| collector::etf_keys(self.term.load(env).to_binary().as_slice()))
```

`to_binary()` serialises the **entire** term to external format. It is called from
`MemoCell::trace` (147), which `collect::()` calls for every pinned node while holding that
cell's `state` mutex. A round (collector.rs:442) pins **every** live resource, builds an
index `HashMap<Key, usize>`, an internal-count `Vec`, and an edges `Vec<Vec<usize>>`, then
marks — O(live) per round, with round frequency = the live count at the previous round
(floor `MIN_ROUND` = 16 384, collector.rs:520–529). Amortised O(1) per allocation, which is
fine.

The sharp edge is per-cell: a cell whose state is large (e.g. a P1-published fold list) is
serialised whole, in one allocation, while holding that cell's `state` mutex — so a reader or
forcer of that cell blocks behind it. Each `save` produces a fresh `State` (fresh `OnceLock`),
so this repeats after every publish. Separately, `trace` decodes the term through ETF because
`erlang:term_to_binary`-level structure is the only portable way to find resource references;
that is a genuine constraint, not an oversight — but the cost profile is worth knowing.

Bounded probe: **PB6** (collector on vs `nif_collector_status` off-path comparison is not
possible on this OTP; measure instead by timing a bounded walk with and without a forced
`collect_cycles` round).

### P9 — one indirect call per element in every materialisation and reduce walk `[S]`

The compiler lowers `recur` inside a `loop`/anonymous fn to **self-application** —
`(self self)(args)` — and only a linked top-level `defn` gets a direct named self-call
(`compiler.bl::compile-recur` 959–985, `self-apply` 946; a named `fn` binds its own name to
`self.(self)` at `compiler.bl:2250`). The lazy engine's own header records the measured
consequence: "a call through a closure is an INDIRECT call, and on this host an indirect call
costs up to ten times a direct one" (`lazy_seq.bl` header), which is why the whole force
protocol was pushed to top level.

The force protocol honours that. These do not:

| walk | anchor | form |
|---|---|---|
| `to_list` | lazy_seq.bl:608 | local named `fn step` |
| `prefix` | 619 | local named `fn step` |
| `count` | 645 | local named `fn step` |
| `nth` | 653 | local named `fn step` |
| `run` | 670 | local named `fn step` |
| `reduce-lazy` | rt.bl:3776 | `loop`/`recur` |
| `reduce-cursor` | 3889 | `loop`/`recur` |
| `reduce-seq` | 3867 | `loop`/`recur` |
| `reduce-list` / `count-list` / `nth-list` | 3764 / 1023 / ~1060 | `loop`/`recur` |
| `lazy_seq_enumerable::do-reduce` | — | local closure (by ABI necessity) |

So `(count lazy)` / `(doall lazy)` / `(reduce f x lazy)` pay one indirect call per element on
top of `LazySeq/cell`. `force` pays none. Against the tens-of-ms-per-element captured-env
baseline **[Q]** this is second-order, but it is a constant factor on the hottest loop in the
system, and it is inconsistent with the design rule the module states for itself.

The top-level-vs-local choice is genuinely constrained: the pinned emitter exports **every**
top-level `defn` and does not privatise `defn-` (`aot.bl::compile_host_file` 141; the same
divergence is documented in `lazy_memo.bl` and `refs.bl`). So top-level helpers buy direct
calls at the cost of ABI surface. `lazy_memo.bl` accepted that trade (`deps_*`); `lazy_seq.bl`
accepted it for the force protocol but not for the walks.

Repair: **R9**.

### P10 — a `fun_info` BIF hoisted out of its error branch, per node creation `[S]`

`lazy_seq.bl::new/1` (110), `new/2` (assume same shape) —

```clojure
(let [own (erlang/element 2 (erlang/fun_info (fn [] nil) :module))]
  (if (erlang/is_function thunk 0) <happy path> (erlang/error ... own ...)))
```

`own` feeds only the `FunctionClauseError` branch, but is computed unconditionally. `new/1`
runs once per lazy node — i.e. once per 32 produced elements — and `from_fun` (147) is the
`lazy-seq` expansion target, so it is on the boot edge as well. `force` (488), `realize`
(570), `prefix` (619), `nth` (653), `pending?` (218) and `memo_state` (508) correctly keep
the read inside the error branch; `new/1` and `new/2` do not.

Complexity: O(1), one BIF call per node creation. Repair: **R10**.

### P11 — the chunk width is a literal in four places `[S]`

| site | value |
|---|---|
| `lazy_seq.bl::chunk_size` (105) | `32` |
| `lazy_seq.bl::input` (159) | threshold `(erlang/> size 32)` |
| `lib.rs::cursor_chunk_impl` (552) | `for _ in 0..32` |
| `lib.rs::cursor` (525) | `avg.saturating_mul(32)` |

The BL producers read `BeamLisp.LazySeq/chunk_size`; the native chunk length is compiled in.
They agree today. The `dirty_chunks` lane decision (`avg*32 > fast_lane_bytes`) silently
becomes wrong if either moves. Not a defect now — a coupling with no single source of truth.
Repair: **R11**.

### P12 — `for` is the only headline producer with no fold recipe `[S]`

`core.bl::for` (1305) expands to `lazy-seq` + `loop` + `BeamLisp.LazySeq/chain` — chunked and
correct, with the deliberate flat-`concat` tail. But it attaches no `new/2` recipe, whereas
`lazy-map` (2474), `lazy-filter*` (2572) and the `chunked` producers do. So `(count (for …))`
and `(reduce … (for …))` go through `lazy-recipe` → nil → `reduce-lazy`, the memo-cell walk,
while the equivalent `map` goes through the recipe. The bench measures `for` in the same
table as `map`, so the two rows are not comparable mechanisms. Consistency item.

Repair: **R12**.

### P13 — `LazySeq::cell`'s catch-all materialises any other Enumerable `[S]`

`cell` (589) ends with

```clojure
:else (let [impl (Enumerable/impl_for x)]
        (if (erlang/== impl nil) x (normalize_cell (Enum/to_list x))))
```

So `cell` on any unrecognised Enumerable is O(size) — it builds the whole list to take a
head. Reachable through `(lazy-seq <coll>)` (a `LazySeq` body may return any seqable, which
`realize_step` 544 will then normalise) and through any producer step handed a
non-normalised collection. The Vector/Set/binary branches (realize_step 544: `Vector/to_list`,
`Set/to_list`, `String/graphemes`) have the same shape but are bounded by the jank use case
the module documents. Note `k-first` (rt.bl:956) does **not** have this problem — it uses
`Vector/first`/`Vector/nth` — so the cost is confined to the lazy-normalisation path.

Repair: not proposed; flagged as a documented cost with an unbounded `:else`.

---

## 4. Bounded probes (proposed; PB5's expression was run — see §2 C1)

All are single `bin/bl run` programs, memory-capped, n ≤ 16 384 unless stated, and read
existing public surface (`LazyMemo/stats`, `erts_debug`, `:erlang.memory`) — no new code.
(PB5's expression was already run, as `bin/bl eval`; its outcome is in §2.)

- **PB1 — lane ratio (P3).** Run `bench/lazy_scaling.bl -- 2000`, then read
  `BeamLisp.LazyMemo/stats/0` before/after. Expected from source (C1 RETRACTED): `op_reroute`
  grows ≈ one per chunk publish on the `map`/`filter` rows — each chunk value reaches a fresh
  tail node, so `added` is non-empty (lib.rs:735–742) and the fast attempt cannot succeed. A
  `map` row whose `op_reroute` ≈ 0 would falsify *that* reading; a `op_lane` ≠ 0 reading is a
  regression sentinel (lib.rs:44).
- **PB2 — fold memory (P1, C4).** One program: for n ∈ {2 000, 4 000}: (a)
  `(count (map inc (range n)))`, sample `:retained_bytes` from `stats/0`; (b) the same with
  `take`; (c) `(erlang/memory :total)` delta around each. Prediction: `retained_bytes` grows
  ≈ 8·n·wordsize after (a) and stays flat after (b). n↔2n doubling of `retained_bytes` proves
  the retention is linear and ungated.
- **PB3 — dispatch export (P2).** Time `(count (map inc (range n)))` twice in a fresh process:
  first vs second. Prediction: the second is slower than the first's walk alone by an O(n)
  copy. Cross-check with `(Deferred/realized? …)` over a delay holding a large list.
- **PB4 — crossing ledger (P4, P5).** Wrap a bounded walk in `stats/0` deltas and print
  `op_read_fast, op_read, op_cas_fast, op_cas, op_reroute, op_cursor_chunk_fast,
  op_dependency_resource, op_id`. Prediction from source: per chunk ≈ 1 `op_read_fast` (force)
  + 1 `op_read_fast` (claim) + 1 `op_cas_fast`-with-`:keep` + 1 `op_read_fast` + 1 `op_cas_fast`
  (publish) per node, and `op_cursor_chunk_fast` = chunks. Deviations localise the cost.
- **PB5 — run; it retired C1 rather than confirming it.** The expression below was executed
  this session, and the outcome is recorded in §2 (C1, RETRACTED): `(dependencies (raw-cons 1
  node))` → 1 edge, `(dependencies (raw-cons 1 ()))` → 0, `(dependencies (Vector [node]))` → 1.
  The probe as first written PREDICTED `()`; that prediction was wrong and is withdrawn. This
  is now a "do not re-run" pointer, not a pending check.
- **PB6 — collector census cost (P8).** Time a bounded `(count (map inc (range n)))` with and
  without a forced `BeamLisp.LazyMemo/collect_cycles/0` interleaved; compare against
  `collector_status/0` (which reports `""` when the collector is on, so the on-path is
  testable on this OTP 29 host per the roster **[Q]**).
- **PB7 — graph lock contention (P6).** `bench/memocell_bench.bl` section D already builds a
  2 000-deep dependency chain; extend the depth sweep (200/2 000/20 000) on this host and fit
  the build time. O(depth) is healthy; super-linear indicts `edge_plan` and the locked copy.
  **[Q]** the existing section D is the template.

Do **not** use the roster's baseline wall times as the comparison arm; use same-host,
same-load, same-n pairs only (the bench header states this rule itself).

---

## 5. Proposed repairs (bounded, ordered)

| # | Repair | Files | Notes |
|---|---|---|---|
| **R1** | Reserve/admit bytes on fold publication and design bounded memoized chunk publication that preserves realize-once, failure replay, and the `{acc elems}` contract. Do not leave a fully consumed producer pending to recompute it. Non-memoizing consumption requires a separately explicit API or a sound purity proof. | `rt.bl::lazy-fold-pending` 3929, `lazy-count` 1039, `k-to-list` 1197, `lazy_seq.bl::publish_folded` 236 and force/admission protocol | A redesign requiring consumer/protocol tests, not a two-function edit. Returning only an accumulator or nil elements breaks count/to-list; skipping completed publication repeats side effects. The earlier bounded-skip proposal is withdrawn as unsafe. |
| **R2** | Add `nif_state_tag/1`, answering `{:pending\|:completed\|:failed\|:terminal\|:running, version, …}` from the cell state tag + version **without exporting the term**; use it for tag-only decisions in `pending?`, `lazy-recipe`/`pending_recipe`, `Deferred/realized?`, and `force_state` dispatch, followed by a full read when the recipe/value is actually needed. Preserve the public `memo_state` full-state API unchanged. Revalidate the peek version on later reads/CAS or retry; do not assume two reads see the same state. | `lib.rs` (new NIF + stub in `lazy_memo.bl`), `lazy_seq.bl` 203/218/455/508, `rt.bl` 3920 | Removes O(\|state\|) copies from dispatch (P2). `force_state`'s `:completed` branch still exports (it must). |
| **R3** | In `lazy_memo.bl::exchange_version/5` (286), when `deps_mode` is a **non-empty list**, call `nif_exchange_version` directly; keep the fast attempt when it is `:keep` or `()` (they may still reroute because current/replacement byte size exceeds the fast-lane limit). | `lazy_memo.bl` 286 | Saves one crossing on the dominant publish (P3). Independent of every other repair — the former "must land with R4/C1" coupling is withdrawn. `added` is not knowable BL-side, so validate with PB1 before adopting. |
| **R5** | Add `nif_retained_bytes/0` (one atomic load) and use it in `admit!` instead of `stats/0`. | `lib.rs`, `lazy_memo.bl` 420/470 | Removes a 23-field map build per claim (P7). Also consider caching `Application/get_env` in `:persistent_term` (it is a config value). |
| **R6** | Do not hold `GRAPH` across `save`: copy outside the global lock only with a carefully specified two-phase protocol; after reacquiring it, revalidate local state/version AND recompute `edge_plan` AND rerun `would_cycle` against the current graph immediately before insertion/publication. | `lib.rs` 730–752, 848–872 | Removes O(\|value\|) work from the global lock window (P6). Local version/added-edge checks alone are insufficient: while A copies a planned A→B, B can publish B→A. Fresh cycle validation must be atomic with insertion. Preserve lock ordering, collector detach validation, and notifications; measure wasted copies/retries before adopting. |
| **R7** | Make `edge_plan`'s membership test a `HashSet` (or keep the linear scan and compact edges when `previous.len()` exceeds a bound). | `lib.rs` 215 | Removes the O(\|prev\|·\|new\|) term (P6). |
| **R8** | Investigate cheaper immutable cursor positions over shared backing storage, or allocation/registration reuse that preserves replay. Destructive in-place advancement is not a drop-in replacement for an immutable cursor. | `lib.rs` 464–571, `seq_cursor.bl` 50/63 | Potential cursor cost reduction (P5); size of the win is unmeasured. Repeated reads of the same cursor and independent/interleaved consumers must still see identical positions. Keeping an exported function's signature is not enough to preserve its semantics; test replay, sharing, collector references, and multiple consumers before changing the representation. |
| **R9** | Move the per-element materialisation walks (`to_list`, `prefix`, `count`, `nth`, `run`) and, where ABI permits, the `rt.bl` reduce walks, to direct-call form (top-level helpers, as `deps_*` already are). | `lazy_seq.bl` 608–675, `rt.bl` 3764/3776/3867/3889 | Removes one indirect call per element (P9). The `rt.bl` walks are boot-tier and cannot export extra names — measure before touching them; the host walks are unconstrained (already exported). |
| **R10** | Move the `own` module read in `new/1`/`new/2` into the error branch. | `lazy_seq.bl` 110, 135 | One BIF per node creation (P10). |
| **R11** | Single source of truth for the chunk width: expose `nif_chunk_size/0` and have `LazySeq/chunk_size/0` read it (or freeze all four sites and add a test asserting equality). | `lib.rs`, `lazy_seq.bl` 105 | Removes the silent-drift coupling (P11). |
| **R12** | Give `for` a fold recipe (or route it through `chunked`) so its reduce/count path matches `map`'s. | `core.bl` 1305 | Consistency + cost (P12). |

Suggested order: **PB1/PB4 → R3 → R2 → PB3 → R1+C4 gate → R5 → R6/R7 → R8 → R9/R10/R11/R12.**
PB1/PB4 first because P3's reroute profile is the one structural claim the retraction in §2
*strengthened*; confirm it at the pre-repair level before R3 changes what is being measured.
There is no longer a correctness-driven pair to land first — R4 is withdrawn (§2 C1).

---

## 6. What I did not verify, and what would change the conclusions

- **Two probes were run, and both refuted a claim rather than confirming one.** Every
  performance claim below remains a complexity/counting argument from source plus the in-repo
  bench **[Q]**. The two executions were against the dependency walk: `erl ...
  erlang:is_list([1|foo])` → `true`, and two `bin/bl eval` dependency counts (`{1, 0, 1}` and
  `{0, 1}`), both recorded in §2 (C1, RETRACTED). The retraction is settled by observation,
  not by reading — the earlier draft's error was trusting a recalled BIF semantic over a test.
- **The roster's baseline numbers (13 s / 27 s / 100 s at n=2000) are not attributed to any
  mechanism here.** They were taken under load/swap; the roster says so; I have no
  same-host, same-load pair. If a reader wants a cause, PB1/PB4 on the *baseline* checkout is
  the only honest route.
- **Rustler 0.38 semantics were read from the vendored crate source** (`~/.cargo/registry/.../rustler-0.38.0/src/{env.rs,term.rs}`) to settle whether `cursor_chunk_impl`'s
  `state.env.save(remaining)` re-copies the tail. It does not (`OwnedEnv::run` reuses the same
  `NIF_ENV`; `in_env` short-circuits on pointer equality). If that ever changes, the chunk walk
  becomes O(n²/32) — worth a test that pins it (a chunk walk over a 1 M list under a heap cap).
- **`force_state`'s waiter protocol** was traced for a hang on owner death and found sound
  (monitor-before-register; registration CAS version-guarded; `owner_lost` publishes to every
  registered waiter; `:keep` cannot answer `:cycle`). No bug claimed; no probe run.
- **`collect()`'s soundness** (mark/validate/detach ordering) was read but not re-derived;
  out of scope for this review beyond its per-round O(live) cost and the ETF census path.
- **`bench/memocell_bench.bl` sections A–J [Q]** are a ready-made harness for P4/P5/P6/P7 and
  were not run. Section J's rows (captured-env cost, `swap! assoc` at k=10 000) are the
  historical witness for the captured-environment class this integration was built to remove.
