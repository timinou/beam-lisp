# Shipping

There are two builds. `bl build` AOT-compiles beam-lisp source to `.beam`
modules inside a project; `mix bl.build` produces the distributable `bl` drop.
One ships libraries; the other ships the language.

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

## The drop — `mix bl.build`

`mix bl.build` is the one command that produces a distributable `bl`. It chains,
in order:

1. `mix compile` — the beams, the AOT prelude, the NIFs;
2. `mix release bl` (prod) — the ERTS-carrying release tree;
3. `cargo build --release` in `tooling/drop` — the launcher and pack tool;
4. `drop pack` — graft launcher + payload + trailer into one file;
5. install to `--out` — an atomic rename (default `./bl`).

| option | effect |
|---|---|
| `--out PATH` | where to write the `bl` binary (default `./bl`) |
| `--release DIR` | reuse an existing release tree (skip step 2) |
| `--skip-cargo` | reuse a previously built launcher / pack tool |
| `--target T` | cross-target (`linux/x86_64` …; needs per-target NIFs) |

The result is a single self-extracting binary carrying ERTS, the native tier
(the language crates, the solver, Explorer), and the shipped libraries. It runs
with no Erlang installed. On first run it extracts to a versioned directory and
installs a launcher; later runs go straight to the payload, and a warm
`bl daemon` for the tree makes them instant.

The escript is not a packaging tier: it is a single BEAM archive that cannot
carry native artifacts. `mix release` — which `mix bl.build` wraps — is the only
supported one.

## `mix bl.z3.fetch` — the solver

The SMT solver is resolved at exactly one place, `priv/z3/bin/z3`, never from
`PATH`. `mix bl.z3.fetch` downloads the pinned official z3 release for the host
platform, verifies it against a pinned sha256, extracts it into `priv/z3/`, and
smoke-runs it.

```sh
$ mix bl.z3.fetch
fetching https://github.com/Z3Prover/z3/releases/download/z3-4.16.0/z3-4.16.0-x64-glibc-2.39.zip
sha256 verified; extracting to …/priv/z3
bundled z3 ready: Z3 version 4.16.0 - 64 bit
```

The fetched tree is a derived artifact and is gitignored; re-running the task
reproduces it. Re-pinning z3 means bumping the version and the digests in the
task. A fresh checkout that will build a drop, or that will use the prover,
runs this once — after `mix compile`, so the `priv` symlink exists.

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
mix deps.get
mix compile                 # also creates the priv symlink
mix bl.z3.fetch             # the solver, from the pinned asset
mix bl.build --out bl-linux-x86_64
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
