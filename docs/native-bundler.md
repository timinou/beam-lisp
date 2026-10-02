# `drop` — the beam-lisp native bundler

*Spec, v1 — COMPLETE and verified on Linux (§11). One Rust crate
(`tooling/drop` — NOT under `native/`, which the `:beam_lisp_native`
Mix compiler reserves for Rustler NIF crates). Build-time needs: cargo,
curl, 7z (windows bundle unpack only) — nothing else.*

## 0. The one build option

Whether OTP is bundled is the ONLY packaging decision:

| | command | artifact | needs OTP on host |
|---|---|---|---|
| no | `MIX_ENV=prod mix escript.build` | `bl`, 4 MB | yes |
| yes | `drop pack --release DIR --out BIN` | ~100 MB | **no** |

There are no payload tier flags: a drop is always the full tier
(lang + datom crates + z3 + explorer).

## 1. Purpose

Ship `bl` as ONE file per target that runs with **no Erlang/OTP installed**,
carrying the **full native tier**: language + datom Rust crates + z3 + Explorer/Polars.

Non-goals (v1):

* auto-update channels (trailer is version-tagged; a channel feed is additive later)
* ERTS *building* — we **reuse** prebuilt per-target ERTS bundles (§4); building
  ERTS stays the BEAM-machine project's job
* Phoenix/livebook-style app bundling — this packs a `mix release` of `beam_lisp`, period

## 2. Artifact anatomy

```
┌──────────────────────────────────┐
│  launcher (Rust, static-ish)     │  ~700 KB, compiled per target triple
├──────────────────────────────────┤
│  payload: release.tar.gz         │  gzip of the pruned mix release (§3)
├──────────────────────────────────┤
│  trailer (44 B, fixed)           │  magic + offsets + digest (§2.1)
└──────────────────────────────────┘
```

### 2.1 Trailer (little-endian, at EOF, 56 B)

| field | size | value |
|---|---|---|
| payload offset | u64 | absolute byte offset of the payload |
| payload length | u64 | bytes of payload |
| payload sha256 | 32 B | digest of the payload slice |
| target os | u8 | 0=linux 1=darwin 2=windows |
| target arch | u8 | 0=x86_64 1=aarch64 |
| format version | u16 | 1 |
| magic | 4 B | `DRP1` |

The launcher reads the trailer, re-hashes the payload slice, refuses to run on
mismatch (partial download / tamper), and on success extracts.

### 2.2 Reproducibility

Tar entries sorted, mtimes zeroed, uid/gid 0, paths relative without `./`;
gzip with no name/timestamp (`gzip -n` semantics). Same inputs → identical sha256.

## 3. Payload composition (the full tier)

Input: `MIX_ENV=prod mix release bl` output. Keep everything; **prune** only
build residue (`releases/<v>/` env scripts are kept — the launcher's entry uses
`bin/bl`; `bin/*` service scripts other than `bl` may be dropped).

Rides in the payload:

| component | form | why it works |
|---|---|---|
| language beams + priv/*.bl | OTP apps under `lib/` | normal release |
| datom crates (`datom_fjall` …) | NIF `.so`/`.dll` in `priv/native` | `defnative` loads from app priv; `priv_dir` resolves in a release |
| Explorer/Polars | NIF in `lib/explorer-*/priv` | loaded only on `datom.frame/q-df`; present here by policy |
| z3 | binaries under `lib/beam_lisp-*/priv/z3/<os>-<arch>/` | `z3_port` spawns via port; PATH pinned to priv |

Measured, this tier on Linux x86_64: **258 MB unpacked, 76.4 MB gzipped**
(z3 67 MB + explorer 143 MB dominate; the language itself is ~36 MB unpacked).

## 4. ERTS sourcing — REUSE, verified 2026-09-01

Our toolchain is **OTP 29** (`erts-17.0.1`). Burrito's public CDN (beam-machine
builds) and erlang.org carry matching bundles — probed live:

| target | URL | status |
|---|---|---|
| macOS universal (x86_64 + aarch64 in one) | `https://beam-machine-universal.b-cdn.net/OTP-29.0/macos/universal/otp_29.0_macos_universal.tar.gz` | 200, ~50 MB |
| Linux x86_64 (libc-any) | `https://beam-machine-universal.b-cdn.net/OTP-29.0/linux/x86_64/any/otp_29.0_linux_any_x86_64.tar.gz` | 200 |
| Linux aarch64 | `…/OTP-29.0/linux/aarch64/any/otp_29.0_linux_any_aarch64.tar.gz` | 200 |
| Windows x64 | `https://github.com/erlang/otp/releases/download/OTP-29.0/otp_win64_29.0.exe` | 302 (official installer; unpack with 7z) |

Rules:

* **Version pinning is load-bearing**: ERTS major must match the OTP the beams
  were compiled for. `drop pack` refuses mismatched `--erts` unless
  `--force-erts` (for experiments only).
* **Integrity**: each bundle is pinned by sha256 in `tooling/drop/erts.lock`.
  First `pack` fetches, verifies, caches under `~/.cache/drop/erts/`;
  later packs hit the cache. The CDN operator politely asks bandwidth
  restraint — after first fetch we are self-sufficient.
* **Mirroring**: once pinned, re-host the bundles on our own storage for CI;
  the URL table lives in `erts.lock` so switching source is a lock-file edit.
* **Licensing**: ERTS is Apache-2.0 — payload ships `lib/erl_licenses/` +
  our NOTICE, as `mix release` already does.

## 5. NIF & native-binary strategy per target

| component | linux x86_64/aarch64 | macOS universal | windows x64 |
|---|---|---|---|
| datom crates (ours, cargo) | `cargo build --target` on CI | `cargo-zigbuild` or macOS runner | `cargo build --target x86_64-pc-windows-msvc` |
| explorer/polars (cargo) | same, or upstream precompiled artifacts | same | same |
| z3 | official z3 release tarballs per target | same (universal build exists) | same (zip + DLLs next to exe) |

The bundler does NOT compile NIFs (v1). `pack` asserts the release's
`priv/native` and explorer priv contain objects for the *target* (ELF/Mach-O/PE
magic check) and fails loudly on a host-only payload — the classic
"packed a linux .so for windows" mistake.

## 6. Runtime contract (the launcher)

1. **Validate**: read trailer, hash payload, compare.
2. **Install dir** (first-run extraction target):
   * Linux: `$XDG_DATA_HOME/drop` else `~/.local/share/drop`
   * macOS: `~/Library/Application Support/drop`
   * Windows: `%LOCALAPPDATA%\drop`
3. **Versioned payload dir**: `<install>/<sha8>/` — extraction is atomic
   (`.tmp` + rename). A payload dir is removed only when nothing holds it
   (see §15, *Cleaning up*): a VM execs helper binaries (`inet_gethost`,
   `erl_child_setup`) out of its own erts dir, lazily, and a daemon runs from
   its tree for its whole life, so deleting a tree some process runs from kills
   it with `Can not execute …/erts-*/bin/inet_gethost : enoent`.
4. **Exec**:
   * unix: `execve("<install>/<sha8>/bin/bl", ["bl", "eval", ENTRY, "--", …argv])`
     where `ENTRY = BeamLisp.Ns.Bl.Cli.main(System.argv())`
   * windows: `CreateProcess` on `bin\bl.bat` with the same arguments
   * `eval` mode loads all release code paths → `priv_dir(:beam_lisp)` resolves →
     z3/native/explorer all findable; `AOT.boot/0` starts the substrate on demand,
     so "apps not started" in eval mode is irrelevant.
5. **Exit codes**: launcher forwards the child's exit status verbatim;
   126/127 reserved for launcher failures (extraction failed / payload corrupt).
6. **Signals**: unix launcher `execve`s (same pid), so Ctrl+C reaches the VM
   untouched. Windows forwards `CTRL_C_EVENT`/`CTRL_BREAK`.
7. **Maintenance** (burrito-parity): `bl maintenance directory|meta|uninstall`
   handled by the launcher BEFORE extraction/unexec.
8. `bl` with no args → repl, exactly like the escript (argv empty ⇒ repl).

## 7. `drop` CLI

```
drop pack   --release DIR --out BIN [--target os/arch] [--erts auto|FILE] [--launcher BIN]
drop fetch  --target os/arch            # download+verify ERTS into cache, print path
drop unpack BIN --dir D                 # extract without running (CI inspection)
drop inspect BIN                        # print trailer fields
```

Targets: `linux/x86_64` · `linux/aarch64` · `macos/universal` · `windows/x64`.
No `--target` = host; the release's own ERTS rides as-is (fastest, and NIF
libc always matches). With `--target`, the bundle is fetched from `erts.lock`
(cache: `~/.cache/drop/erts/`), grafted, and the OTP libs the bundle also
ships (crypto/ssl/…) replace the release's — they must match the bundle's
libc. The release tree is copied to a work dir first; a host release is
never mutated.

`make-drops.sh` orchestrates: host release → host drop + all cross-target
drops (cross-target runs green once NIFs are built for the target libc — §5).

## 8. Launcher implementation constraints

* Rust, **std + `flate2` + `tar` + `sha2` only** (pure Rust → `rustup target`
  cross-builds without a C toolchain; Windows needs no MSVC for the launcher).
* No shell-outs except the final exec. No network at runtime.
* macOS binaries are ad-hoc-signable; real codesign/notarization is a release-pipeline
  step OUTSIDE `drop` v1 (identity is org policy, not bundler policy).

## 9. Test plan / acceptance

1. `drop pack` on the measured release → binary ≈ payload+~1 MB.
2. `drop unpack` → tree byte-equal to input release (sorted-tar determinism:
   two packs → identical sha256).
3. `./bl version` → `beam-lisp 0.1.0`, exit 0. `./bl eval '(+ 1 2)'` → 3.
4. Corrupt one payload byte → clean error, exit 126.
5. `./bl run examples/hello.bl` → expected output, exit 0.
6. Second run hits the extracted cache (no re-extraction; mtimes prove it).
7. GC: two payloads side by side — running the second leaves the first's tree
   intact; a tree nothing holds is swept (`launcher.rs::gc_tests`, §15).
8. (cross-target, CI-gated) same for darwin-universal + windows packs; z3 smoke
   `bl eval '(z3/…)'`; explorer smoke `datom.frame/q-df`.

## 10. Resolved decisions (were open in v1 draft)

* z3 ships pruned to the target's directory when a per-target split is needed;
  today the bundle carries all of priv/z3 (67 MB) — accepted until size bites.
* No tier flags. Full tier only; the single build option is bundled-OTP-or-not (§0).
* macOS minimum version: read from the bundle at pack time when it starts
  mattering (trailer has room via FORMAT_VERSION bump).

## 11. v1 status (complete; verified on Linux x86_64)

v1 additions over the prototype:

* `drop fetch` + `erts.lock` — all four target bundles fetched and verified;
  linux/macos/windows sha256 pinned in the lock.
* ERTS graft — replaces the release's erts dir under the name the release
  expects (read from `releases/*/elixir`), instantiates `*.src` bin scripts,
  and takes the bundle's OTP NIF-carrying libs (crypto/ssl/…) so the VM and
  its NIFs share a libc. Windows installer unpacked with 7z (`-o` attached —
  7z rejects a separate flag).
* `drop unpack` — CI-side extraction, shared code with the launcher.
* `make-drops.sh` — host drop + all cross-target drops from one command.

**The libc rule (the one real cross-target constraint):** beam-machine linux
bundles are static-musl ("any"). A glibc-built NIF cannot load into them —
grafting the bundle's OTP libs fixes crypto/ssl, but the Rust NIFs (datom
crates, explorer/polars) must be built for the target libc
(`cargo zigbuild --target x86_64-unknown-linux-musl`). Until those artifacts
are staged per target, cross-target drops boot and run the pure-language
surface; host-target drops are fully green including all NIFs.

`tooling/drop` — two binaries, shared trailer module:

* `drop pack|inspect` — deterministic tar.gz (sorted, mtime 0, gzip -n
  semantics), appended to the launcher, trailer written. Two packs of the same
  release are **byte-identical** (verified).
* `drop-launcher` — validate → extract (zip-slip-guarded, atomic `.tmp` + rename)
  → GC old versions → `execve bin/bl eval BeamLisp.Ns.Bl.Cli.main(System.argv()) …`.
  `maintenance directory|meta|uninstall` handled pre-extraction.

Acceptance results (full tier: lang + datom crates + z3 + explorer):

| check | result |
|---|---|
| `bl-bundle version` | `beam-lisp 0.1.0`, exit 0 |
| `bl-bundle eval '(+ 1 2)'` | `3`, exit 0 |
| `bl-bundle run examples/hello.bl` | full output + `:ok`, exit 0 (×3 stable) |
| corrupted payload byte | clean sha error, exit 126 |
| cache-hit second run | 566 ms (vs multi-second first run) |
| GC of stale version dir | by reference (§15); a concurrent version's tree is left alone |
| reproducibility | two packs byte-identical |
| bundle size | launcher 0.7 MB + payload 97.1 MB (unstripped beams, §3) ≈ 98 MB |

Two release-integration findings baked into the design:

1. **`mix release` strips beams by default**, which re-stamps every module —
   the AOT drift gate (`aot.ex stale?/2`) then rightly refuses them and every
   AOT namespace falls back to source recompilation. The `bl` release sets
   `strip_beams: false`, and `cli.bl main` still pairs
   `AOT.ensure_loaded` → `Loader.ensure_loaded` on `:no_module` as the loader
   docstring prescribes. Defense in depth, both paths verified.
2. Trailing args after `bin/bl eval EXPR` land in `System.argv()` verbatim —
   a `--` separator LEAKS into argv (verified empirically), so the launcher
   does not add one.

## 12. The warm daemon — a ~instant dev loop

A drop's launcher does more than extract-and-exec: before it cold-boots the
release VM (~1s), it looks for a **warm `bl daemon`** for the caller's tree and
forwards the command to it over a Unix socket. A served command returns in
~20ms instead of ~1s. The escript path costs ~30s per invocation (it cold-loads
its whole archive every time) and cannot load NIFs at all — the daemon+drop
pair is strictly better, so the escript is deprecated.

### One daemon per tree and build

A daemon runs ONE build's code for ONE tree, so it is named by both. The tree
key is the first 16 hex of `sha256(realpath(root))`; the build is `BL_BUILD_ID`
— the payload's sha8, which the launcher sets, or `src` for a checkout run
through `bin/bl`. Its endpoints live under `$XDG_RUNTIME_DIR/beam_lisp/` (a
`0700` dir): `<tree>-<build>.sock` (the `AF_UNIX` stream socket, `0600`),
`<tree>-<build>.token` (a 256-bit secret), and `<tree>-<build>.meta` (pid, root,
build, start time). Two builds used in one tree are two daemons, side by side;
`daemon stop` removes all three files. The socket's existence is discovery; an
**authenticated hello** (constant-time token compare + matching tree
fingerprint + the build the client expects) is authority.

### The wire

Frames are length-prefixed (`{packet, 4}`) Erlang terms (ETF). The daemon
decodes with `binary_to_term(bin, [:safe])` and then a total, allowlisted schema
check — a malformed or oversized frame is refused, never executed. A client
`hello` (`tree`, `token`, `build`) gets `ready` or a `reject` (`unauthorized` ·
`wrong_tree` · `restart_required` when it names another build ·
`shutting_down`). Then one `request` (`argv`, `cwd`,
`env_paths`) streams back `stdout`/`stderr`/`stdin`/`exit` frames.

### A VM per project, a process per request

The daemon holds a **warm VM per project** and runs each command as its own
process under that VM. Per request it forks a fresh env, binds the client's
roots and cwd/argv, overlays the client's environment *process-locally* (never
the node-global table), and routes stdout through a per-request group-leader
proxy — so N concurrent commands are N processes, never a queue, and one
command's env never leaks into the next. Two `bl run`s from two terminals run at
once. Only the reload/intent **sequencer** takes turns: a save's stage→commit
and a dashboard-launched task ride one sequencer so they are ordered against
each other, never racing a program the daemon is running.

### Staleness is a restart, never a hot-swap

The daemon freezes the compiler key it booted with. When the checkout changes
under it (the live key moves) or a client presents a different key, it refuses
work with `restart_required`: a stale VM never serves: it is stopped and a fresh
one loads a single coherent image. Mixing old loaded code with new sources is
the one thing a warm VM must not do.

### Using it

```
bl daemon start     # become the daemon (blocks; the launcher runs it detached)
bl daemon status    # a live daemon's pid, tree, build, compiler key, uptime
bl daemon stop      # drain and exit; the socket is removed

BL_DAEMON=off       # every command cold-boots, no daemon
BL_DAEMON=auto      # a missing daemon is auto-started, then attached
```

The fallback is total: no daemon (or `BL_DAEMON=off`) means each `bl` is an
ordinary cold boot — correct, just slower. A command is never silently retried
after its request frame is sent, because side effects may already have happened;
a lost connection there is an unknown outcome (exit 1), not a re-run.

## 13. Building the blessed `bl`

`mix bl.build` is the one command: compile → `mix release bl` (prod) → build the
Rust launcher + pack tool → `drop pack` → install `./bl`. Options: `--out PATH`,
`--release DIR` (reuse a tree), `--skip-cargo`, `--target os/arch`. The escript
(`mix escript.build`) still builds as a legacy path; prefer the drop.

## 14. CI — GitHub Actions (`.github/workflows/release.yml`)

One drop per target, attached to a GitHub release on a `v*` tag (or built
without publishing via `workflow_dispatch`).

| artifact | runner | note |
|---|---|---|
| `bl-linux-x86_64` | `ubuntu-24.04` | glibc ≥ 2.39 — that is the pinned z3 asset's floor (`z3-4.16.0-x64-glibc-2.39`), which the fetch task smoke-runs |
| `bl-linux-aarch64` | `ubuntu-24.04-arm` | z3's aarch64 asset is glibc 2.38 |
| `bl-macos-arm64` | `macos-15` | |
| `bl-macos-x86_64` | `macos-15-intel` | `macos-13` was retired 2025-12; `macos-15-intel` is its replacement |

**Each target is built natively, on its own runner.** That is the design, not
a shortcut:

* every NIF is compiled against the runner's own libc/ABI, so it always
  matches the ERTS `mix release` copies in. Cross-packing onto the
  beam-machine `linux/any` (musl) bundles instead triggers the libc rule (§11):
  the Rust NIFs would need musl artifacts (`cargo zigbuild`) **and** the pinned
  z3 linux assets are glibc-only, so a pure-musl payload could not carry the
  solver at all.
* `mix bl.z3.fetch` picks its asset from the host OS/arch, and
  `explorer`'s `rustler_precompiled` NIF matches the runner triple.

The legs all run the same sequence — `mix bl.build` (§13) with its
prerequisites in front:

```sh
mix deps.get
mix compile                 # also creates _build/$MIX_ENV/lib/beam_lisp/priv
mix bl.z3.fetch      # writes through that priv symlink into priv/z3
mix bl.build --out bl-<target>
```

`BL_VERSION` (the tag minus its leading `v`, normalized to a valid
`Version`: `v2026.0` → `2026.0.0`) stamps the release, so `bl version` on the
artifact reports it; the GitHub release keeps the tag's name. On macOS the
fetched z3 binary is ad-hoc signed before packing — Apple Silicon will not
execute unsigned pages.

**Per-platform prerequisites.** `wry_webview` is a Linux capability (gtk3 +
webkit2gtk + wlr-layer-shell): its Cargo dependencies are `cfg(target_os =
"linux")`-gated and its `lib.rs` is crate-level `cfg(target_os = "linux")`, so
the macOS legs compile it to an empty cdylib and `wry/*` reads as ABSENT
(§5, and the `defnative` doctrine). The Linux legs install
`libgtk-3-dev libwebkit2gtk-4.1-dev libgtk-layer-shell-dev` first.

The smoke step runs the artifact the way a user does — cold, no daemon, no
checkout — and asserts a live native surface of each tier: the language, a
Rust NIF (`datom.store-fjall/available?`), Explorer (`datom.frame/available?`),
the `lazy_memo` runtime, and the z3 port (`z3/check` → `sat`). A payload that
silently lost its native tier fails in CI, not on a user's machine.

**Deliberately not in CI:** code signing / notarization (§8 — org policy, not
bundler policy), and single-host cross-target packs (`--target`) until
per-target NIF staging lands (§5).

The same workflow runs on every push to `main`: the drops are stamped
`0.1.0-latest.<sha8>`, and the `publish-latest` job moves the tag `latest` to
that commit and replaces the assets of the `latest` pre-release. That release
is what `bl self-update latest` fetches on a machine with no beam-lisp checkout.

## 15. One `bl` on PATH, many builds behind it

`~/.local/bin/bl` is the launcher with NO payload. On every call it decides
which build runs here, then runs it exactly as that drop would (daemon
fast-path included). The decision is `bl which`:

```
$ bl which
launcher  ~/.local/bin/bl
store     ~/.local/share/drop
  1 BL_USE unset
  2 beam-lisp source tree ~/code/undefine/beam-lisp--names
    its last build 868977b2 matches this state
runs      build 868977b2  (commit d1d1cd18… · worktree … · built-at …)
```

### Which build runs (first match wins)

1. `BL_USE=<name>` in the environment.
2. Inside a beam-lisp **source tree** (`priv/boot/core.bl` + `bin/bl` + `.git`):
   that tree's last build, if it was built from exactly this state; otherwise
   the tree runs **from source** (`<tree>/bin/bl`), which is always current.
3. The nearest `env.bl` declares `:bl "<name>"`. A build that is not in the
   store yet is fetched or built right then (`BL_BUILD=never` refuses instead).
4. `:default` in `~/.config/bl/config.bl`, else `stable`.

A drop run by its path (`./bl`, a tool's pinned runtime) is not resolved: an
explicit path is an explicit choice.

### Build names

| name | the build |
|---|---|
| `stable` | the newest tagged release (`vX.Y`), downloaded and checksum-verified |
| `latest` | `main`: built locally from `:source` when the machine has it, else CI's rolling `latest` release |
| `bleeding-edge` | the newest build of the `:source` checkout |
| `bleeding-edge:DIR` / `bleeding-edge:BRANCH` | the newest build of one worktree |
| `v2026.4` | that release |
| `commit:1cf72d26` | that commit, built clean in a detached worktree under `~/.cache/bl/build-trees/` |
| `build:7154e76a` | one stored build, by id |
| `path:/abs/drop` | a drop file, as-is |

### Knowing a tree's build without asking git

The launcher never runs git: spawning any process costs more than the whole
decision. A worktree's build is recognised by its **stamp** — a hash over the
path, size and mtime of every build input (`lib priv native tooling/drop/{src,
Cargo.toml,Cargo.lock} bin env.bl bl.lock`, build outputs excluded) plus the
commit `HEAD` names, read from the git files directly. A build records the
stamp it was built from; any edit to an input changes it, and the tree runs
from source until it is built again. Editing a note or a doc changes nothing.
The same input list decides whether a build is `+dirty` (`provenance/INPUTS`;
a test keeps the two equal).

### The store

```
~/.local/share/drop/<sha8>/                 an extracted payload
~/.local/share/drop/store/channels/stable   pointer files: "build <sha8>" + where it came from
~/.local/share/drop/store/channels/latest
~/.local/share/drop/store/tags/<vX.Y>
~/.local/share/drop/store/bleeding-edge/<tree-id>
~/.local/share/drop/store/sources/<commit>[+<diff12>]
~/.local/share/drop/store/logs/<tree-id>.log      the last build of each tree
```

Every write is temp + rename. At most one build runs on the machine at a time
(`store/locks/build`); each build step is stopped after `BL_BUILD_TIMEOUT_MIN`
(45).

### Getting builds, and keeping them current

```
bl self-install [--source DIR]   put the launcher at ~/.local/bin/bl; record where beam-lisp lives
bl self-update [NAME]            fetch or build NAME (default: stable, then latest)
bl hooks install [DIR]           automatic builds / the latest guard, for the repo at DIR
bl self-gc [--dry-run]           what the store holds, and why each build stays
```

`bl hooks install` in a beam-lisp checkout adds `post-commit`, `post-merge`,
`post-checkout` and `post-rewrite` to the hooks every worktree shares. Each
queues the worktree that fired and starts one detached builder, which builds
queued trees one at a time; a build of the `:source` checkout on `main` also
moves `latest`. Uncommitted work never waits for a build: it runs from source.
`BL_AUTOBUILD=off` stops the builds.

In a project whose `env.bl` says `:bl "latest"`, `bl hooks install` adds a
`pre-push` guard. When the local beam-lisp `main` has commits `origin/main` does
not, the push is refused: the project may depend on them, and every other
machine's `latest` (and CI's) lacks them. Push beam-lisp first, or pin
`:bl "commit:<sha>"`. `BL_ALLOW_UNPUSHED_LATEST=1` pushes anyway.

Hooks already in the repository keep running: each is renamed `<hook>.pre-bl`
and called first. `bl hooks remove` puts them back.

### Cleaning up

A payload dir stays while anything holds it: it is the build being run, a
pointer names it (a channel, a tag, or a worktree that still exists), a daemon
serves it, a process runs from it, or it was used in the last
`BL_DROP_KEEP_DAYS` (14) days. Anything else is removed after
`BL_DROP_GRACE_HOURS` (24). The launcher sweeps after each first extraction;
`bl self-gc --dry-run` shows every build and the reason it stays.

### Where a build came from

Every drop carries `BUILD_INFO.bl` at the root of its payload: repository,
worktree, branch, commit, whether its inputs were dirty (and a hash of the
diff), when, where, and with which compiler.

```
$ bl version
beam-lisp 0.1.0 · 1cf72d26+dirty (main) · ~/code/undefine/beam-lisp · built 2026-09-24T08:58:37Z · build 6da863d2
$ bl version --short
beam-lisp 0.1.0
```

`bl version --json` prints the whole record.

