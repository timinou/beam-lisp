# Migration

Old name → new name, and how the cutover happens without two implementations
living side by side forever.

## Words

| old | new | note |
|---|---|---|
| daemon (the project, warm) | **realm** | what a developer means |
| daemon (the OS process) | **vm** | what `ps` shows |
| `vm.core` "VM" | **realm** | the code says "NOT a separate BEAM node": it was always a realm |
| session (warm project) | **realm** | session stays the word for a REPL or browser session |
| "env" (user-facing) | **project** (`env.bl`) | the fork primitive keeps `env` |

## Commands

| old | new |
|---|---|
| `bl daemon start` | implicit on first command; explicit: `bl realm start` |
| `bl daemon stop` | `bl realm stop` |
| `bl daemon status` | `bl realm show` |
| `bl ports` | `bl vm` (machine) · `bl realm show` (project) |
| `bl open NAME` | `bl realm open NAME` |
| `bl gateway start\|stop\|status` | `bl vm start gateway` · `bl vm stop gateway` · `bl vm` |
| `bl ui` | `bl vm ui` |
| `bl install gateway` | unchanged |

Top-level verbs: 35 today, 37 with `vm` and `realm` added, 33 after the four old ones are removed.

## Namespaces

| now | becomes |
|---|---|
| `vm.core`, `vm.owner`, `vm.scope`, `vm.osenv`, `vm.spec`, `vm.manager`, `vm.sched`, `vm.index`, `vm.repl`, `vm.inspect`, `vm.exec`, `vm.catalog` | `realm.*` |
| `vm.paths`, `vm.net`, `vm.wire`, `vm.io`, `vm.image`, `vm.generation`, `vm.registry`, `vm.inventory`, `vm.client`, `vm.session` | stay `vm.*` (process level) |
| `vm.ports`, `vm.names`, `vm.gateway`, `vm.ca` | `route.*` |

## The cutover rule

> **One need, one implementation.** The old verbs are removed, not kept as a
> parallel path.

1. **Add** the new nouns beside the old (this slice).
2. **Forward.** Each old verb becomes a one-line forwarder that prints a single
   deprecation line, for one release.
3. **Delete** the forwarders.
4. **Rename** the namespaces, mechanically, in one commit per group, after
   behaviour is settled. A rename is reviewable only when nothing else changes.

Renames use `edit` with `rename`, never find-and-replace, so references follow.

## Files and paths that are part of the contract

These are read by the Rust launcher (`tooling/drop/src/daemon.rs`) and must change
in both places or neither:

| contract | where |
|---|---|
| `<tree-id>-<build>.sock/.token` naming | `vm.paths/endpoints` ↔ `daemon.rs endpoints_for` |
| tree id and fingerprint (sha256 of realpath) | `vm.paths` ↔ `daemon.rs` — golden-tested |
| runtime dir | `vm.paths/runtime-dir` ↔ `daemon.rs runtime_dir` |
| port claim keys | `vm.ports` ↔ any other reader |
| `daemon_builds()` (drop GC treats a socket as a live daemon) | `launcher.rs` |

The last one is a bug waiting: it treats **any** `<tree>-<build>.sock` filename as
live, without checking a listener, so a dead socket keeps a drop build from being
collected. The registry fixes it by giving GC one honest question to ask: *is
this record live?*

## What changes for a user, in one paragraph

You type `bl` and it is fast. `bl vm` shows what is running. `bl vm stop` stops
it. `bl realm` is your project. The word *daemon* is gone from the interface.
