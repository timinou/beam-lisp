# Repository Elixir-source reachability audit — 2026-09-28 checkpoint

## Current inventory

At commit `eebd4c9c`, the non-ignored repository contains **5 `.ex`** files and **113 `.exs`** files. The `.exs` distribution is `test/` 90, `research/` 9, `!tasks/` 6, `scripts/` 5, and one each in `config/`, `examples/`, and `priv/`. This is **not** the requested zero-source state. The `test/support/beam_lisp_test.ex` helper has already been replaced by a seeded BL host; no repository `.ex` files remain outside the five production substrate modules below.

The earlier dependency sweep checked 1,165 authored files under `lib/`, `priv/`, `test/`, `bin/`, `config/`, `native/`, `scripts/`, `examples/`, `bench/`, `tooling/`, and `editors/`, as well as the two extensionless launch scripts and `env.bl`. It traced literal calls, dynamically constructed module atoms, OTP callbacks and child specs, seed-manifest host leaves, compile-time macros, protocol implementations, and test entry points. `projects/**` was checked for the earlier four candidate modules, with no references found. This is a conservative static reachability audit, not a proof of unreachability in external consumers.

## Definitive *in-repository* deletion finding

**None of the remaining five `.ex` files is unused.** An import-only scan would be wrong: the cold launcher, OTP application callback, dynamic namespace loader, and seeded host/compiler paths invoke these modules even when no explicit `import` names them.

| Remaining source | Observed root / dependency | Gate before removal |
| --- | --- | --- |
| `lib/beam_lisp/aot_cache.ex` | `bin/bl` computes the live compiler key; `BeamLisp.AOT`, build and seed use cache/provenance operations. Compiler-pinned host-source mappings are part of the key contract. | BL exact-atom replacement must work **before** bootstrap verdicts and hash all migrated codegen leaves; edit a codegen source in a scratch tree to prove key rotation, then rebuild tier and seed. |
| `lib/beam_lisp/aot.ex` | `BeamLisp.init/0` and the launcher load/build the boot tier; `seed.bl` calls the pinned host compiler, and tests compile probes through it. | Port descriptor compilation, bootstrap-tier install, macro/struct attributes, diagnostics and provenance together; cold checkout and seed fixpoint required. |
| `lib/beam_lisp/bootstrap.ex` | `bin/bl` calls `install_hosts!` before the tier verdict and `install!` to enforce the committed seed manifest. | BL replacement must be staged by `bin/bl-stage-hosts` before `elixirc` and operate without preloaded `Ns.Rt`; corrupt-host and same-key SHA freshness cases must remain covered. |
| `lib/beam_lisp/loader.ex` | Runtime `require`, `BeamLisp.run_file/1`, and app bootstrap resolve and load namespaces; `Loader.Server` is an OTP child. | Preserve dynamic namespace load, source/beam preference, path semantics, diagnostics and concurrent loader ownership under cold boot. |
| `lib/beam_lisp/env.ex` | OTP application starts the registry; reader/compiler/linker, all pinned host leaves and test isolation use its var table. | Preserve ETS/Agent ownership, namespace resolution, process-local bindings and seeded state; it is the lowest pre-boot dependency and cannot call `Ns.Rt` before that tier loads. |

The earlier apparent candidates were **not deleted as unused**: `DevChange`, `AnfInterpreter`, `Sandbox` and `ExUnitCase` were ported with their public/test contracts and seeded at their exact atoms. `DevChange` is a loadable public dev namespace; `AnfInterpreter` is the live ANF oracle; `Sandbox` and `ExUnitCase` are public test APIs. Their absence from a CLI import list never justified losing coverage.

## Dynamic reachability edges

- `env.bl` declares the `BeamLisp.Application` OTP callback. It starts `BeamLisp.Env` and `BeamLisp.Loader.Server`, then calls `BeamLisp.init/0`; the application and root API are already committed BL host beams, but the Env implementation remains Elixir.
- `bin/bl-stage-hosts` verifies and stages exact manifest-listed host beams **before** `elixirc`. `Bootstrap.install_hosts!` establishes SHA authority before tier-key comparison. A stale boot tier rebuilds as a unit and re-executes in a fresh VM.
- `AOT` dynamically builds `BeamLisp.Ns.Init.*`/`Body.*`; runtime `Record` and `Server` factories synthesize additional module atoms. `defimpl`, compile-time guard macros, and OTP callbacks are dependency edges without ordinary function-call imports.
- A warm VM can retain a deleted Elixir beam or compiler namespace var. A scratch checkout with no `build/` is the decisive source-removal gate, followed by `bin/bl seed --check` and focused behavior tests.

## Verification status and limits

Completed cutovers through `eebd4c9c` were committed in proved waves. The latest root API and native memo waves passed `bin/bl build --force`, `bin/bl seed --check`, focused BL suites, and scratch-tree cold boot. All orchestrated builds/tests used `systemd-run --user --scope` with explicit `MemoryMax` and `MemorySwapMax`; no unrelated `.local/!journal/todos/*` files were staged. The full repository test suite, migration of all 113 `.exs` files, release-image inspection, and final zero-source inventory **have not been completed**. Do not claim a definitive *externally unused* module list from this static audit: downstream users may load public namespaces by name.
