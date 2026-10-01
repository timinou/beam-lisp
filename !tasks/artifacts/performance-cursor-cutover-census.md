# PLAN-155 — immutable cursor root + in-place census

Findings addressed: `performance-lazy-review.md` **P5** (a fresh cursor resource per
32 elements) and **P8** (the collector serialises each cell's whole state to ETF under
the state lock). Companion: `performance-review.md` finding **7** (native state/graph
serial and copy amplification).

Files touched (5):

| file | change |
|---|---|
| `native/lazy_memo/src/lib.rs` | cursor ROOT cutover; `State::census` → in-place walk; `resource_key`; `OP_CURSOR_NEW` + `CURSOR_POSITIONS`; `MemoStats.op_cursor_new`/`cursor_positions`; unit tests |
| `native/lazy_memo/src/collector.rs` | `census_keys` (in-place structural walk, closure/unknown-only ETF fallback); calibration cross-checks the walk against `etf_keys`; unit test |
| `priv/host/lazy_memo.bl` | cursor ABI documented: root + `{root, index}` token, handle = either spelling; `deps_walk` note |
| `priv/host/seq_cursor.bl` | `:tail` documented as a HANDLE (root or token); no code change (the struct reads `:chunk`/`:tail`/`:dirty` by key and passes `:tail` straight to `cursor_chunk`) |
| `test/bl/host_seq_cursor_test.bl` | handle predicate; boundaries `0/1/31/32/33/40/63/64/65/100`; 16k repeated head + repeated full walk; one-resource-per-walk counter; replay; collector occurrence/closure/reachable regressions |

## Invariants proved by construction (and by the new tests)

1. **One native allocation per walk.** `nif_cursor` mints the only `Cursor`
   resource of the walk; every later position is an ordinary BEAM 2-tuple
   `{root, index}` referencing it. `op_cursor_new` therefore grows by 1 per walk
   for **any** length (measured in `cursor-walk-mints-one-native-resource-whatever-its-length`
   for `n ∈ {0,1,32,33,64,1000,16384}`). The old shape allocated/registered one
   resource per chunk → `n/32`.
2. **The position index costs `ceil(n/32) + 1` saved handles**, built once, in the
   source's own `OwnedEnv`, by walking the list that `allocate` already saved
   there. Every boundary `save` is O(1) (same-env `in_env` short-circuit, Rustler
   `env.rs:53`), so the build is O(n) — no tail copy, and no chunk pull scans
   from the head. Exposed as `nif_stats.cursor_positions`.
3. **A pull is a pure read of `(root, index)`.** Chunk `k` is the first 32 heads
   at `positions[k]`; the tail is `{root, k+1}` iff `k + 1 < ceil(n/32)`, else
   `nil`. `has_tail(index, positions) = index + 2 < positions.len()` — the index
   always ends with the empty list, so the rule matches `remaining.is_empty_list()`
   exactly. Replay, sharing, and interleaving are covered by
   `a-pull-reads-so-the-same-handle-replays`.
4. **The census is occurrence-exact without serialising a whole state.**
   `collector::census_keys` walks the saved term in place: `TermType` (public
   `enif_term_type`) classifies each subterm; conses, tuples and maps are
   descended (so a resource appearing 20 times reports 20 keys); a subterm that
   IS a collector node is resolved by `resource_key`
   (`MemoCell | Cursor | seen::Seen` — every pinnable type, so the walk is
   graph-equivalent to ETF); leaves are skipped.
5. **ETF is used only where the public API cannot reach.** A closure's captured
   environment has no installed NIF accessor, so a `Fun` subterm is serialised
   **by itself** and read by the proven `etf_keys`; a `TermType::Unknown` subterm
   is read the same way rather than guessed at. `Some(keys)` for the whole state
   is returned only if every subterm was readable; otherwise `None` → `Traced::Opaque`
   → a conservative root that is never collected through (fail open).
6. **No new unsafe assumption.** The walk uses `enif_term_type`, `enif_get_list_cell`,
   `enif_get_tuple`, the map iterator and `enif_get_resource` through Rustler's
   safe API. The only unsafe ERTS knowledge in the module is the pre-existing,
   runtime-calibrated `Layout`.
7. **The calibration now proves the walk, not just the layout.** Before the first
   round, `calibrate` builds a probe term mixing list/tuple/nested-list shapes,
   reads it twice — once with `etf_keys`, once with `census_keys` — and requires
   the same occurrence multiset (order aside). Disagreement leaves the collector
   OFF (`collector_status` non-empty), never collecting through a wrong census.
   Weak registry / strong trace / notifications are untouched: `register`,
   `Node::trace`, `quiet`, `detach` and the round's mark/validate order are
   unchanged.
8. **`Seen` and the ETF reader are preserved.** `Seen::admit` still uses
   `etf_keys` on each admitted key; `etf_keys` remains public for calibration and
   fallback. `Cursor::trace` still visits only its source key — the positions
   alias the source's own saved terms, so the source's census already covers
   every reference they hold and the index adds no reference of its own.

## ABI

Unchanged at the BEAM boundary:

- `nif_cursor/3` → the ROOT resource (a reference, chunk 0). `SeqCursor.new/1`
  stores it in `:tail`, exactly as before.
- `nif_cursor_chunk_fast/1`, `nif_cursor_chunk/1` → `{chunk, tail}`; `tail` is
  `nil` or the `{root, index}` token. `chunk` is still a raw Erlang list of at
  most 32 heads.
- `nif_cursor_dirty_chunks/1` → boolean; accepts the root or a token.
- `nif_dependency_resource/1` → unchanged; `deps_walk` reaches the source
  through the token's root element (tuple arm → reference arm), so a walk handle
  remains a graph boundary.
- `nif_stats/0` gains `op_cursor_new` and `cursor_positions` — additive; every
  pre-existing key keeps its name and meaning.

## Expected counter readings (counts only — no timings)

For a single **new + full walk** of a list of length `n` on the fast lane:

| n | `op_cursor_new` Δ | `op_cursor` Δ | `op_cursor_chunk_fast` Δ | `cursor_positions` Δ |
|---|---|---|---|---|
| 0 | 1 | 1 | 1 | 1 |
| 1 | 1 | 1 | 1 | 2 |
| 32 | 1 | 1 | 1 | 2 |
| 33 | 1 | 1 | 2 | 3 |
| 100 | 1 | 1 | 4 | 5 |
| 16 384 | 1 | 1 | 512 | 513 |

`op_cursor_new` is the O(1)-vs-`n/32` proof: the OLD shape read `n/32` here
(512 for `n = 16 384`) because each pull minted and registered a sub-cursor.
`op_cursor_chunk_fast` stays `ceil(n/32)` — the pull COUNT is unchanged; each
pull's cost is now one tuple instead of one resource, one `next_id` and one
registry insert/remove under the collector's global mutex. (The counts are for
one walk of a fresh cursor; the head `cell` that reads an already-pulled chunk
adds no pull.)

Collector counters to watch on an occurrence test (`live_cells` delta over
`settle!`): `cycle_enabled true`, `cycle_aborted 0`, and a nonzero
`cycle_collected`; the 20-occurrence self-cycle must NOT survive a round.

## What this session verified, and what it did not

Verified here: `cargo check` clean; `cargo test --lib` **29 passed / 0 failed**
(the three new cursor-index/tail invariant tests and the census
canonical-order test included).
`priv/host/lazy_memo.bl`, `priv/host/seq_cursor.bl` and the test file were read
for bracket/structure balance (the harness VM is not reachable from this
session, so no BL compile was attempted).

Not verified here (left to the orchestrator, as instructed): the native rebuild,
the seed/image regeneration, and the live BL suites —
`test/bl/host_seq_cursor_test.bl`, `test/bl/memo_bounds_sunset_port_test.bl`,
`test/bl/host_lazy_memo_test.bl`, `test/bl/ref_cycles_test.bl`,
`test/bl/lazy_budget_test.bl`. Those are the gates that can confirm the ABI
transparency, the counters above, and the collector regressions.

Residual, stated rather than hidden: a resource of a non-collector type that is
embedded **directly** (not inside a closure) in a memo state is no longer
reported by the census. It cannot match the collector's index, so the graph is
unaffected; `Seen` — the one non-cell pinnable type — IS resolved, and any
resource captured by a closure still arrives through the ETF fallback.
