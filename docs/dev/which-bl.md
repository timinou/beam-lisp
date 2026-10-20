# Run the code you are editing

Use `./bin/bl` in a checkout. Use the full path to an installed drop when
reproducing a packaged release. `command -v bl` identifies the executable on
`PATH`; `bl which` describes a running tool's image. A drop contains an immutable
SDK snapshot. Editing a checkout changes that checkout's commands.

`build/` is the checkout application image. `BEAM_LISP_EBIN` selects an explicitly
prepared image. Keep experiments in private images and caches; an installed
drop's files and another checkout's outputs belong to their owners.

## One compiler VM, fresh project code

`./bin/bl` builds its native transport client with Cargo on first use. The
client reaches an existing VM before starting Elixir or staging host beams.
Each request supplies its directory, arguments and environment.

Current installed drops also run their first default command in the persistent
VM. The first client waits for readiness and retains its command's initialized
state for subsequent clients. `--cold` explicitly starts a fresh VM; an explicit
transport declaration still overrides the default.

The client hashes actual runtime and project bytes under separate identities:

- Runtime identity covers SDK sources, native sources, launcher settings,
  the compiler floor and an explicitly selected image. A change starts a fresh VM.
- Project identity covers project sources and declared or explicit source paths.
  A document analysis realm keeps its environment and bounded content caches.
  A realm with published project definitions retires on a project change, so
  the next execution loads fresh definitions into a new realm in the same VM.

Generated build and cache directories are excluded. Ordinary project edits keep
the compiler warm. Opening a realm creates a cold index owner; commands that
consume the source index build it on that owner. Automatic command VMs skip the
web dashboard, gateway and project schedules.

A checkout VM stays up until `./bin/bl realm stop`. On Linux with an active
systemd user runtime, automatic VMs have a 4 GiB memory limit and 512 MiB swap
limit. Keep test daemons in private runtime directories and stop them in cleanup;
`test/scripts/checkout_transport.py` exercises that lifecycle.

`./bin/bl --cold ...` starts a fresh VM and also works without Cargo. Image builds
and dependency provisioning run cold. The `:warm` setting in `env.bl` or the user
configuration overrides the checkout's default transport policy.

## Compiler floor and SDK

`priv/bootstrap/seed/manifest.term` authenticates the compiler floor by content.
A compiler change requires regenerating and qualifying that floor. Batch boot
and host edits before regeneration:

```sh
BL_BOOTSTRAP_INSTALL=1 scripts/regenerate-seed
./bin/bl --cold seed --check
```

The regenerator uses a bare, capped VM because an application VM already holds
SDK custody. If the current image cannot load changed compiler sources, use a
coherent older source image through `BL_REGEN_ROOT`. The regeneration workflow
and recovery contract are in [bootstrap regeneration](../bootstrap-regeneration.org).

A release reuses the qualified floor and compiles the complete SDK during
`self-build`. Its precompiled index records every member and digest of each
compiled unit. A fresh runtime verifies and restores the whole unit before
initializing it. SDK compilation is build work; runtime admission verifies
source bytes, code identities and ownership evidence.

## Focused runtime host checks

Before runtime host edits, save the seed-matching sources:

```sh
mkdir -p .local/host-bootstrap
cp priv/host/aot.bl priv/host/env.bl priv/host/loader.bl priv/host/reader.bl .local/host-bootstrap/
```

Then run a few relevant files in the isolated checker:

```sh
scripts/check-runtime-hosts \
  --bootstrap-hosts .local/host-bootstrap \
  --work-dir .local/host-check \
  test/bl/perf/spawn_cost_test.bl test/bl/lazy_clean_capture_test.bl
```

It compiles changed hosts with the existing compiler and tests their exact beams
in a second memory-capped VM. Unchanged host beams are reused. Each suite has a
120-second ceiling; `--suite-timeout SECONDS` adjusts it. Failed assertions,
empty suites, timeouts and interrupted phases fail the command.

`--sdk-image APP` copies a prepared SDK into the private image. Repeat
`--compile-sdk SOURCE` for edited SDK units that need normal build compilation;
the checker seals their complete units into the private precompiled index before
starting the test VM. The compiler snapshot stays fixed during runtime checks.
Qualify the actual floor before packaging a release.

## Analysis reuse contracts

LSP and `bl check` share one parsed and lowered document. Summaries, type and
arity diagnostics, emission diagnostics and lint counts consume that document.
Growth analysis runs when a projection requests growth.

Analysis caches use the shared finite-value cache implementation: each
projection has a 32 MiB budget, bounded entry count and aggregate VM accounting.
Keys include exact source content and environment identity; publication revisions
invalidate results when engine or provider definitions change. Concurrent or
unknown publication declines reuse. Hash equality alone cannot certify a proof.
Contexts travel as exact serialized finite identities, so crossing another cache
boundary does not repeatedly expand their tagged containers.

Read-only lease observations do not acquire module execution fences. Env's
serialized starter bookkeeping must remain callable by a process holding those
fences. Execution, transfer and release retain their physical module locks.
Bootstrap manifest parsing is reused only for identical current file bytes.

Mechanical regression tests count lowering passes, retained analyses, SDK
inventory walks and lint candidates. `test/scripts/drop_startup.py` measures a
fresh packaged install and checks that startup compiles no SDK sources.
