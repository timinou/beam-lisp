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


## W2 — the build's memory is a log of facts (landed)

**The change.** New driver namespace `priv/build/build-log.bl` plus its Elixir
call surface `BeamLisp.BuildLog`. The build's memory moved from ONE mutable
document (the manifest: a `term_to_binary` map rewritten after every source) to
an APPEND-ONLY LOG OF FACTS in the language's own data syntax, replayed into a
state. The manifest is now that state's projection, written once at the end.

```
[:build/run id at-ms]                              a build started
[:build/built path key tier [modules] cached?]     path is fresh under these keys
[:build/failed path reason]                        path did not compile
[:build/dropped path]                              path left the build
[:build/end id built errors]                       how the run ended
```

Queries, none of which a manifest could answer: `stale/3` (the build's own
worklist, in plan order), `impact/2` (everything an edit reaches — the reverse
closure of the plan's `:deps`), `coverage/3` (how much of the plan the log
accounts for).

**Why facts and not the manifest.** The old shape had three costs, and each is
now gone: it rewrote O(n) bytes to record one source (O(n) writes per build); an
interruption left a document that was neither the old truth nor the new one;
and it could only answer one question. A fact is written once and never edited,
so a build killed mid-wave resumes from the last COMPLETE fact — and the log
says what happened (compiled, cached, failed, dropped) instead of only what is.

**Observed.**

| what | observed |
|---|---|
| the log on disk | four lines of text for a two-source fixture: one `:build/run`, one `:build/built` per source, one `:build/end` |
| the real tree | `_build/dev/lib/beam_lisp/.mix/build.log`, 51 KB — ~300 sources, compacted |
| **resume** | delete the manifest: the next run is `{:noop, []}` and the projection is rewritten from the log |
| **agreement** | `read_manifest() == BuildLog.manifest(state)`, asserted |
| stale by query | after a body edit, `stale == [b.bl]` exactly (`a` is still fresh); `impact(a) == [b]`, `impact(b) == []` |
| a driver edit | 15 s to rebuild the 5 driver sources — W1's amplifier fix, used in anger |
| migration | a build directory with a manifest and no log: the source whose tier key is unknown rebuilds once, then warms |
| compaction | one `:build/run` survives (the last one); replaying never grows a history |

**Two things the probes caught** (both now comments in the module, because
whoever writes the next reader/writer will meet them):

1. `pr-str` is a VALUE printer — a string prints UNQUOTED, so a log written with
   it would not read back. The log carries its own four-line serializer.
2. A reader NODE is a tagged TUPLE (`{:vector [elem …]}`), so `vector?` is FALSE
   for it while `count`/`first`/`second` answer anyway. The first `read-facts`
   returned `[]` for a log that was plainly there, and the probe that printed
   `(vector? node)` → `false` is what found it.

**Contracts updated, because the truth moved** (the tests pin a property; the
property now lives one layer down):

- `test/beam_lisp/aot_build_key_test.exs` — the tier-key drift is forged IN THE
  LOG (a text edit — the log is text, which is the point), and a forged MANIFEST
  is asserted to change nothing, since it is a projection.
- `test/bl/build_test.bl` — a poisoned manifest now COSTS NOTHING (the run
  repairs the projection instead of rebuilding the world), plus new tests: `the
  log is the memory`, and `clean` removing both files.
- `test/beam_lisp/boot_build_barrier_test.exs` — the driver tier is five
  namespaces now (`build-log` joins it, so it is tier-keyed like its siblings).

**Validated.** 14/14 ExUnit across the three touched suites; 29/29 in the
driver's own `.bl` suite; the 12-suite build/AOT gate set green; `mix compile`
on the real tree still converges.

**One observed flake, attributed by probe.** `test/bl/system/linear_test.bl`
failed once (1 of 23, `the-old-self-apply-is-caught`) in the first run after
this change, then passed three runs in a row. The assertion is a pure function
of a literal source string, so `research/selfbuild/w2_probe5.bl` was run in BOTH
trees: identical output (`[{:local "inner-fn_3", :fn "self-apply", :placements
2}]`) and identical `check-source` results, from the same AOT beams. ∴ the
language decides the same thing in both trees and the failure is in the `.bl`
FORK runner (order/seed dependent — the same machinery whose seed-order flake
`examples_test` documents), not in this wave. Recorded rather than smoothed
over: 1 failure in 4 runs is the only evidence there is, and it is not enough
to claim a rate.


## W3 — the Elixir substrate compiles in-process (landed)

**The change.** `priv/build/substrate.bl` (driver tier, so tier-keyed like its
siblings) plus `BeamLisp.Substrate` as its Elixir call surface. `mix compile`
builds two things — the Elixir sources in `lib/` with mix's own `:elixir`
compiler, and the `.bl` sources with this project's task. The drop must do both
with no Mix project, no `_build` and no `MIX_ENV`; Elixir's compiler and
`Kernel.ParallelCompiler` ship in the payload (W0/P2 measured 86 modules in
9.9 s with Mix absent), so the substrate is just another STAGE.

- Facts: `[:build/ex path content-hash [module …]]`, in the SAME log as the
  AOT waves, so one replay answers for both.
- Freshness: the content hash — plus the recorded MODULE LIST, which is what
  makes a beam that vanished (or a half-extracted tree) pull its own source
  back into the build. That is W1-R1's hole, closed here by construction.
- Attribution: every compiled module reports the file it came from in
  `module_info(:compile)`. That is what lets the whole set compile in ONE batch
  (which is what the parallel compiler needs in order to resolve cross-file
  dependencies itself) and still record a fact PER FILE, so one edited file
  recompiles alone.
- `build/run` gained `:ex {:root "lib" :exclude ["dev" "mix"]}`; the stage runs
  BEFORE the `.bl` waves (a `.bl` source may call into it) and its errors are a
  REPORT, not a barrier. `:ex-built` is in the run's result.

**Observed** (`test/beam_lisp/build_substrate_test.exs`, and the driver's own
suite):

| what | observed |
|---|---|
| the project's own substrate | `lib/` minus `dev/`, `mix/` → every module, one fact per source, **no `Elixir.Mix.beam` in the output** |
| a second pass | compiles NOTHING (fresh by hash) |
| a body edit | exactly one file stale, one compiled |
| a deleted beam | its source is stale again — the hash alone would have called it done forever |
| a file that will not compile | reported with file:line, records NO fact, so it stays stale and the next run retries |
| integration | `build/run` with `:ex`: `:ex-built 1` then `0`, `[:build/ex …]` in the same log, one entry in the state's `:ex` |

**Three API facts the probes and the first failures earned** (all now comments):

1. `Kernel.ParallelCompiler` walks its file argument as an **Erlang list**; a bl
   vector is a struct, so handing it one dies inside the compiler's own
   `[file | queue]` clauses. `Enum/to_list` at that boundary.
2. The parallel compiler now **requires** `return_diagnostics: true` (the raw
   `{file, {line, col}, msg}` tuples are deprecated), and then an error is a
   `%Code.Diagnostic{}` — a MAP. `error-message` reads either shape.
3. The stage's root is the SOURCE root (`lib`), with exclusions RELATIVE to it —
   `**/*.ex` from the project root picks up `deps/` too (`deps/abnf_parsec`
   failed the first real run, from inside its own module body).

**Acceptance, honestly split.** G3 has two halves. *Produces the full ebin with
no mix* is MET for the stage: the whole `lib/` minus the two Mix-carrying roots
compiles in-process, and W0/P2 is the evidence that the compile needs no Mix
module at all (this test VM has Mix loaded, so the test asserts the artifact and
the absence of any Mix beam rather than the absence of the Mix module). *The
ExUnit suite passes against those beams* is a RELEASE-tree property — it needs
W4's assembly to be meaningful (a tree whose code path is the substrate's, with
no mix on it), and is scheduled there.


## W4 — the release is a value (FIRST HALF LANDED; assembly next)

**Landed.** `priv/build/release.bl` + `BeamLisp.Release` (Elixir call surface):

- `app-closure/1` — the transitive `:applications` closure of the root app (37
  apps for `beam_lisp`: OTP plus `_build` deps), each with its `.app` version
  and its `:code.lib_dir/1` directory, so no dependency file is read to know
  what a release must carry;
- `value/1` — `{:name :vsn :erts {:vsn :dir} :apps [{:app :vsn :dir} …]}`;
- `rel-text/1` / `write-rel!/2` — the `Name.rel` term, at
  `releases/<vsn>/<name>.rel` (where `systools` looks when told `:path`).

**Shaped against the mix-built drop** (`03cd2b3d/releases/0.1.0/bl.rel`), and two
of those shapes are not free choices:

| what | why it matters |
|---|---|
| Erlang SYNTAX: `{"bl","0.1.0"}` | strings, not binaries — my first version used `~w`, which prints a binary as `<<98,101,…>>`, i.e. a `.rel` nothing can read. Charlists + `~p` reproduce mix's output. |
| 3-tuples with a TYPE | `{kernel,"11.0.1",permanent}`; `none` is "carried but not started" (mix writes `iex` that way). `systools` reads it to decide what boots. |
| our closure ⊆ mix's set | mix also carries `:sasl` and `:iex`, which are nobody's `:applications` dependency. Neither is needed for a boot; a REPL-shipping release adds `iex` as `none`. |

The test parses OUR `.rel` back with `:erl_scan` + `:erl_parse` and asserts the
term equals the value, so the round trip through Erlang's own parser is the
assertion — not the string we hoped we wrote.

**Assembly recon (the recipe, gathered from the shipped drop, piece by piece).**
The shipped `bin/bl` is mix-generated; for `eval` it runs
`releases/<vsn>/elixir --cookie … --boot releases/<vsn>/<script> --boot-var
RELEASE_LIB "$ROOT/lib" --vm-args …`, and for `start` adds `--erl-config
<sys.config>` + `--erl "-mode embedded"`. What a tree needs, and from where:

| piece | source |
|---|---|
| `lib/<app>-<vsn>/{ebin,priv}` | the value's `:dir`s (with a priv include/exclude — the drop currently ships `priv/.spell/graph` and a stray `priv/env.bl`) |
| `erts-<vsn>/` | the value's `erts.dir` |
| `releases/<vsn>/<name>.rel` | `write-rel!` ✓ landed |
| `releases/<vsn>/{<name>,start_clean}.{script,boot}` | `:systools.make_script/2` → `script2boot/1`, with the `$ROOT`→`$RELEASE_LIB` rewrite for non-OTP apps before `script2boot` (W0/P3+P6: options `[{:path, [staging, libdir]}, {:outdir, staging}, :silent]`, `.rel` copied into the staging dir, `script2boot` takes the extension-less STEM) |
| `releases/<vsn>/elixir`, `iex` | PATCHED COPIES of Elixir's `bin/{elixir,iex}` (mix's are patched to release-relative paths) — a sub-task in itself |
| `releases/<vsn>/{sys.config,vm.args,remote.vm.args,env.sh}` | templates; `sys.config` is `[{logger,[{default_handler,[{config,#{type=>standard_error}}]}]}].` and the rest ship as comments plus env defaults |
| `releases/{COOKIE,start_erl.data}` | a cookie, and `"<erts-vsn> <vsn>"` |
| `bin/bl` | a launcher: mix's is ~190 lines of `sh`; a minimal one execs `releases/<vsn>/elixir` with the flags above |

**LANDED, and the gate is met — observed, not asserted.** `assemble/2` builds
the tree in the order the recon gave, and the tree runs:

```
$ /tmp/beam_lisp_release_tree/bin/bl version
beam_lisp 0.1.0
$ /tmp/beam_lisp_release_tree/bin/bl eval 'IO.puts("elixir=" <> System.version())'
elixir=1.20.2
$ /tmp/beam_lisp_release_tree/bin/bl eval 'BeamLisp.Ns.Bl.Cli.main(["eval","(+ 40 2)"])'
42
```

That `42` is the LANGUAGE running inside a tree where `assemble` generated every
piece — the `.rel`, both boot scripts, the ERTS tree, 37 apps, the templates, the
launcher. (`eval` is Elixir eval, which is what a mix launcher offers; the drop's
own language verbs are W9's.)

**Five traps, each earned by failing first:**

| what went wrong | the fix |
|---|---|
| `:systools` lives in OTP's `sasl`, and a `start_clean` VM has no `lib/sasl-*/ebin` on its path | the stage appends it from the ERTS root it is already copying from — `sasl` is a BUILD tool here, never a release dependency |
| `systools` answers `{:mandatory_app, :kernel, :none}` | `start_clean` is the same app set with only the MANDATORY apps permanent (kernel, stdlib, elixir); everything else is `none` — carried, not started |
| `File.cp_r!` creates the destination, not its parents | mkdir `erts-<vsn>/` before copying `bin` into it |
| `~w` prints a binary as `<<98,101,…>>` | `~p` with charlists, which is how `{"bl","0.1.0"}` gets written |
| **an unescaped `"` inside a bl docstring silently truncates the string** | escape it — the compiler then fails far away (`node_items("$")`), and what found it was compiling each top-level FORM separately (`/tmp/w4_bisect.exs` against a paren-split copy) |

**A claim I made and then FALSIFIED, recorded so it is not inherited.** I
hypothesised that a `defn` body may not begin with a vector literal, and wrapped
the launcher's line-vector in `(vec …)` on that theory. The error persisted, so
the wrapper was reverted and the bare vector re-tested: 25/25 top-level forms
compile. The theory is false, the wrapper is gone, and the only real cause was
the docstring quote above.

**One packaging fact handed to W10.** The tree carries
`lib/*/ebin/Elixir.Mix.Tasks.*.beam` — rustler's, rustler_precompiled's, and
beam_lisp's own compile task — because `copy-app!` copies the `ebin` as built.
They are dead in a release (no Mix) and vanish when the cutover deletes
`lib/mix`; the fix belongs to the wave that removes those sources.


## W5 — the compound codec (landed); the packer's byte dialect (read, not built)

**Landed.** `priv/build/drop.bl` + `BeamLisp.Drop`: `parse-trailer`,
`encode-trailer`, `compound`, `verify`, `target`, plus the streaming hashing a
launcher needs. A drop is `launcher ⊕ payload ⊕ trailer`, and the trailer is
self-describing — 56 bytes at EOF: `offset u64 LE`, `len u64 LE`, `sha256 32B`,
`os u8`, `arch u8`, `version u16 LE`, magic `DRP1`. Reading a 100 MB compound
costs a seek and 56 bytes; verifying it streams the payload through
`:crypto.hash_update/2` in 1 MB chunks.

| what | observed |
|---|---|
| **the acceptance, in one line** | the golden trailer of a real `drop pack` compound decodes to its fields AND re-encoding them gives the SAME 56 bytes |
| the real 103 MB compound | `BL_COMPOUND=…/bl mix test` → the streamed digest equals the digest the packer stored, and `offset+len+56` equals the file size |
| truncation vs corruption | a synthetic compound, cut and then corrupted: the cut fails the ARITHMETIC, the corruption fails the DIGEST, and each reports which |
| not a drop | random bytes → `nil`, never an exception (a launcher asks this of arbitrary files) |

**Three interop facts earned by failing** (all now comments):

1. `erlang/x/y` resolves as `:erlang."x/y"` — other Erlang modules take the
   BARE form (`binary/part`, `crypto/hash`, `file/pread`), which is what the
   rest of the tree already did.
2. **`count` on binary data is not its size**: a 56-byte trailer counts 55. Byte
   arithmetic uses `erlang/byte_size`; an off-by-N here is a wrong digest.
3. For a LITTLE-ENDIAN field the padding belongs at the END
   (`:binary.encode_unsigned/1` answers with the minimal width). Padding in
   front writes the number backwards — and the suite's self-consistency could
   never have caught it; only the packer's own bytes did.

**NOT DONE: `bl pack`.** `launcher recovery from BL_BIN`, the tar, the gzip and
`atomic install` are the rest of this wave, and the acceptance is byte-identity
with `drop pack` on the same tree. The dialect, read out of
`tooling/drop/src/pack.rs` (so the next step is transcription, not research):

- the walk is depth-first with `read_dir` SORTED at every level, files only (no
  directory entries); `rel` = the path relative to the release root;
- every entry is a **GNU** header (`Header::new_gnu`, magic `ustar  \0` at 257):
  `mode 0o755` for EVERY file (executables and data alike), `mtime 0`, `uid 0`,
  `gid 0`, empty uname/gname, real size, `set_cksum` — which is 6 octal digits,
  a NUL and a space, computed with the checksum field blanked;
- data is padded to 512, and `finish()` writes the two 512-byte zero blocks;
- gzip is `flate2`'s default compression (zlib level 6) — and the CONTAINER is
  where byte-identity will actually be won or lost: XFL and the OS byte in the
  gzip header come from the writer, not from deflate, so the honest route is to
  build the gzip envelope by hand (`:zlib.deflate` with `windowBits: -15` for
  raw deflate, then crc32 + isize) rather than to hope `:zlib.gzip/1` agrees
  byte for byte;
- `drop pack` takes `--launcher` (defaulting to `drop-launcher` next to the
  running binary) and `--target`, so a from-the-language packer can reuse an
existing launcher prefix and stay byte-identical for the other two thirds.

