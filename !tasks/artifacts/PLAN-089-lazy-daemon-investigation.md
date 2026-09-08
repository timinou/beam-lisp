# PLAN-089 Fix 2/3 — lazy AOT and daemon boot reload investigation

Scope: read-only investigation. No Fix 2/3 implementation and no builds were run.

**Post-review correction:** Fix 1's interface-only prelude key has been withdrawn. Ordinary core functions execute transitively inside macros and the compiler (for example, `case` calls `case-pairs`). Their bodies cannot safely be excluded without compile-time dependency tracking. The final implementation retains raw boot-source keys. Any body-only fast-path proposal below is conditional on that missing dependency proof, not a current capability.

## Executive conclusion

Fix 2 as stated in the plan is **not sound if it merely skips `build/run`**. After a boot-source edit, `Bootstrap.install!/1` may stage the previous-generation seed while `AOTCache.compiler_key/0` already describes current files. A demand compile could therefore execute the old compiler and stamp/cache its output with the new key. Lazy mode needs a bootstrap-generation barrier before any ordinary namespace may compile.

Fix 3 should not generalize the current `DevHotpatch` module-loading loop unchanged. That loop purges and reloads every emitted module, including `Ns.Body.*` and `Ns.Init.*`, although AOT and linking explicitly rely on body/init modules being never reloaded so in-flight functions and macro closures cannot be stranded. The daemon needs a boot-specific reload coordinator with explicit epochs, serialized prepare/commit, fresh immutable body/init module identities, and restart fallback.

Recommended shape:

1. Lazy Mix mode performs planning/freshness bookkeeping but defers ordinary stale namespaces.
2. If toolchain drift exists, first establish a current, internally consistent boot compiler generation; no ordinary output may be stamped or cached before this barrier.
3. The daemon owns an always-on boot-source watcher independent of client `bl watch` subscriptions.
4. Boot updates are debounced, classified, prepared against one source snapshot, and committed through `Daemon.Executor`.
5. Stable namespace shims may be hot-loaded; old body/init code is never purged. Unsafe changes or failed preparation mark the daemon restart-required before accepting more commands.

---

## Verified source facts

Everything in this section was observed in repository source. Comments are reported as contracts where noted; no runtime/build verification was performed.

### 1. Mix → bootstrap → AOT build path

`lib/mix/tasks/compile.beam_lisp.ex`:

- `Mix.Tasks.Compile.BeamLisp.run/1` has only `--source-dir`, `--out`, `--force`, and `--jobs`; there is no lazy option.
- It always discovers every configured `.bl`, `.bl.md`, and `.bl.org` source before entering the runtime.
- `in_runtime/1` calls `BeamLisp.Bootstrap.install!(Mix.Project.compile_path())`, then `BeamLisp.AOT.boot()`, then invokes the build, and stops `Env`/`Loader.Server` only if it started them.
- `build_call/2` first calls `Loader.ensure_loaded("build")`, then invokes a var in the registry. Thus `build` may come from AOT or source.

`priv/boot/build.bl`:

- `build/run` reads and plans **all** supplied sources, computes one `tkey = AOTCache/compiler_key`, and considers a source fresh only when manifest `:hash` and `:key` match and all recorded beam files exist (`fresh?`).
- A toolchain-key change makes every manifest entry stale.
- Stale paths are compiled/fetched in dependency waves. A wave uses `pmap-ordered`; source workers run concurrently and results are folded in plan order.
- Cache keys are `<compiler-key>/<closure-key>`. Cache participation is disabled only by force or cache configuration, not by namespace demand.
- Manifest entries are written after each successful source. Deleted sources have their recorded beam files removed.

### 2. Seed versus source is an explicit bootstrap generation boundary

`lib/beam_lisp/bootstrap.ex`:

- `Bootstrap.install!/1` integrity-checks every committed seed beam against `priv/bootstrap/seed/manifest.exs`.
- It computes `AOTCache.compiler_key/0` before boot and installs seed modules on both key match and mismatch, unless a destination namespace generation is already stamped with the current key.
- A key mismatch is treated as previous-generation staging: the installed seed can intern and run, and `:bootstrap_staging` records only seed namespace shims (`compiler`, `reader-node`, etc.; body/init companions are excluded).
- It purges and `load_binary`s every installed seed module into the current VM.
- The stated ladder is gen-N seed → rebuild gen-N+1. `:bootstrap_staging` causes the AOT drift gate to trust those staged namespaces despite key mismatch.
- A later matching install clears staging. The current process does not clear staging merely because one namespace was demand-compiled.

Consequence: a mismatched seed is valid **as a compiler input generation**, but it is not evidence that current boot source is live.

### 3. AOT-first loading already supports per-namespace source fallback, with limits

`lib/beam_lisp/loader.ex` and `lib/beam_lisp/aot.ex`:

- `Loader.ensure_loaded/1` is the single AOT-first require path. It calls `AOT.ensure_loaded/1`; `:no_module` falls through to `ensure_loaded_source/1`.
- All library loading is pinned through `Loader.Server`; ambient dirs are captured from the caller. A process-local `:bl_loading` set cuts require cycles.
- Source loading is additionally protected by `:global.trans` keyed by resolved path, evaluates into `:global`, and marks loaded only after successful evaluation.
- `AOT.ensure_loaded/1` returns early when `Env.loaded_ns?/1` is true. An already-interned namespace is not re-hashed on every access.
- For an unloaded AOT namespace, `stale?/2` checks provenance. Boot namespaces use only toolchain-key comparison; non-boot namespaces use source-closure hash plus toolchain key.
- In dev, stale returns `:no_module`; strict mode raises. Missing source in packaged deployment causes trust, not fallback.
- Boot namespaces listed in `:bootstrap_staging` bypass drift rejection.

Therefore the existing fallback is useful for lazy ordinary namespaces, but it does **not** itself update an already-loaded staged compiler, and it deliberately trusts staged seed namespaces.

### 4. Memoized keys and source caches

`lib/beam_lisp/aot_cache.ex`:

- `compiler_key/0` memoizes in `:persistent_term` for VM lifetime.
- `current_compiler_key/0` recomputes from live files and loaded host code without using the memo.
- `reset_compiler_key/0` exists only as a test-facing escape hatch according to its comment.
- The key includes Beam Lisp/Elixir/OTP versions, AOT backend, loaded host-code object bytes, raw boot/toolchain sources, including `core`/`sugar` (the unsafe interface-only experiment was removed after review).
- Cache fetch links/copies beams but does not validate provenance itself; correctness depends on keys and complete manifests.
- Cache store publishes by temp-directory rename. Current source also invokes bounded old-generation cleanup after stores.

`lib/beam_lisp/tiers.ex`:

- `boot_namespaces/0` is independently memoized in `:persistent_term`. A daemon introducing/removing a boot file would not see membership change without invalidation/restart.

`lib/beam_lisp/aot.ex`:

- `ns_closure_hash/2` creates a process-local source cache for one computation and deletes it in `after`; it intentionally does not persist across calls. This cache does not need daemon invalidation.

### 5. Provenance can lie if active compiler generation and key diverge

`AOT.emit_module/5` stamps every namespace shim with `{source_hash, AOTCache.compiler_key()}`. The stamp records the memoized desired toolchain key; it does not independently identify which loaded compiler generation produced the bytes.

Combined verified facts:

- bootstrap can run a mismatched previous seed;
- `compiler_key/0` can already be the live-current source key;
- emit stamps that key;
- cache store namespaces output by that key.

Thus a lazy implementation that skips boot rebuild and demand-compiles an ordinary namespace can label old-generator output as current-generator output. This is a source-derived unsoundness, not a measured failure in this investigation.

### 6. Macros are compile-time state and have stricter lifetime rules

`lib/beam_lisp/aot.ex`:

- Required namespaces are loaded before compilation so their macros are interned before dependents compile.
- `capture_value_def` replays `defmacro` and also macro-expands defining macros to capture produced definitions.
- A dependent's provenance uses the transitive require closure specifically because a required macro body can alter dependent bytes.
- AOT macro/value initializers live in stable `BeamLisp.Ns.Init.<Ns>` companion modules. Comments explicitly state these must never be reloaded: macro closures anchored there would fail after BEAM version churn.

`lib/beam_lisp/link.ex` and `lib/beam_lisp/emit.ex`:

- Runtime definitions compile real code into fresh immutable body modules. The stable namespace module contains only forwarding shims and is regenerated.
- Old body modules are intentionally never reloaded/purged, allowing captured closures and in-flight calls to finish safely.

A boot macro edit is therefore not equivalent to swapping a plain runtime function. It must update the macro var before any dependent is compiled, and old macro closure code must remain valid.

### 7. Current hotpatch behavior conflicts with immutable-module contracts

`lib/beam_lisp/dev_hotpatch.ex`:

- `hotpatch_ns!` compiles one requested `priv/boot/<name>.bl` into a temp directory using `AOT.compile_file/2` in the live VM.
- Compilation itself re-interns vars as a side effect.
- It then loops over **all** emitted beam files and calls `:code.purge`, `:code.delete`, and `:code.load_binary` for each.
- There is no dependency expansion, source snapshot, rollback, daemon drift-state update, compiler-key reset, or concurrency control in this module.

Because emitted files include namespace shim, deterministic `Ns.Body.<Ns>`, and possibly `Ns.Init.<Ns>`, this loop reloads modules which AOT/Link comments say are never to be reloaded. It is a useful manual iteration aid, not a safe daemon transaction primitive.

### 8. Daemon ownership and serialization

`lib/beam_lisp/daemon/server.ex`:

- `Server.init/1` boots once, then starts one named `Daemon.Executor` and one `WatchRegistry`.
- State captures `compiler_key` at startup.
- Each acceptor context has `drift_fun` comparing frozen startup key with `AOTCache.current_compiler_key/0`.
- The comment and protocol behavior require restart on mismatch; `test/beam_lisp/daemon_integration_test.exs` verifies a bogus startup key yields `:restart_required` at hello.
- The frozen key is captured into the acceptor context. There is no API to advance it after a reload.

`lib/beam_lisp/daemon/executor.ex`:

- All commands and `run_reload/2` callbacks are serialized in one GenServer mailbox.
- A command executes synchronously inside the Executor process, with per-request isolated Env layered over `:global` and caller-specific ambient roots.
- Reload callbacks therefore cannot overlap a command once submitted to the FIFO.
- `queue_depth` currently reports `state.active`, but `active` is initialized to zero and never changed; tests only assert zero while idle. It is not usable as precise backpressure/observability today.

### 9. Existing watcher/reload is application namespace reload, not boot-toolchain reload

`lib/beam_lisp/daemon/watch_registry.ex` and `lib/beam_lisp/reload_watcher.ex`:

- Watchers exist only after a `bl watch DIR` subscriber registers. There is no always-on watcher for `priv/boot`.
- One watcher is deduplicated per canonical requested directory.
- File events for `.bl`, `.bl.md`, `.bl.org` synchronously call an injected apply function. Under daemon ownership, that function submits `ReloadWatcher.apply_change/3` to the Executor FIFO.
- `ReloadWatcher.apply_change/3` evaluates `(reload/stage ...)`, then `(reload/commit)`.

`priv/std/reload.bl`:

- Reload statically checks dangling references, promises, removals, and type warnings before evaluation.
- A coherent bundle is evaluated into the commit target (normally `:global`), with namespaces declared first and vars removed afterward.
- It describes per-var swap semantics: stable shim changes, old immutable body module remains available.
- It is not a fully atomic BEAM transaction: `apply-bundle!` evaluates namespaces sequentially after static validation; an unexpected evaluation failure can occur after earlier mutations. No rollback is implemented.
- It does not update daemon compiler epoch/key state, compiler-key persistent terms, boot-tier membership, or AOT cache policy.

### 10. Existing tests cover components but not Fix 2/3 safety

Observed tests:

- `daemon_integration_test.exs`: startup/probe and restart-required drift rejection.
- `daemon_watcher_test.exs`: reload callback FIFO serialization, subscriber notification, watcher dedup.
- `daemon_executor_test.exs`: sequential command survival and client path isolation.
- `reload_watcher_test.exs`: real filesystem event reaches application reload and changes a function.
- `aot_drift_test.exs`: ordinary stale AOT source fallback and strict refusal.
- `aot_build_key_test.exs`: toolchain-key mismatch makes eager build rebuild.
- `aot_reproducible_test.exs`: repository gate for deterministic output (not run here).

No observed test proves lazy compile after mismatched seed, cache non-poisoning, daemon boot hot-swap, macro reload across repeated epochs, commands queued during boot reload, or old-code survival during repeated hotpatch.

---

## Proposed Fix 2 — sound lazy compilation

This section is design proposal, not verified current behavior.

### Contract

Lazy mode means: avoid eagerly rebuilding stale **ordinary** namespaces, while preserving this invariant:

> Every beam stamped/cache-keyed as toolchain generation K was produced by a compiler runtime proven to represent generation K.

Eager mode remains default and remains CI/commit/release gate.

### Do not implement lazy as an early return

The Mix task still needs to:

1. install/verify bootstrap;
2. boot Env and Loader.Server;
3. discover and plan sources;
4. read the existing manifest;
5. establish the active compiler generation;
6. preserve enough manifest/source-root metadata for runtime demand compilation;
7. clean entries for removed sources only under an explicit, safe policy.

Skipping all build work would leave no demand-build index, leave stale manifest entries apparently authoritative to tooling, and permit false provenance.

### Add an explicit generation model

Introduce a runtime-owned structure (one GenServer or immutable epoch record), conceptually:

```text
%ToolchainEpoch{
  desired_key: current files/host-code key,
  active_key: generation actually loaded and allowed to emit,
  source_snapshot: boot path => digest,
  state: :current | :staged_seed | :preparing | :restart_required,
  generation: monotonic integer
}
```

Rules:

- `desired_key` may use the current `compute_compiler_key` logic.
- `active_key` must derive from installed seed provenance / completed bootstrap transaction, not be assumed equal to desired key.
- AOT emission and cache store must accept an explicit proven key/token from the epoch, rather than reading global `compiler_key/0` at the final write.
- No ordinary demand compile while state is `:staged_seed` or `:preparing`.
- Never globally reset the compiler-key persistent term while old work may still compile. Replace ambient memo reads in build/emission with an epoch-scoped immutable key passed through the operation.

This separates three currently conflated facts: source key, seed generation, and active compiler generation.

### Bootstrap barrier

On lazy startup:

1. `Bootstrap.install!` reports whether it installed a matching seed, staged previous seed, or retained current destination beams. Expand this result to include seed manifest key and installed namespace generation evidence.
2. If active == desired, ordinary demand loading may proceed.
3. If staged seed != desired, build/hot-load the **minimal closed boot compiler set required to produce ordinary code**, in declared dependency/topological order, before serving any ordinary compile.
4. Verify the prepared generation as a unit. At minimum: every required boot namespace shim has intended provenance, all expected body/init modules are present, compiler/reader/lower entry exports exist, and a smoke compile executes using the prepared generation.
5. Only then publish active_key = desired and permit ordinary demand compilation.

Conservative first version: rebuild the complete genuine codegen boot partition at the barrier. This is still materially better than rebuilding 142 ordinary namespaces and avoids inventing an incomplete dependency model. Fine-grain the boot compiler closure later only after explicit boot dependency metadata exists.

### Demand compilation registry

Add one serialized demand compiler service rather than letting arbitrary Loader callers compile stale source directly:

- key: canonical source path + desired toolchain epoch + source closure key + output root;
- states: absent/preparing/ready/failed;
- concurrent requests for the same key join one operation;
- different namespaces may initially serialize for safety; parallelism can be added only by using the existing build-plan waves under one epoch snapshot;
- resolution uses caller ambient roots captured before hopping into the service;
- before commit, re-read source/closure digests. If changed during preparation, discard and retry; never publish bytes from a mixed snapshot;
- cache writes occur only after epoch and closure revalidation;
- manifest update and beam publication use atomic temp-write/rename and one owner.

`Loader.ensure_loaded_source/1` is already VM-wide serialized for source eval, but lazy AOT needs more: output publication, provenance, cache, manifest, source snapshots, and epoch validation.

### Manifest semantics

Two viable representations:

A. Keep stale entries but add manifest header `{desired_key, active_key, lazy_pending}`. Runtime cannot mistake stale entries for current because beam provenance remains authoritative.

B. Write a separate lazy-index manifest and leave eager manifest untouched until demand compile succeeds.

Prefer B initially: it avoids teaching existing eager/clean code that an entry can be intentionally pending. Each successful demand compile atomically moves only its source entry into the ordinary manifest.

Do not delete old beam files at lazy planning time. They remain useful fallback artifacts but must fail provenance against the new epoch. Replace them only when the corresponding demand compile commits.

### Macro handling

- A required namespace must be current before compiling its dependent. The demand service follows the build-plan require DAG, not merely runtime `Env.loaded_ns?`.
- Macro-containing required namespaces invalidate dependent closure keys as today.
- Reloading a macro namespace must replace the registry value before dependents compile, but retain the module containing any old macro closure.
- Never load a new implementation into the same `Ns.Init.<Ns>` identity. Use epoch-qualified/fresh immutable init module identities and make the stable shim/init dispatcher point to the new one, or source-evaluate into fresh throwaway modules.
- Defining macros that expand to defs need the same capture/replay path as eager AOT; do not use textual definition-name heuristics as a substitute.

### Lazy mode activation and boundaries

- Support `--lazy` and optionally `BL_LAZY_AOT=1`; CLI flag wins.
- Reject/ignore lazy in prod/release and CI policy; explicit dev-only contract.
- `--force --lazy` should be invalid rather than ambiguous.
- Lazy only helps a process that will execute after the Mix compiler. If Mix terminates before runtime use, document that no deferred work occurs.
- A standard `mix test path` still invokes Mix compilation before tests; the compiler task must return success after the bootstrap barrier and let test runtime demand-load only exercised namespaces.
- `BEAM_LISP_AOT_STRICT=1` should disable source fallback/lazy demand and require eager current beams.

### Fix 2 failure behavior

- Bootstrap barrier failure: return Mix compiler error; never continue with falsely keyed output.
- Ordinary demand failure: preserve old beam and manifest entry, return the compile error, do not cache.
- Epoch/source drift during compile: discard temp output and retry bounded times; then fail with a drift diagnostic.
- Missing source: existing packaged-beam trust remains only outside lazy dev mode; lazy mode should report the unresolved namespace.

---

## Proposed Fix 3 — safe daemon boot reload

### Separate boot watcher from application watch subscriptions

Server should start one daemon-owned `BootWatcher` for the canonical Beam Lisp checkout when boot-source files are present. It must not depend on a `bl watch` client or stop when subscribers disconnect. Application `WatchRegistry` remains for client trees.

Watch at least:

- genuine `priv/boot/**/*.bl` inputs;
- `priv/self/**/*.bl` when the Core backend includes them in the key;
- host codegen module beam/source changes cannot safely be in-place patched by this mechanism and should mark restart-required;
- prelude interface extractor changes should mark restart-required.

Events are hints only. Debounce/coalesce them, then compute content digests/current desired key. Never infer state from event count or mtime.

### Classify drift

Proposed classes:

1. **Prelude body-only (`core`, `sugar`)**: currently a toolchain-key change, because ordinary functions can execute at compile time. Treat it as a genuine codegen edit unless future compile-time dependency tracking proves a narrower invalidation set.
2. **Prelude interface change**: compiled callers may change name/arity/macro resolution. Conservative action: restart-required or run a complete compiler barrier plus invalidate/rebuild affected ordinary code. Do not claim one-namespace swap is enough.
3. **Genuine codegen boot edit** (`compiler*`, `lower`, `anf`, `reader*`, build planners, etc.): prepare and atomically advance a complete active compiler epoch. Expand to its boot dependency/reverse-dependency closure, not only the saved filename.
4. **Reader registry/data-reader change**: restart-required initially unless the design explicitly snapshots and replaces reader-macro/tagged-literal registries and proves no in-flight reader uses mixed tables.
5. **Boot file add/remove/rename**: restart-required initially because `Tiers.boot_namespaces/0` is memoized and namespace removals/module retirement need explicit semantics.
6. **Host Elixir codegen drift**: restart-required; the running module bytes are old even though file source changed, and recompiling Mix code inside daemon is a different system.

A conservative classifier still delivers the principal win for repeat body edits while protecting ambiguous edges.

### Prepare then commit

Use two phases, both governed by one source snapshot/epoch:

- **Prepare**: read all relevant source bytes once, compute desired key and closure, compile into a private temp output using the active proven compiler generation. Preparation must not mutate global Env/module state. Since current `AOT.compile_file/2` does mutate Env and creates modules, it is not a valid off-FIFO/background staging primitive.
- Initial safe implementation: run preparation itself on Executor FIFO. Better later implementation: isolated helper BEAM node/process with no shared module table, returning beam bytes + metadata. A mere `Env.isolated` process is insufficient because BEAM modules are VM-global.
- **Commit**: enqueue one `Executor.run_reload` job. Revalidate file digests and base epoch. If changed, discard and restart preparation. Load/repoint the complete prepared set, update Env vars/links/ns_defs/reader state, then advance daemon epoch and accept commands.

The acceptor must read epoch state dynamically. Today it closes over startup `state.compiler_key`; replace that closure with a call to the epoch owner. During `:preparing`, either queue authenticated requests behind the Executor or reject with a retryable `:reload_in_progress`. During `:restart_required`, reject all new work.

### Transaction limits and failure policy

BEAM module loading plus Env mutations cannot be rolled back reliably after arbitrary partial failure. Therefore:

- validate every beam binary/module name/export/provenance before first mutation;
- preload only fresh immutable implementation modules first (no externally visible dispatch yet);
- switch stable shims/registry dispatch last, inside FIFO;
- advance epoch only after all switches succeed;
- if any failure occurs after first visible mutation, mark daemon `:restart_required` and stop accepting commands. Do not attempt optimistic reverse swaps or continue in a mixed image;
- if failure occurs before visible mutation, discard staging and keep old epoch serving.

“Old code keeps serving” is valid only for pre-commit failure. It must not be promised for a failed multi-module commit without real rollback.

### Safe module lifetime / purge policy

Module categories need explicit policy:

- `BeamLisp.Ns.<Ns>` stable shim: may be hot-loaded under Executor serialization. Prefer soft-purge-aware loading; never blindly purge code still executing. BEAM supports old/current versions, so load new shim and let old callers finish. If a third-version load would require purging still-referenced old code, postpone/retry or restart daemon.
- runtime `Ns.Fn.M<n>` or epoch-qualified body modules: immutable. Load once, never reload, purge, or delete during daemon lifetime.
- AOT deterministic `Ns.Body.<Ns>`: cannot be reused for repeated daemon epochs under the current lifetime contract. Hotpatch output must instead use epoch-qualified/fresh body identities and point the shim at them.
- `Ns.Init.<Ns>` macro/value companion: same rule; fresh identity per epoch, never reload. Old macro closures retain their defining code.
- Removed implementations may be reclaimed only when `:code.soft_purge/1` proves no process references them and no Env/closure registry retains them. Default is retain until daemon restart.

This intentionally trades bounded daemon memory growth for correctness. Add observability and a restart threshold (epochs/module count/memory), not unsafe eager purge.

### Concurrency and ordering

- Filesystem events may arrive while a command runs; digest/debounce may happen outside the FIFO only if read-only.
- Any operation that compiles in this VM, interns vars, creates/loads modules, changes reader registries, or advances epoch must run in Executor FIFO.
- Multiple boot saves coalesce to the newest complete snapshot. A queued reload based on epoch N uses compare-and-swap semantics; if active epoch is no longer N, discard/replan.
- A command accepted before the reload job may finish on old epoch. A command behind the reload sees new epoch. No command may overlap commit.
- Loader.Server remains the namespace-load serialization point inside command/reload execution. Avoid acquiring independent global load locks outside its pinned process in an order that can invert.
- Existing `run_reload` is sufficient as ordering primitive, but `queue_depth` must be fixed before using it as status/backpressure.

### Boot source drift and daemon protocol

Replace boolean drift with states in ready/reject metadata:

```text
:current          key K, generation g
:reload_pending   serving K, target K2
:reloading        no concurrent command commit
:restart_required reason, old K, desired K2
```

After a successful hot reload, the daemon advertises the new active key and updates metadata on disk atomically. A client should never compare against a stale startup key captured by an acceptor closure.

If a save changes again during reload, do not briefly advertise intermediate desired key. Active key changes only on successful commit.

---

## Proposed acceptance tests

All tests below are proposals; none was run.

### Fix 2 unit/integration tests

1. **Lazy option contract** — parsing supports `--lazy`; `--force --lazy` errors; eager default unchanged.
2. **No eager ordinary rebuild** — forge every ordinary manifest entry stale by toolchain key, invoke lazy task, assert bootstrap barrier runs but untouched ordinary beam bytes/mtimes and manifest entries remain unchanged.
3. **Demand closure only** — run a test requiring A→B while unrelated C exists; assert only A/B publish current-key beams and C remains stale.
4. **Concurrent same-namespace demand** — two callers require one stale namespace; assert one compile/cache store/manifest commit and both observe result.
5. **Different client roots** — same ns name in two ambient roots does not alias registry key; canonical path/output root are part of demand identity.
6. **Source changes during compile** — controlled barrier edits a dependency between prepare and commit; first output discarded, retry stamps final closure only.
7. **Mismatched seed barrier** — stage seed key N, current boot key N+1, demand ordinary namespace. Assert no ordinary compiler invocation occurs until active epoch N+1; emitted provenance is N+1.
8. **No false-key cache entry** — force bootstrap barrier failure after old seed is live; assert no `<N+1>/<closure>` cache entry or current-key manifest entry appears.
9. **Matching seed fast path** — matching seed permits demand compile without boot rebuild.
10. **Macro dependency** — change required macro body, lazy-require dependent, assert macro namespace current first and dependent bytes/result reflect new expansion.
11. **Repeated macro epochs** — keep a closure/macro value from epoch 1, reload through at least three epochs, assert old closure still callable and new compiles use latest macro.
12. **Strict mode** — lazy + `BEAM_LISP_AOT_STRICT=1` refuses stale source fallback with actionable eager-build instruction.
13. **Deleted source** — lazy planning does not prematurely remove live old modules; demand of removed ns fails clearly; eager clean remains authoritative.
14. **Reproducibility** — demand-built beam bytes equal eager-built bytes for the same proven epoch (extend `aot_reproducible_test.exs`).
15. **Seed gate unchanged** — committed seed regeneration/fixpoint gate still required and passes after lazy development.

### Fix 3 tests

1. **Always-on boot watcher** — daemon with no `bl watch` subscriber observes a boot save and enters pending/reload/restart state.
2. **Body edit hot swap** — edit a safe compiler/core body, await epoch barrier, next daemon command observes new behavior without PID change.
3. **Interface edit fallback** — add/rename/re-arity prelude definition; daemon rejects new work as restart-required (until broader rebuild support exists).
4. **Reader/data-reader fallback** — registry-affecting save takes conservative restart-required path.
5. **Add/remove boot file fallback** — verifies memoized boot membership cannot remain silently stale.
6. **FIFO ordering** — block command A, save boot source, queue command B. Assert A completes old epoch, reload commits, B executes new epoch; no interleaving.
7. **Coalesced saves** — save v2 then v3 during prepare; only v3 publishes, active key never advertises v2.
8. **Source snapshot CAS** — mutate one boot dependency after preparation; commit rejects stale base and replans.
9. **Preparation failure** — syntax/macro error before visible commit leaves old epoch serving and reports held/error state.
10. **Partial commit failure** — injected load failure after first visible switch marks restart-required; no subsequent command executes in mixed image.
11. **Old in-flight call** — long-running old body crosses reload; it completes old result while a later call gets new result.
12. **Three-plus reloads** — retained function capture from epoch 1 survives epochs 2–4; catches two-version purge bugs.
13. **Macro companion lifetime** — macro closure from first init remains callable after three reloads; newest dependent compile expands with latest companion.
14. **No immutable purge** — instrument `:code.purge/delete`; assert no body/init implementation module is purged during normal reload.
15. **Shim soft-purge pressure** — hold old shim execution across repeated commits; coordinator postpones/restarts rather than hard-purging live code.
16. **Daemon metadata update** — successful reload updates ready/status/meta active key and generation; reconnect is accepted, not rejected against startup key.
17. **Host-code drift** — changing/reloading a host codegen module takes restart path, not boot-source hotpatch.
18. **Watch/client isolation** — application `bl watch` subscriptions still dedupe/unsubscribe independently of permanent boot watcher.
19. **Resource bound** — repeated epochs expose retained module count; threshold triggers graceful restart recommendation/action without purging live code.
20. **Eager equivalence** — after daemon iteration, eager build + reproducibility + seed fixpoint gates produce canonical bytes.

### Test hygiene

- Use explicit barriers/messages around prepare and commit; no sleep-and-hope except unavoidable filesystem backend warmup already isolated by watcher helpers.
- Use temp cache/output/source roots and restore environment variables.
- Tests mutating boot files must copy them to an isolated synthetic boot root or inject source providers; never edit repository boot source in place during parallel tests.
- Mark module-lifetime tests `async: false`; module namespace identities must be unique per test.

---

## Suggested implementation sequence

Proposal only:

1. Introduce `ToolchainEpoch` and make provenance/cache writes consume an explicit proven epoch token.
2. Add bootstrap result/evidence and the lazy bootstrap barrier.
3. Add serialized demand compiler + lazy manifest/index; land Fix 2 tests.
4. Refactor hotpatch emission to fresh immutable body/init identities; eliminate hard purge of implementation modules.
5. Add daemon-owned boot watcher, classifier, debounce/snapshot, and dynamic epoch protocol state.
6. Add prepare/commit failure state machine and restart fallback; land Fix 3 concurrency/lifetime tests.
7. Only after correctness gates: optimize boot closure granularity or off-FIFO helper-node preparation.

## Non-goals / cautions

- Do not use `AOTCache.reset_compiler_key/0` as the production reload protocol. Erasing one memo does not prove loaded code changed atomically and permits concurrent operations to observe different keys.
- Do not use `Env.loaded_ns?` as proof a namespace matches current source; it is explicitly a no-rehash fast path.
- Do not reuse `DevHotpatch.hotpatch_ns!` unchanged in the daemon.
- Do not promise rollback from the existing reload bundle; static coherence prevents known semantic errors but evaluation/module loading remains effectful.
- Do not purge immutable body/init modules merely to control memory. Restart the dev daemon at a bounded threshold instead.
- Do not allow cache publication before active-generation proof. Cache poisoning would outlive the daemon and make later eager builds appear valid.
