# PLAN-092 LazySeq structural ownership audit

## Scope and contract

Read-only audit of `lib/`, `priv/`, `test/`, `native/`, packaging, and bootstrap integration against `PLAN-092-native-memo-contract.md`. The central cutover is `%BeamLisp.LazySeq{resource: resource}` + `BeamLisp.LazyMemo`; author-facing `.bl` syntax and the public traversal API remain unchanged.

## Executive result

The cutover is correctly central: all language and runtime lazy producers already construct through `BeamLisp.LazySeq.new/1` or `from_fun/1`, and all ordinary consumers force through `LazySeq.cell/1`, `force/1`, or higher-level traversal helpers. They benefit automatically once `lib/beam_lisp/lazy_seq.ex` is replaced.

Edits are nevertheless required outside that runtime sibling file:

1. `lib/beam_lisp/loader_server.ex` — remove LazySeq monitor ownership; retain serialized loader execution and ownership of unrelated registries.
2. `lib/beam_lisp/meta.ex` — replace direct `key` mutation/pattern access. Metadata identity must no longer piggyback on removed memo-table identity.
3. `test/beam_lisp/wave23_lazyseq_test.exs` — rewrite ETS-layout and Loader.Server-death assertions to observable resource/state behavior and add structural ownership/cycle/reclamation coverage.
4. `lib/beam_lisp/ex_unit_case.ex` and `lib/mix/tasks/beam_lisp.test.doctor.ex` — remove stale claims that LazySeq is a VM-global registry requiring async opt-out.
5. Native/package integration — ensure `native/lazy_memo` is always built/packaged for any usable BeamLisp runtime; unlike optional `defnative` backends, this NIF has no fallback.

No compiler-only patch is needed or desirable. Compiler-created lazies, core library lazies, RT lazies, vectors flowing into lazy operators, and Elixir `Enumerable` consumers all converge on the same runtime implementation.

## Exact structural access inventory

### Central implementation — cut over here

- `lib/beam_lisp/lazy_seq.ex`
  - Current struct: `key`, `generation`, `tid`, `thunk`; all must be replaced by the resource handle only.
  - Current ETS state machine: `force_bound`, `force_state`, `claim_attempt`, `evaluate_attempt`, `publish_attempt`, `wait_for_attempt`, `lookup`, `compare_replace`, `admit_attempt!`, `owner_lost`, `memo_owner_lost`, `ensure_table`, `ensure_owned_table`; replace with the fixed `BeamLisp.LazyMemo` resource API/state contract.
  - Preserve `new`, `from_fun`, `lazy?`, `chain`, `realize`, `cell`, traversal helpers, `Enumerable`, and `Inspect` externally.

- `lib/beam_lisp/lazy_memo.ex`
  - New fixed host substrate already exists in the dirty tree and matches the intended direction: explicit serialized NIF load, `create/exchange`, iterative dependency enumeration, flat-size estimate, budget admission, and NIF stubs.
  - Runtime integration must ensure every NIF call that can occur first (`exchange`, `read`, `id`, `stats`, not only `create`) is either internal after `create` or calls `ensure_loaded!`; document/enforce that invariant.
  - Dependency walker currently recognizes wrapped `%LazySeq{resource: ...}` only. This is sufficient if raw resources never escape. Keep the raw handle internal; otherwise add an explicit internal wrapper clause rather than claiming generic resource tracing.
  - `admit!/0` currently rejects only `retained_bytes > budget`; contract says admission before a new attempt, default 512 MiB. Confirm intended edge (`>=` is normally the correct “at budget” rejection) in focused tests.

### Required edits outside runtime sibling scope

- `lib/beam_lisp/loader_server.ex`
  - Remove `lazy_monitors` state, `async_monitor_lazy_owner/3`, `async_demonitor_lazy_owner/2`, lazy monitor casts, and `handle_info/2` calls to `LazySeq.owner_lost/4`.
  - Restore `init/1` to state needed by loader duties only. Do **not** delete `run/1`: it still serializes namespace/module/table initialization and owns unrelated Native/PerfProbe tables.

- `lib/beam_lisp/meta.ex`
  - Direct dependencies: docs name `:key`; `with_meta/2` updates `%LazySeq{lazy | key: make_ref()}`; `meta_key/1` pattern-matches `key`.
  - A resource-only struct cannot clone by changing a key. `with_meta` must preserve the contract “fresh lazy node, independent realization” by constructing a new LazySeq from a thunk that realizes/returns the source sequence, or via one intentional LazySeq clone API that creates a fresh resource. It must not reuse the same resource if metadata remains per-instance.
  - Metadata lookup needs an identity derived without exposing the resource globally. Preferred: `LazySeq.id/1`/an internal identity accessor backed by `LazyMemo.id(resource)`, namespaced as `{:meta_of, id}`. This metadata registry remains permanent under current semantics (see cache classification), so native IDs must never be reused during a VM lifetime or metadata can alias a later cell. Alternative: put metadata on the struct, but that violates the approved “only resource handle” struct.
  - Update boundedness/docs: realization is reclaimable; metadata entries are not automatically reclaimed and must not be described as sharing the old memo-cache tradeoff.

- `test/beam_lisp/wave23_lazyseq_test.exs`
  - `await_waiter_registered/1` directly destructures `key/tid` and reads ETS state: replace with an observable synchronization hook (messages/barriers around thunk execution) rather than native internals.
  - Keep/rewrite observable sharing, failed-attempt retry, recursive force, owner death, concurrent claims, unrelated-node progress, Loader.Server-busy progression, and caller-context tests.
  - Delete expectations for `memo_owner_lost` after Loader.Server death/restart. Replace with an already-created/completed and pending resource surviving restart.
  - Budget tests must account for process-global native live cells from other tests; use before/after `stats` or isolated lifetime, never assume an empty global table.
  - Add direct/indirect result and closure-capture cycle rejection; failed diagnostic self-cycle; captured-handle dependency; discarded-node GC; live-handle survival; long-chain iterative reclamation; `pending_reclaims` convergence; independent nodes; exact once-sharing under concurrency.

- `lib/beam_lisp/ex_unit_case.ex`
  - Remove `BeamLisp.LazySeq` from documented VM-global registries and from the rationale for `async: false`. Native graph/stats are global implementation accounting, but ordinary LazySeq values are resource-owned and do not create cross-test mutable registry semantics.

- `lib/mix/tasks/beam_lisp.test.doctor.ex`
  - Remove/update the audit needle `{"BeamLisp.LazySeq", "lazy-seq realization cache is VM-global"}`. Retain warnings for genuine global registries.

### Direct structural access that remains valid

These pattern-match only the struct type, not removed fields, and require no cutover edits:

- `lib/beam_lisp/form_meta.ex` — delegates metadata operations.
- `lib/beam_lisp/multi.ex` — classifies LazySeq as `:seq`.
- `lib/beam_lisp/rt.ex` — type dispatch/predicates.
- `lib/beam_lisp/sorted.ex` — detects a LazySeq improper-list tail and calls `to_list`.
- `test/support/beam_lisp_test.ex`, `test/beam_lisp/wave27_taggedlet_test.exs`, `test/beam_lisp/sorted_test.exs`, `test/beam_lisp/wave14_meta_test.exs` — public struct/API use only, except metadata behavior may need expectation updates if identity implementation changes.

## Automatic beneficiaries: all lazy producer/consumer paths

### Author/compiler path

- `priv/boot/core.bl: lazy-seq` expands exclusively to `BeamLisp.LazySeq/from_fun (fn [] ...)`. No syntax or compiler lowering change required.
- Every `lazy-seq` in `priv/boot/core.bl` (concat/interleave/map/filter/repeatedly/take-while/partition/for and related implementations) therefore receives reclaimable memo ownership automatically.
- Fixture/library forms under `test/fixtures/jank/` likewise expand through the same macro. No fixture edits are needed for the cutover.
- `priv/boot/compiler.bl` and `compiler2.bl` can produce/consume ordinary language sequences but contain no direct LazySeq struct/ETS coupling. Compiler workloads benefit through core/RT without a compiler-specific mode.

### Runtime lazy operators

All of the following in `lib/beam_lisp/rt.ex` use `LazySeq.new`, `chain`, and/or `cell`, so no structural edits are required:

- producers: `lazy_map`, `lazy_multi_map`, `lazy_filter`, `range`, `iterate`, `repeat`, `cycle`, `concat`, `take_while`, `drop_while`;
- traversal/consumption: `first`, `rest`, `next`, `count`, `empty?`, `nth`, `drop_from`, `seq`, `reduce`, equality walking, `take_loop`, `doall`, `dorun`, and bounded printing;
- chunk helpers (`map_chunk`, `range_chunk`, `concat_chunk`, filter/take builders) retain the existing 32-element chunking and create tails through central constructors.

Shared consequences: completed values no longer live merely because a VM-global ETS row exists; captured predecessor handles and returned lazy tails become explicit graph dependencies; all user effects retain once-per-attempt/concurrent-sharing semantics.

### Vector/list/Stream/Enumerable paths

- `lib/beam_lisp/vector.ex` is an eager persistent value (tuple/trie). Its `Enumerable` implementation is not a memo cache. Vectors passed to `LazySeq.cell` or lazy RT operators automatically feed the central lazy nodes; vector internals require no ownership edit.
- Proper lists are eager values; improper `[head | %LazySeq{}]` chains in `RT`, `Sorted`, and `LazySeq` keep routing their tails through `cell/to_list` and benefit automatically.
- Elixir `Enum`/`Stream` interop goes through the existing `Enumerable` implementations. `LazySeq.Enumerable.reduce` forces with `cell`, hence central cutover applies. `Stream` pipelines themselves retain Elixir’s deliberately non-memoized pull semantics and must not be converted into LazyMemo cells.
- `Set`, `SortedSet`, maps, strings, and generic Enumerables normalized by `LazySeq.cell` are eager inputs; no cache migration applies.

## Other caches/registries: keep separate

### Deliberately permanent or lifecycle-scoped registries

- `lib/beam_lisp/env.ex`
  - `:beam_lisp_vars`: authoritative vars/namespaces/metadata/per-env definitions. Rows are deleted on env destruction where appropriate; global definitions are intended registry state.
  - `:beam_lisp_ops`: fixed/default and app-registered capability operation registry.
  - Per-env materialization is once-per-environment definition state with explicit generation/redefinition invalidation, not reachability-owned lazy computation. Do not migrate.

- `lib/beam_lisp/native.ex`
  - `:beam_lisp_native_declarations`: permanent replay registry required for AOT/module initialization. Keep Loader.Server ownership. It must survive declaring processes and is intentionally VM-global.

- `lib/beam_lisp/record.ex`
  - `:persistent_term` module→record schema registry. Definitions/modules are VM-global and rare; permanence is intentional.

- `lib/beam_lisp/meta.ex`
  - LazySeq metadata currently lives in the Env registry. This is identity metadata, not realization memo state. It must remain logically separate unless a future dedicated weak/resource-owned metadata design is approved. Avoid native ID reuse as noted above.

- `lib/beam_lisp/perf_probe.ex`
  - Explicit aggregate counters with manual `reset`; observability, not memoization.

- `lib/beam_lisp/test_rt.ex`, RT data-reader entries, trace/multi definitions
  - Registries with explicit env lifetime/redefinition/clear behavior; not reachability-owned computation.

- `lib/beam_lisp/sandbox.ex`, `lib/beam_lisp/tiers.ex`, `lib/beam_lisp/compiler_options.ex`, `lib/beam_lisp/generation.ex`, daemon UID/build state
  - Small VM/process configuration and warm-base registries in `persistent_term`; permanence or explicit reset is part of their contract.

### Content-addressed/build caches

- `lib/beam_lisp/aot_cache.ex`: disk content-addressed compiled artifacts + compiler-key memo and generation GC. Entries are intentionally shared across runs and evicted by build-cache policy, not term reachability.
- `lib/beam_lisp/aot.ex`: temporary process-dictionary source resolution cache exists only during closure hashing.
- Bootstrap seed under `priv/bootstrap/seed`: committed build input, not runtime memo state.

None should be routed through LazyMemo. Doing so would make authoritative registry/build state disappear when a handle becomes unreachable and would invert their semantics.

## Native availability and packaging audit

### Existing automatic integration

- `mix.exs` compiler order is `Mix.compilers() ++ [:beam_lisp_native, :beam_lisp]`: Elixir compiles first, native compiler then builds crates, then BeamLisp AOT. This is why `BeamLisp.LazyMemo` correctly avoids `@on_load` and loads explicitly at first construction.
- `lib/mix/tasks/compile.beam_lisp_native.ex` discovers every `native/*/Cargo.toml`, builds release cdylibs, asks Cargo metadata for target directory, and installs `priv/native/<crate>.so`.
- `native/lazy_memo/Cargo.toml` names `lazy_memo`, points to `src/lib.rs`, and sets `crate-type = ["cdylib"]`, matching install/load names.
- `BeamLisp.LazyMemo` loads `Path.join(BeamLisp.Tiers.priv_root(), "native/lazy_memo")`; Erlang appends `.so`, matching the compiler destination.
- Mix releases include the application `priv` directory, so a successfully installed `priv/native/lazy_memo.so` is available in a release.

### Required hardening

- `compile.beam_lisp_native` currently treats missing Cargo as success because existing native backends are optional. LazyMemo is mandatory and has no ETS fallback. Change behavior: if `priv/native/lazy_memo.so` is absent/unusable and Cargo is absent, fail compilation with the actionable requirement. Optional datom/wry crates may retain absence semantics.
- Ensure clean-source distribution includes `native/lazy_memo/Cargo.toml`, `src/lib.rs`, and `Cargo.lock` (once generated). Hex’s default file set may omit top-level `native/`; add explicit `package: [files: ...]` if Hex publishing is supported. A release built from a Git checkout is already covered by the native compiler + `priv` packaging.
- Freshness checks consider `src/**/*.rs` and `Cargo.toml`; add `Cargo.lock` (and crate-local `.cargo/config.toml` if introduced) so dependency/target configuration changes rebuild the installed NIF.
- Platform naming is hard-coded to `.so`; current target is Linux. If macOS/Windows support is claimed, derive installed library suffix using the same convention `load_nif` expects and update freshness/install tests. Do not claim cross-platform packaging until tested.
- NIF upgrade safety must be explicit: resource types from one loaded module version cannot be assumed compatible with another. Prefer no live upgrade of this module or reject old resources predictably.

## Cache key, seed, and release consequences

- **AOT compiler key:** `BeamLisp.LazySeq` and `LazyMemo` are not codegen modules in `AOTCache.@codegen_modules`. That is appropriate because emitted calls remain `BeamLisp.LazySeq/from_fun` and the public runtime ABI is unchanged. Existing AOT beams call the central module dynamically and receive new semantics without cache invalidation.
- **Seed:** `priv/boot/core.bl` author syntax/macro expansion is unchanged. Do not regenerate the committed bootstrap seed during iteration. A final seed regen is unnecessary solely for this runtime cutover unless another change modifies hashed boot/codegen input.
- **Release:** build the mandatory NIF before `mix release`; verify `_build/<env>/lib/beam_lisp/priv/native/lazy_memo.so` is present in the assembled release and that a released node can call `LazyMemo.stats/0` and force a LazySeq.
- **AOT cache artifacts:** they need not embed the NIF. The running application supplies the host modules and `priv/native` artifact; cached namespace beams retain stable public calls.

## Test impact beyond wave23

Preserve and run centrally after native integration (orchestrator responsibility):

- `test/beam_lisp/wave10_lazy_test.exs` — baseline author-level lazy behavior.
- `test/beam_lisp/wave26_laziness_test.exs` — chunking/laziness/effect boundaries.
- `test/beam_lisp/wave14_meta_test.exs` — fresh-node metadata and equality semantics; likely needs expected identity wording but not removal.
- `test/beam_lisp/sorted_test.exs` — improper LazySeq tail encoding.
- `test/support/beam_lisp_test.ex` users — equality realization remains public API based.
- compiler/default-budget regression: compile a representative default compiler/core workload at the unchanged 512 MiB admission setting; this proves the useful fix applies beyond a hand-picked compiler path without raising the cap.
- native crate focused tests: exact CAS, wrong-expected retry, direct/indirect cycle rejection without mutation, accounting saturation/invalid sizes, poisoned/untrusted paths without panic, destruction graph cleanup, and iterative reclamation.
- packaging tests: mandatory missing-artifact error, native compiler install path/freshness, and release smoke load.

## Cutover acceptance matrix

| Area | Automatic | Required explicit action |
|---|---:|---|
| Core `.bl` `lazy-seq` macro and all callers | yes | none |
| RT lazy operators/traversal/chunking | yes | preserve public APIs while replacing internals |
| Compiler-created lazy values | yes | no compiler-only mode; default-budget regression |
| Vector/list/Set/Enumerable inputs | yes | none |
| Loader.Server | no | remove only lazy monitor/table ownership |
| Lazy metadata | no | replace key field coupling; preserve fresh realization identity |
| Wave23 internals tests | no | observable/resource tests; remove ETS/owner-loss assumptions |
| Test async documentation/doctor | no | remove stale global LazySeq classification |
| Other registries/caches | not applicable | keep separate |
| Native compiler/release | partly | make lazy_memo mandatory, package sources/artifact, cover freshness |
| Bootstrap seed/AOT compiler key | runtime-compatible | no iteration seed regen; no key rotation solely for runtime semantics |

## Risks to resolve before merge

1. Metadata keyed by native integer ID is safe only if IDs are never reused in the VM; otherwise permanent metadata aliases future resources.
2. Mandatory NIF vs native compiler’s current optional-toolchain policy is a real deployment mismatch; compilation must fail before runtime when lazy_memo cannot exist.
3. Global `stats` make budget/GC tests order-sensitive unless assertions use deltas and eventual `pending_reclaims == 0` convergence.
4. Resource dependency tracing is intentionally limited to visible LazySeq handles and function environments; opaque foreign NIF resources remain outside the guarantee.
5. `with_meta` must not accidentally share the original memo resource, or metadata changes will cease to create independently forced nodes.
