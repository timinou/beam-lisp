# The toolchain without Mix

The build, the test runner, the release and the self-build do not need Mix. This
is what replaced it, what state lives where, and — plainly — the one thing that
still does.

## The verbs

| what | was | is |
|---|---|---|
| compile | `mix compile` | `bl build` |
| compile the Elixir side | `mix compile` (elixirc) | `bl build` — the `:ex` stage `env.bl` declares |
| test | `mix test` | `bl test` (`.bl` **and** `.exs`) |
| run a project task | `mix <task>` | `bl <task>` (`env.bl`'s `:tasks`) |
| assemble a release | `mix release` | `bl self-build` (it assembles one and seals it) |
| seed the bootstrap floor | `mix run priv/bootstrap/gen_manifest.exs` | `bl seed` |
| dependencies | `mix deps.get` | `bl deps fetch` (see *the gap*, below) |
| CLI from a checkout | `mix bl …` | `./bin/bl …` |
| environment report | — | `bl doctor [--deep] [--json]` |

A `bl build --release` / `--self` — one pipeline with the output shape as a
parameter — is the first half of FUP-056 and is *not* implemented; the release
path is reachable through `bl self-build`, which reproduces a drop from inside
one.

`bl build` with no arguments builds what the tree **declared**: `:build` in
`env.bl` names the roots, the output directory, the width, whether the tree has
natives, and the substrate's `:ex` root and excludes. A flag still wins, and a
PATH argument still means what it meant.

## `env.bl` declares, state lives outside the tree

An `env.bl` at a project's root is a map, read as **data** — no evaluation — and
found by walking up from wherever the command was typed. Nine keys:

```
:name :paths :tasks :ports :env            the development surface
:app :build :release :deps                 what the tree IS and REQUIRES
```

The last four are **declarations, never state**. Nothing in `env.bl` records what
has been built or fetched; that lives beside the work:

| state | where | why there |
|---|---|---|
| build facts | `<out>/build.log` | the log is the build's memory; one fact per source per run |
| build manifest | `<out>/manifest` | a *projection* of the log, not a second truth |
| libraries | `~/.cache/beam_lisp/lib/<name>-<vsn>-<sha8>` | content-addressed, so a directory that exists is a library that is complete |
| native artefacts | `~/.cache/beam_lisp/native/<key>/<crate>` | keyed by the content of `src/**/*.rs`, `Cargo.toml`, `.cargo/config.toml` and a lock **that constrains something** |
| who is building | a claim file in the out dir | a claim NAMES its owner; a lock names nobody |
| the bootstrap floor | `priv/bootstrap/seed/` (committed) | the beams a tree with no generation boots the compiler from, and the manifest that says which toolchain built them (`bl seed` regenerates both) |

A release carries **no build state**: the log and the manifest stay outside the
tree, so two independent builds of the same sources produce byte-identical trees
(`BeamLisp.Pristine` compares them and reports every difference by name).

## The kind of image, and why "is Mix loaded?" had to go

Whoever builds an image declares what it is, and that declaration decides whether
the image may mutate itself:

```
BL_BIN set              a drop      (the Rust launcher names its compound)
BEAM_LISP_IMAGE set     a release   (the shell launcher states its kind)
neither                 development (a checkout, a test run, CI)
BEAM_LISP_DEV=1         development, whatever the image — a tree declares itself
BEAM_LISP_RELOAD=1      an operator opts a packaged node in, per node
```

`reload` used to answer this by asking whether `Elixir.Mix` was loaded. That
answer disappears the day Mix is deleted — and it disappears in the wrong
direction: every development image would look like production and refuse
mutating reloads. `BeamLisp.Image` is now the one implementation of the rule;
`reload` (in bl) and the application's dev-server decision both call it.

## The toolchain reports on itself

`bl doctor` answers *can this host run a beam-lisp?* `bl doctor --deep` answers a
different question — *is this toolchain free of the build system it replaced?* —
and it is the one place that deletion is OBSERVABLE:

```
mix            required, and PASSES when Mix is absent — a `bl` that needed Mix
               would fail the probe that exists to witness its removal
mix-residue    what is left, named: mix.exs, mix.lock, lib/mix/tasks (n files),
               deps/ — reported and NOT required, because they stay until a
               locked library can be compiled onto the code path without Mix
bl.lock        how many libraries the tree declares
store          locked vs present in the content-addressed store, offline
seed           which toolchain built the floor, and whether it is this one
image          dev / release / drop, and whether reloads may mutate in place
```

Residue is a fact, not a verdict. A required probe this repository cannot pass
would be a probe that lies about the tree it reports on, which is why `mix` is
the only required one — and why its PASS means *absent*. `--json` carries the
same facts as one object; the exit code follows the required probes only.

## The gap, stated plainly

**Dependency provisioning still needs Mix.** Of the 47 packages in `bl.lock`, 44
build with `mix` and 3 with `rebar3`. `bl deps fetch` obtains hex tarballs into
the content-addressed store and verifies them offline, but it does not *compile*
them, and beam-lisp's code path needs their beams.

So `mix.exs`, `mix.lock` and `deps/` are still present, and CI runs
`mix deps.get && mix deps.compile` as its first step — the only Mix in the
pipeline. `bl.lock` is already the replacement lock, with the same names,
versions and digests, and a test refuses to let the two disagree while both
exist.

Closing that gap is what makes a fresh clone buildable with nothing but `bl`, and
it is also the first half of distributing beam-lisp applications at all. It is
scheduled as [FUP-056](../../!tasks/follow-ups/FUP-056-unify-bl-build-with-bl-self-build-distri.org).
