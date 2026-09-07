# Shared LazySeq memo cutover contract

User approved full structural fix. One implementation for every LazySeq consumer; no compiler-only mode, eviction, or raised cap. All .bl author syntax stays unchanged. Existing non-owned source changes must be preserved.

## Native API: BeamLisp.LazyMemo

New Rustler cdylib native/lazy_memo, installed by existing native compiler as priv/native/lazy_memo.so. New host module lib/beam_lisp/lazy_memo.ex owns lazy NIF loading (not on_load at Elixir compile time, because native compilation runs after Elixir). Public wrapper ensure_loaded! uses a serialized first-load path and a fast persistent marker; clear actionable error when artifact missing. No pure-ETS fallback.

Primitive methods (functions replacing NIF stubs):
- new(state, dependency_resources, estimated_bytes) -> resource
- read(resource) -> state (copy into caller env)
- compare_exchange(resource, expected_state, new_state, dependency_resources, estimated_bytes) -> :ok | :retry | :cycle
- id(resource) -> positive integer, stable for resource lifetime
- stats() -> %{live_cells: N, retained_bytes: N, pending_reclaims: N}
State terms opaque to native layer. Compare must use exact term identity/equality appropriate for Erlang refs/functions, not byte serialization. Dependency list contains actual resource handles (deduplicate by id internally). API does not expose resource handles in global registries.

Resource owns one SavedTerm in an OwnedEnv behind short mutex; state reads/CAS run native only for bounded structural operations, never Lisp/user callbacks. Reject invalid sizes; use resource allocation overhead + estimate, saturating accounting to avoid wrap. No panic on poisoned mutex/untrusted decode.

A native global graph maps integer ids to dependency integer ids ONLY, never ResourceArc or Erlang terms. Updates atomic with successful CAS. Reject any new dependency edge that would make resource transitively depend on itself; return :cycle without mutation. Build dependencies outside native locks. Compare expected first, then graph validate, publish state and accounting coherently. Fixed lock order: cell then graph; destructor must not acquire another cell lock while holding graph. New unique resource can depend on existing resources. Graph removal occurs at resource destruction. This supplies explicit rejection of reference cycles among visible lazy handles instead of leaking them.

Avoid recursive destructor stack overflow on long sequence chains: drop resource state by sending OwnedEnv to one native reclamation queue/thread. Drop popped env OUTSIDE queue/graph/cell locks. Descendant destructors enqueue their env, making release iterative. Queue is transient, not permanent rooting. Stats expose pending queue for deterministic test convergence. Initialize worker safely once. No enif_send from arbitrary thread unless Rustler documented safe API; a Rust-only queue is sufficient. Crate and ordinary graph state are shared only within this module version; document safe NIF upgrade restrictions rather than assuming cross-version resources interchangeable.

## Host LazySeq state machine

Use only resource handle in LazySeq struct (no copied thunk/key/tid/generation that keeps inputs forever). Preserve rest of sequence traversal/Enumerable APIs unchanged.

States:
{:pending, thunk}
{:running, thunk, owner_pid, attempt_ref, waiter_pids}
{:failed, thunk, kind, reason, stacktrace}
{:completed, value}
{:terminal, reason}

Claim CAS pending/failed -> running. Execute thunk in caller, never Loader.Server or NIF owner hop. On success publish completed, dropping thunk. Waiters register CAS + monitor owner; owner sends per-attempt outcome to registered waiters after successful CAS. Failed outcome delivered to attached waiters; later force may retry. Monitor races must not strand callers or leak monitor messages. If running owner is self, recursive_force error. If owner died, CAS terminal force_owner_lost; never repeat ambiguous effects. No global memo owner exists; Loader.Server restart does not invalidate resources. Ensure resource remains live across force/wait with explicit lexical argument/reference used through operation. On cycle-rejected outcome publish terminal cyclic_memo error without retaining offending result/reason (and release thunk if terminal); notify waiters. Error reason/stacktrace may themselves capture lazy handles: apply same dependency detection to failures and avoid retaining self in diagnostic payload.

## Host dependency enumeration

Before native new/CAS, walk the state term for resource handles wrapped in %LazySeq{}; stop traversal at a LazySeq (its transitive children are native graph edges, not recursively re-read). Also traverse tuples, proper/improper lists, maps keys+values, and Erlang function environments via :erlang.fun_info(fun,:env). Deduplicate visited resource ids and repeated function identities to avoid redundant closure work; arbitrary nesting must not blow stack (worklist). The host LazyMemo resource itself is reference-like: support bare LazyMemo handles if exposed as documented internal API or keep exposure internal. Opaque third-party native resources may hide refs that cannot be inspected: do not claim general tracing collection across foreign NIF graphs; document boundary.

Size estimate uses :erts_debug.flat_size(state)*wordsize (not a hard physical heap bound; excludes external binary shared ownership details). Native stats include resource overhead. Existing lazy_cache_budget_bytes remains a SOFT admission check of live retained bytes before new attempt; successful results still accessible under pressure, default remains 512 MiB. No whole-table or live-resource eviction. Main win is actual reclamation, not policy relaxation.

## Cleanup and verification

Remove LazySeq-specific table/monitor ownership code from Loader.Server once no caller remains. Rewrite ETS-layout tests as observable state/diagnostic tests; preserve sharing, failures, owner death, loader-busy progression coverage. Replace table-owner death expectations with resource survival across Loader.Server restart (state now independent). Add concurrent claims, independent nodes, captured handles, GC after many discarded nodes, long chain reclamation, real live handles surviving GC, direct and indirect result/capture cycles, and default-budget compiler build regression. Preserve chunking and laziness tests.

Native worker may run cargo check/test ONLY its new crate; runtime worker may run standalone Elixir syntax checks but no project-wide compilation. Orchestrator integrates native build, then focused tests, full build/tests, reproducibility, memory plateau and iteration measurements. Update docs tutorial after actual behavior verified. Do not regenerate seed during iteration.
