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
   * Linux: `$XDG_DATA_HOME/bl` else `~/.local/share/bl`
   * macOS: `~/Library/Application Support/bl`
   * Windows: `%LOCALAPPDATA%\bl`
3. **Versioned payload dir**: `<install>/<sha8>/` — extraction is atomic
   (`.tmp` + rename). After a successful extract, payload dirs other than the
   current one are removed (Burrito-parity GC; the running version never GCs itself).
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
7. GC: drop in a fake older version dir → gone after next successful run.
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
| GC of stale version dir | removed on next successful run |
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
