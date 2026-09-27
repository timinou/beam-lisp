# Repository Elixir-source reachability audit

## Scope and result

This audit accompanies the ongoing zero-repository-Elixir migration. The source inventory after commit `74419f77` is **26 `lib/**/*.ex`**, **27 repository `.ex`** (the extra is `test/support/beam_lisp_test.ex`), and **114 repository `.exs`** visible outside ignored directories. These counts are not zero. Do not interpret a missing literal import as proof that a module is dead: users can load a namespace by name, and several production paths construct module atoms or use OTP callback/protocol dispatch.

The scan read 1,165 authored files under `lib/`, `priv/`, `test/`, `bin/`, `config/`, `native/`, `scripts/`, `examples/`, `bench/`, `tooling/`, and `editors/`, plus the two extensionless launch scripts and `env.bl`. It checked literal inbound module names, `Module.concat` and string-to-atom construction, application callback/child specs, compiler seed manifests, behaviours/protocols, and test entry points. `projects/**` was checked for the four candidate modules, with no matches; docs and external downstream repositories were not exhaustively scanned. This is a conservative static reachability audit, **not** a whole-program proof of unreachability.

## Production/boot-reachable: retain until behaviour is ported

| File | Observed root or inbound edge |
| --- | --- |
| `lib/beam_lisp.ex` | `BeamLisp.Application` calls `BeamLisp.init/0`; public eval/run/repl API. |
| `lib/beam_lisp/bootstrap.ex` | `bin/bl` installs the pinned host and compiler seed before application startup; manifest SHA authority. |
| `lib/beam_lisp/aot.ex` | Compiler tier, `bin/bl` provenance verdict, BL build/runtime compilation. |
| `lib/beam_lisp/aot_cache.ex` | `bin/bl` compiler key and BL build-tier cache. |
| `lib/beam_lisp/loader.ex` | Namespace loading through boot, CLI, and runtime. |
| `lib/beam_lisp/env.ex` | OTP application child and namespace/var registry. |
| `lib/beam_lisp/loader_server.ex` | OTP application child; process owner of globally loaded library state. |
| `lib/beam_lisp/lazy_memo.ex` | Native lazy-memo resource loader; used by `LazySeq` and pinned `SeqCursor`/`Reactive`. |
| `lib/beam_lisp/guards.ex` | Compile-time guard macros imported by remaining `multi.ex` and `record.ex`, plus runtime tuple-tag inventory. |
| `lib/beam_lisp/multi.ex` | Multimethod/protocol engine called from boot runtime. |
| `lib/beam_lisp/record.ex` | `defrecord`/`deftype` runtime, dynamic `BeamLisp.Record.*` module construction. |
| `lib/beam_lisp/vector.ex` | Persistent vector and Enumerable implementation, boot/runtime/host callers. |
| `lib/beam_lisp/lazy_seq.ex` | Native-backed lazy seq and Enumerable implementation. |
| `lib/beam_lisp/refs.ex` | Atom/Volatile/Promise/Future/Reduced struct types and deref; compile-time matches against pinned host structs. |
| `lib/beam_lisp/decimal.ex` | Exact decimal runtime and protocol; called from boot and numeric host. |
| `lib/beam_lisp/sorted.ex` | Sorted map/set structs and ordered collection operations; runtime constructs their exact module atoms. |
| `lib/beam_lisp/server.ex` | Dynamic `BeamLisp.Server.*` gen-server module construction from `defserver`. |
| `lib/beam_lisp/reload_watcher.ex` | Dev CLI starts `ReloadWatcher.start_link`; not an unused dev file. |
| `lib/beam_lisp/z3_port.ex` | Z3 port driver from `priv/lib/z3.bl` and `priv/std/z3pool.bl`. |
| `lib/beam_lisp/supervisor.ex` | Supervisor-as-data APIs called from boot/runtime. |
| `lib/beam_lisp/test_rt.ex` | Active BL `deftest`/`bl test` registry and runner, not merely ExUnit support. |
| `lib/beam_lisp/trace.ex` | `priv/boot/rt.bl` trace/untrace dispatch. |

All 22 rows have observed production or boot inbound edges. They are migration targets, not deletion candidates.

## Restricted-use candidates: no deletion without preserving the contract

| File | Finding | Required cutover |
| --- | --- | --- |
| `lib/beam_lisp/dev_change.ex` | Only static caller is `priv/std/dev/change.bl`; that namespace has no in-repo static loader, CLI verb, or project reference. It is nevertheless publicly loadable by name and has `test/beam_lisp/dev_change_test.exs`. **Likely unused by in-repo production entry points, not proved globally unused.** | Decide whether the public `dev.change` feature is retained. If retained, port both implementation and tests. If removed, remove wrapper and tests in the same reviewed change; prove cold boot/build and downstream API decision. |
| `lib/beam_lisp/anf_interpreter.ex` | Only caller `priv/self/anf.bl`, loaded by `test/bl/anf_test.bl` and `test/bl/system/tier_test.bl`. **Test-only, but its reference interpreter is live coverage.** | Port the stacktrace-preserving interpreter or replace its oracle with equivalent tests before deleting it. Never discard the ANF oracle merely to lower the source count. |
| `lib/beam_lisp/sandbox.ex` | Public test-harness API used by `BeamLisp.ExUnitCase` and `test/beam_lisp/sandbox_test.exs`; no in-repo production caller. | Port the downstream-facing test API and migrate its tests first; downstream usage outside this repository remains unverified. |
| `lib/beam_lisp/ex_unit_case.ex` | `use BeamLisp.ExUnitCase` macro consumed by the sandbox suite; documented public test API, not a runtime root. | Coordinate with `sandbox.ex` and the ExUnit-to-BL test cutover. |

## Dynamic edges that defeat import-only scans

- `env.bl` declares `BeamLisp.Application` as OTP `:mod`; application startup then starts `BeamLisp.Env` and `BeamLisp.Loader.Server` and calls `BeamLisp.init/0`.
- `bin/bl` stages manifest-listed pinned beams **before** `elixirc`, installs verified hosts before its tier verdict, then starts the application. The seed manifest lists exact host module names; searching `.ex` imports misses them.
- `AOT` constructs `BeamLisp.Ns.Init.*`/`Body.*`; `Record` and `Server` construct runtime module atoms. `priv/lib/web.bl` and other BL sources also intern exact Elixir module atoms.
- `defimpl`, `defprotocol`, compile-time guard macros, and OTP callback names are dependency edges even without a function-call reference.
- A cold checkout is the decisive verification gate; a warm VM can retain deleted Elixir beams or namespace vars and conceal missing pinned-host dependencies.

## Verification and limits

The migration waves committed through `74419f77` passed targeted `bin/bl build --force`, `bin/bl seed --check`, focused BL suites, and scratch-tree cold `bin/bl eval '(+ 1 2)'` runs. Builds/tests were run under `systemd-run --user --scope` memory/swap caps (typically `MemoryMax=5G`–`10G`, `MemorySwapMax=3G`–`6G`). The full repository test suite, all remaining `.exs` migrations, release-image inventory, and a final zero-source proof **have not run**. An early 12G/2G scope was OOM-killed while a faulty pinned Set recursively read its own backing field; that bug was fixed, regression-tested, reseeded, and committed.
