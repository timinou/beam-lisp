# W0 — self-build probes

De-risking the design in `!tasks/plans/PLAN-108-the-drop-builds-itself-bl-as-the-whole-t.org`.
Each probe is decisive on one unknown; a verdict is only recorded when the
output was observed, and the command that produced it is written down.

Run them with the drop's own Elixir (`<release>/bin/bl eval '…'`) so every
result is evidence about the SHIPPED artifact, not about a dev checkout.

Environment note: the drop under test is the one the repo `bl` carries.
`./bl maintenance meta` names its payload sha (`03cd2b3d…`); never select a
payload directory by mtime — parallel sessions leave newer unrelated ones
around.

## Verdicts

| # | question | verdict | evidence |
|---|---|---|---|
| P1a | does a launcher built from HEAD export `BL_BIN`? | **PASS** | `strings drop-launcher` → `BL_BIN`=1, control `BL_DAEMON`=2 |
| P1b | does `drop pack` round-trip a hand-assembled tree? | **PASS** | 103,588,258-byte drop, `inspect` parses it |
| P1c | is packing deterministic? | **PASS** | two packs → identical sha256 `3daeccf6…` |
| P1d | does the new drop run, with `BL_BIN` = its own path? | **PASS** | `eval '(+ 1 2)'`→3; `BL_BIN`→`…/p1/bl-p1a` |
| P1f | is the self-graft arithmetic recoverable inside a drop? | **PASS** | `offset+len+56 == size`; sha matches; launcher prefix 810,104 B |
| P2 | can the drop compile the Elixir substrate with no Mix? | **PASS** | 86 modules, 86 beams, 9,902 ms, no Mix |
| P3 | does `:systools` produce the boot scripts in the drop? | **PASS** | `make_script`→`{:ok,_,[]}`; `script2boot`→`:ok` |
| P4 | is gzip available and deterministic in the drop? | **PASS** | `:zlib.gzip` works; `a == b` for repeated input |
| P5 | does a hand-assembled, unconsolidated tree boot? | **PASS** | Elixir 1.20.2 boots; the language returns 42 |
| P6 | byte-identical to `mix release`? | **DEFERRED** | needs a `deps/` + full compile in this worktree; the informational half is done below |

## P1 — launcher and packer

    research/selfbuild/p1_launcher.sh <bin-dir> <release-tree> <workdir>
    research/selfbuild/p1f_trailer_recovery.exs   (run inside a drop)

    BL_BIN: 1        (drop-launcher, HEAD build)
    BL_BIN: 0        (drop — the pack tool does not need it)
    BL_DAEMON: 2     (control)

    drop: wrote …/bl-p1a — launcher 0.8 MB + payload 98.0 MB (gz), sha256 5c7222072c15…
    format: DRP1  offset=810104  len=102778098  sha256 5c7222072c15…  os=0 arch=0  total=103588258
    identical=YES                        (bl-p1a and bl-p1b, sha256 3daeccf6…)
    eval (+ 1 2) -> 3
    BL_BIN -> /home/user/.cache/bl-w0/p1/bl-p1a

Inside that drop, parsing its own file:

    P1f magic=DRP1 version=1
    P1f arithmetic: offset+len+56=103588258 == size true
    P1f launcher_bytes=810104 payload_bytes=102778098
    P1f sha256(payload) matches trailer: true
    P1f payload gzip magic: <<31, 139>>
    P1f other=/home/user/code/undefine/beam-lisp/bl magic=DRP1 offset=807112 len=102840725 consistent=true

This settles the design's central mechanism: `bl pack` recovers its own launcher
prefix from `BL_BIN` + its own trailer, and the arithmetic closes exactly. It
also parses the SHIPPED `bl` the same way, so `bl pack` works on the artifact
already in the field — provided the launcher is the HEAD build (the shipped one
predates `BL_BIN`; hence `--launcher FILE` stays mandatory in v1).

## P2 — the Elixir substrate, compiled in-drop

    BL_TREE=<tree> "$PAYLOAD/bin/bl" eval 'Code.eval_file("research/selfbuild/p2_parallel_compiler.exs")'

    P2  files=86 out=… mix_loaded=false parallel_compiler=true
    P2  RESULT ok modules=86 warnings=9 beams=86 ms=9902

Nine warnings, all the three guarded `Mix.*` sites plus one Elixir deprecation:

    lib/beam_lisp/generation.ex:23  Mix.env/0 is undefined
    lib/beam_lisp/application.ex:86 Mix.env/0 is undefined
    lib/beam_lisp/aot.ex:945        Mix.Project.compile_path/0 is undefined
    Kernel.ParallelCompiler: "you must pass return_diagnostics: true"

`lib/dev` and `lib/mix` are excluded by construction: `lib/dev` is the Tidewave
dev server, `lib/mix` defines Mix tasks and cannot even compile without Mix.
W4/W7 should pass `return_diagnostics: true` to silence the fourth warning.

## P3 — systools

    BL_PAYLOAD=<payload> "$PAYLOAD/bin/bl" eval 'Code.eval_file("research/selfbuild/p3_systools.exs")'

    P3  systools=…/lib/sasl-4.4/ebin/systools.beam
    P3  make_script ok warnings=0
    P3  script=…/bl.script exists=true bytes=160976
    P3  after make_script dir=["bl.boot", "bl.script", "bl.rel"]
    P3  script2boot=:ok boot_exists=true boot_bytes=110575
    P3  shipped start.boot bytes=112052 identical=false

`make_script/2` writes BOTH the `.script` and the `.boot`, with zero warnings,
using only the payload's `lib/` as the app path. `script2boot/1` takes the
extension-less stem (passing the filename makes it look for `<name>.script.script`).

## P4 — gzip

    {25, true, "hello"}     :zlib.gzip("hello") — 25 B, deterministic, round-trips
    {30, true}              gzip of a file, repeated → identical
    P1f: zlib.gzip of a 4 KiB slice — deterministic re-gzip: true

`:zlib` is preloaded in ERTS and callable with no app started. Usage note for
W5: gzip takes Erlang iodata. From beam-lisp, `erlang/apply/3` with a *byte list*
works (`binary_to_list`) while a beam-lisp string literal raised badarg even
though `is_binary` reports true — build the tarball bytes as a
`list_to_binary`/`iolist_to_binary` result and the call is clean.

## P5 — the hand-assembled release boots

    research/selfbuild/p5_handbuilt_release.sh <payload> <tree>
    research/selfbuild/gen_start_boot.exs

    P5  consolidated dir present? NO
    P5  BOOT OK elixir=1.20.2
    P5  42                                   BeamLisp.Ns.Bl.Cli.main(["eval","(+ 40 2)"])
    P5  eval exit=0

Everything but the boot script is reused verbatim from the shipped drop (lib,
ERTS, `bin/bl`, `sys.config`, `vm.args`, `env.sh`, `elixir`, `iex`,
`start_clean.*`). So the pass isolates exactly the part under test: a
`:systools`-generated boot script, in a tree with **no `consolidated/`**.

Confound ruled out: the generated `start.script` uses `$ROOT` (78 occurrences)
and embeds NO absolute path, so the tree booted from its own `lib/` — it is not
secretly reading the payload.

## P6 — the `mix release` diff, reconciled without a build

`mix release` and `make_script` produce the SAME structure: 40 `{path, …}`
lines, the same app set in the same order (kernel, stdlib, elixir, sasl,
beam_lisp, then alphabetical). Both scripts name the same apps; neither embeds
an absolute path. The entire difference is which boot variable a path uses:

| script | non-OTP apps | OTP apps | size |
|---|---|---|---|
| ours (`make_script`) | `$ROOT/lib/<app>/ebin` | `$ROOT/lib/<app>/ebin` | 160,976 |
| shipped (`mix release`) | `$RELEASE_LIB/<app>/ebin` | `$ROOT/lib/<app>/ebin` | 163,091 |

So W4's byte-identity step is: after `make_script`, rewrite the path line for
the project + its hex deps from `$ROOT/lib/<app>-<vsn>/ebin` to
`$RELEASE_LIB/<app>-<vsn>/ebin` before `script2boot` — the release's `bin/bl`
supplies that variable via `--boot-var RELEASE_LIB "$RELEASE_ROOT/lib"`.

A full byte-diff against `mix release` still belongs in W4, where an assembler
exists to compare; doing it here would mean a `deps.get` + full compile in this
worktree for no extra information.

## What these probes do NOT show

- `bl release` / `bl pack` / `bl self-build` do not exist yet — nothing was
  written outside `research/selfbuild/`.
- The `.app` synthesis for `beam_lisp` is untested: P5 reused the shipped `.app`.
- Protocol consolidation is confirmed NON-essential for booting; whether its
  absence costs measurable dispatch time is unmeasured.
- Cross-target packing (ERTS fetch/graft) was not exercised; P1 packed for the
  host with the release's own ERTS.
- The native tier (fjall / explorer / z3) was not exercised in a hand-assembled
  tree — P5 reused the payload's `priv/`, so the NIFs rode along by copy.

## W1 — the toolchain has two keys (landed)

**The change.** `priv/build/` now exists and holds the build driver — `build`,
`build-plan`, `source-graph`, `ns-interface` — moved out of `priv/boot/`, which
is now the CODEGEN tier alone (8 namespaces: reader, compiler, reader-node,
core, sugar, data-readers, anf, lower).

- `BeamLisp.Tiers` — `build_dir/1`, `build_namespaces/0`, `tier_of_ns/1`,
  `build_source?/1`, `toolchain_source?/1` (the union the barrier schedules).
- `BeamLisp.AOTCache` — `build_key/0` (driver sources plus `compiler_key/0`,
  since the codegen compiles the driver), `key_for_ns/1`, `key_for_source/1`,
  `key_for_tier/1`, `current_build_key/0`, `reset_keys/0`.
- The emitter stamps every beam with its TIER key; the runtime drift gate
  compares against the same function. `@gate_namespaces` is GONE — the tier
  directories say which namespaces the gate must tier-key, so the list cannot
  drift from the tree.
- The build manifest records the tier key per source; `fresh?` compares against
  `key_for_source(path)`.
- The serial barrier is now the TOOLCHAIN prefix (codegen ∪ driver):
  `partition-plan` returns `:toolchain`, `continue-after-toolchain?` gates it.
- The committed seed floors the CODEGEN only — 21 modules, down from 30. The
  driver is never seeded (see defect 1).

**Evidence** — `research/selfbuild/w1_amplifier.sh`, re-runnable and
self-cleaning:

| what | observed |
|---|---|
| manifest key per tier | boot/compiler.bl, boot/sugar.bl, std/errors.bl, lib/datom.bl → codegen `b6a47eb8…`; build/{build,build-plan,source-graph,ns-interface}.bl → driver `fff8a5a3…` |
| beam stamps | `Ns.Build` → `fff8a5a3…`, `Ns.Compiler` → `b6a47eb8…` |
| **the amplifier is gone** | adding a build-driver source: codegen key UNCHANGED, driver key moved to `4c3d22e0…`, ONLY driver-keyed sources went stale, and the build touched **5 sources** (before the split: every beam, ~300) |
| codegen edits stay conservative | adding a codegen source moved codegen to `32d07ec2…` AND the driver with it (the driver folds the codegen key in), so everything went stale — correct, and the opposite of the line above |
| leaves no trace | the probe file is deleted by its trap; both keys return to the baseline values; two consecutive `mix compile`s then report nothing to build |
| gates | 45/45 across aot_tier_key, boot_build_barrier, aot_build_key, aot_drift, aot_gate_cost, aot_cache, aot_reproducible, source_graph, bootstrap_adapter, bootstrap_generation |

**Full suite, attributed.** `mix test` on the W1 tree: 1509/1544, 3 invalid, 35
failed — and none of the 35 is W1's. 33 are `priv/z3/bin/z3` absent (gitignored,
so a fresh worktree has no solver at all and every z3-backed example dies at
server start; symlinking `priv/z3` — the way `deps` is already symlinked — closes
them, and `examples_test` then runs 226/229). The other 3 —
`examples/system/02_inductive_safety.bl`, `examples/veritas/03-the-mock-server.bl`,
`examples/semantic/13-entity-graph.bl` — reproduce IDENTICALLY on a pristine
worktree at `f90293b` (pre-W1: 214/217, same three, same reasons, same messages).
That comparison is what makes "no regressions" an observed fact instead of a
hope. Two further flakes appeared in the full run only (`TestVerbTest`,
`DaemonIntegrationTest`) and pass in isolation; both are cross-session
contention — another session's daemon held the UI port
(`{:taken, ... root: "/tmp/bl_dash_762"}`) and the CrossNode spike lost its
`:net_kernel` name to another node.

Baseline for the next waves: a cache-warm `mix compile` is **4m41s** on the
pristine tree and **7m54s** on this one. The split changes WHAT a build-tool edit
invalidates, not what a build costs — that is W2/W3's business.

**Two real defects found by doing this, both fixed.**

1. *A staged seed could install a previous-generation BUILD DRIVER.* The seed
then carried the driver, so a mismatched seed staged old driver beams; when a
shim/body pair spanned the generation boundary the build died with
`BeamLisp.Ns.Build."boot-source?"/1 is undefined or private` — the old body
calling a function the new shim no longer exports. Codegen floored from a
previous generation is a bootstrap (gen-N compiles gen-N+1); a driver floored
from a previous generation is a mixed toolchain pretending to be one. Fix: the
seed no longer contains the driver, and `Bootstrap.install!` refuses to stage a
build-tier namespace even if a seed offers one.

2. *`fresh?` could not see that a beam had been replaced.* `install!`
recreated a deleted driver beam from the seed, so the build found "every module
present + manifest key matches" → fresh → and never repaired the bytes. With
the driver out of the seed this specific loop is closed (demonstrated: delete
the 9 driver beams, `mix compile` rebuilds exactly 4 sources with the driver
key).

**W1-R1 (open, recorded, not yet fixed).** `fresh?` still checks only that each
module's beam EXISTS. A beam replaced out of band — a stale copy, a partial
extraction, a release tree assembled by someone else — is not detected, and the
build will call the source fresh while the bytes on disk are another
generation's. The AOT cache already keeps a sha256 per module, so the repair is
cheap and belongs before W5: record per-module digests in the manifest, and make
`fresh?` compare them.

