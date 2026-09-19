# Shipping

There are two builds. `bl build` AOT-compiles beam-lisp source to `.beam`
modules inside a project; `bl self-build` assembles a release from the
checkout and seals it as the distributable `bl` drop. One ships libraries;
the other ships the language. (The Mix-era `mix bl.build` is gone with
`mix.exs` — see
[../build/the-toolchain-without-mix.md](../build/the-toolchain-without-mix.md).)

## `bl build` — compile namespaces to beams

`bl build PATH... [--out DIR] [--force] [--jobs N] [--native]` compiles sources
in dependency order, in parallel waves, and writes a manifest to the output
directory. Freshness is keyed by the source interface, so a second run is a
no-op and a body edit rebuilds exactly one file.

```sh
$ bl build src --out build
beam-lisp AOT: building 2 source(s)
  …/src/math.bl
  …/src/demo.bl
$ bl build src --out build
beam-lisp AOT: up to date
```

| flag | effect |
|---|---|
| `--out DIR` | output directory (default `build`) |
| `--force` | rebuild every source, ignoring the manifest |
| `--jobs N` | parallel width per wave (default: the scheduler count) |
| `--native` | also emit native modules |

Exit `0` when every source built, `1` when any failed, `2` on a usage error.

Put a directory of these beams on a program's code path with `--code-path DIR`
or `BEAM_LISP_CODE_PATH` — see
[00-the-cli.md](00-the-cli.md#where-a-namespace-is-found).

## The drop — `bl self-build`

`./bin/bl self-build` is the one command that produces a distributable `bl`.
It chains, in order:

1. the tier sources rebuild from the tree's image directory (`.bl/`);
2. the ERTS-carrying release assembles from that image;
3. the Rust launcher named by `--bin` is embedded — cargo builds it from
   `tooling/drop` (`cargo build --release`). The drop ships THAT binary, so a
   launcher fix is missing from the artifact until the binary is rebuilt —
   `cargo check` is not enough;
4. the compound — launcher + payload + trailer — is written to `--out`.

```sh
$ ./bin/bl self-build --bin ~/.cache/cargo-target/release/drop-launcher --out ./bl
self-build: …/bl  (227 tier sources rebuilt from …/.bl, 141404864 payload bytes)
```

| option | effect |
|---|---|
| `--out PATH` | where to write the `bl` binary (default `./bl`) |
| `--bin PATH` | the drop-launcher binary to embed (required) |

The result is a single self-extracting binary carrying ERTS, the native tier
(the language crates, the solver, Explorer), and the shipped libraries. It runs
with no Erlang installed. On first run it extracts to a versioned directory and
installs a launcher; later runs go straight to the payload, and a warm
`bl daemon` for the tree makes them instant.

The escript is not a packaging tier: it is a single BEAM archive that cannot
carry native artifacts. The release assembly inside `bl self-build` is the
only supported one.

## `bl install z3` — the solver

The SMT solver is resolved at exactly one place, `priv/z3/bin/z3`, never from
`PATH`. `bl install z3` downloads the pinned official z3 release for the host
platform, verifies it against a pinned sha256, extracts it into `priv/z3/`, and
smoke-runs it.

```sh
$ bl install z3
fetching https://github.com/Z3Prover/z3/releases/download/z3-4.16.0/z3-4.16.0-x64-glibc-2.39.zip
sha256 verified; extracting to …/priv/z3
bundled z3 ready: Z3 version 4.16.0 - 64 bit
```

The fetched tree is a derived artifact and is gitignored; re-running the task
reproduces it. Re-pinning z3 means bumping the version and the digests in the
task. A fresh checkout that will build a drop, or that will use the prover,
runs this once.

## On a fresh machine: `bl doctor`

Before running anything, ask the machine what it can do:

```sh
$ bl doctor
beam-lisp doctor

  ok   language       (+ 1 2) → 3
  ok   otp            29
  ok   elixir         1.20.2
  ok   beam-lisp      2026.0.0
  ok   search-paths   0 root(s)
  ok   code-paths     44 dir(s)
  ok   datom_fjall    loaded
  ok   explorer       loaded
  ok   lazy_memo      65536 bytes fast lane
  ok   z3             sat
  ok   wry            loaded
  --   daemon         not running (:no_socket)
  --   src/           absent
  --   .bl-check.edn  absent (run `bl check --update`)

  ✓ 2 required probes ok; 3 optional absent
```

Two probes are **required** — the language evaluates, and the LazyMemo fast lane
answers. Every other probe reports an optional capability; an absent native is a
line in the table and the command still exits `0`. `--json` is the same report
as one object for a script.

Exit `1` only when a required probe fails.

## CI

A project's CI runs the same verbs a developer runs. The gate blocks a change
that regresses a proof, breaks a test, or lets a document drift:

```sh
bl test                  # the tests pass
bl check --changed       # no diagnostics, smells, or lost proofs
bl examples              # every example still runs
bl doc run $(find docs -name '*.bl.md' -o -name '*.bl.org')   # docs still run
```

`bl doc run` takes files; feed it the document list (`find`, a shell glob, or
`git ls-files`). `--check` is the strict form: it writes nothing and fails on a
stale result.

The release pipeline itself adds the two build-only steps in front:

```sh
bl deps fetch              # hex tarballs into the content-addressed store
bl deps compile            # …and their beams onto the code path
bl install z3              # the solver, from the pinned asset
cargo build --release --manifest-path tooling/drop/Cargo.toml   # the launcher
./bin/bl self-build --bin <drop-launcher> --out bl-linux-x86_64
```

Each target is built natively on its own runner, because every NIF is compiled
against that runner's libc and the pinned z3 assets are per-platform. The
artifact is then smoke-tested the way a user runs it — cold, no daemon, no
checkout:

```sh
BL_DAEMON=off ./bl version                       # beam-lisp <version>
BL_DAEMON=off ./bl eval '(+ 1 2)'                # 3
BL_DAEMON=off ./bl eval '(datom.store-fjall/available?)'    # true
BL_DAEMON=off ./bl eval '(datom.frame/available?)'          # true
BL_DAEMON=off ./bl eval '(BeamLisp.LazyMemo/fast_lane_bytes)'  # 65536
BL_DAEMON=off ./bl eval '(let [p (z3/open)] (z3/check p "(assert true)"))'  # sat
```

Every assertion is a live native surface, so a payload that silently lost its
native tier fails in CI rather than on a user's machine.

## The verbs that ship a program

- [03-the-live-loop.md](03-the-live-loop.md) — `bl serve` runs a web app and
  keeps it alive; `bl watch` / `bl monitor` reload it on save.
- [00-the-cli.md](00-the-cli.md) — every verb, flag, and exit code.
