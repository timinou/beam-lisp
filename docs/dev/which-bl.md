# Which `bl` am I running?

There are two of them in a checkout, they run **different code**, and nothing
about the command line tells you which. This has cost a session hour, twice, so:

```
./bin/bl      the checkout          lib/*.ex → compiled on demand (or by `bl build`)
                                    priv/std/*.bl → AOT-compiled on demand, FROM SOURCE
                                    priv/lib/*.bl → from source

./bl          the shipped DROP      a 143 MB self-contained ELF at the tree root.
                                    Its image has the std PRE-COMPILED to beams.
```

## The half-and-half that makes it confusing

In the drop, the two source trees behave **differently**, and that is the trap:

| you edit … | under `./bl` (the drop) | under `./bin/bl` (the checkout) |
|---|---|---|
| `priv/std/bl/env.bl`, `bl/cache.bl`, `bl/cli.bl` … | **INVISIBLE** — the drop carries beams for these (`Elixir.BeamLisp.Ns.Bl.Env.beam`, `…Bl.Cache.beam`, `…Bl.Cli.beam`, …) | visible: AOT-compiled from source on demand |
| `priv/std/vm/*.bl`, `priv/std/proc/*.bl` | visible — no beam for these ships in the drop | visible |
| `lib/**/*.ex` | INVISIBLE unless the drop was rebuilt | visible once `bl build` has compiled them |

So an edit can appear to work — and an edit to the *other* half of the same
change can appear to do nothing. Measured (2026-09-18): the `:schedules` cutover
(P4) was exercised under `./bl` and the pane's numbers did not move, because
`bl.env`/`bl.cache` are compiled into the drop; the same sources under `./bin/bl`
were correct immediately.

## The rule

* **In a checkout, use `./bin/bl`.** It is the tree you are editing. This is the
  launcher every verification in this repo's docs should name.
* **`./bl` is for running the shipped drop** — a user's machine, a release, a
  reproduction on a machine that has no checkout. If you are debugging a checkout
  with it, you are debugging a build from some earlier day.
* `BEAM_LISP_EBIN=…` points a checkout at another job's beams (CI). It does not
  make the drop see your sources.

## Two lines in the output, decoded

```
bl: the committed compiler floor was built by another toolchain
    (compiler_key_mismatch); using it to rebuild
```

Not an error. This checkout has no usable floor for its current toolchain, so the
committed one is installed first and the tree rebuilds — a one-time cost per
toolchain change, and the reason a "sudden" cold cache is normal after anyone
edits `priv/boot/*` or the compiler.

```
bl: the Elixir half is STALE — <file> is newer than the newest beam in <ebin>
```

`bin/bl`'s own guard (added for this reason): the `.bl` half AOT-compiles itself
on demand, but the Elixir half does **not** — only `bl build`'s `:ex` stage
compiles `lib/*.ex`. Without the guard the symptom is a fix that "does nothing",
which reads exactly like a fix that does not work. Run `bl build`, or set
`BL_NO_STALE_CHECK=1` when you know why it is stale.

## Why this matters for anything shipped

An installed drop is a *snapshot of a generation*, and a snapshot can be older
than the checkout that produced it. That is the same shape as the reload
question (`FUP-084`, `BUG-048`: the tier key moved and the beams did not), and
it is why `FUP-108` treats "which generation am I running?" as a fact the tool
should be able to state rather than a thing a person infers from silence.

## When nothing boots: a working toolchain in four steps

Seen 2026-10-17: every checkout (pristine `main` included) died at boot with
`invalid_source_kernel_abi` / `stale_sdk_bootstrap_inventory`, and an installed
drop died with `undefined var: compiler/special-forms`. Three separate causes
looked like one. Do not edit `priv/host/*` to "diagnose" — changing a host leaf
changes the source key and turns every following run into a stale-floor error.

1. **Never write into an installed drop.** `~/.local/share/drop/<id>/` is
   read-only by contract. A worktree whose `.bl/lib/beam_lisp-0.1.0/ebin` is
   linked into a drop's `ebin`, or a debug script with `{:output_dir …}` into
   it, overwrites the drop's boot beams. Repair: copy the drop's own
   `priv/bootstrap/seed/<Module>.beam` back over each differing
   `ebin/<Module>.beam` (compare with `cmp`), and check
   `find <drop> -newer <drop>/BUILD_INFO.bl -name '*.beam'` is empty.
2. **Boot from a commit whose floor matches its host source.** If `main`
   refuses, use the newest commit that boots: try it in a scratch worktree
   (`git worktree add --detach … <sha>`), copy the ignored assets
   (`priv/native/`, `priv/z3/`) from a working checkout, and run with an
   isolated cache (step 3). Then cherry-pick or merge onto it.
3. **Isolate the AOT cache per experiment.** `XDG_CACHE_HOME=$HOME/tmp/bl-xdg-<name>`
   with `beam_lisp/{ebin,lib,native}` copied from `~/.cache/beam_lisp` (the
   compiled dependencies; without them boot dies with `x509.app` missing). Leave
   `aot/` empty: it is rebuilt from source. Never delete shared `~/.cache/beam_lisp/aot`
   entries to "clean" — other trees' beams live there too.
4. **Change host or boot source, then regenerate the floor once, at the end,**
   from the tree itself:
   `BL_BOOTSTRAP_OUTPUT=… ./bin/bl run scripts/regenerate-seed.bl`, then
   `BL_BOOTSTRAP_SEED=…/seed ./bin/bl run scripts/install-seed.bl`, then
   `./bin/bl seed --check`. Before that, host-leaf changes are tested in a child
   VM against beams compiled from the current source
   (`test/bl/namespace_readiness_fast_path_test.bl` shows the pattern).

Run one warm VM for a whole round of focused tests instead of a cold `bl` per
command: `bl serve` a small driver that evaluates one form per TCP line and
CLOSES the socket after replying (a server that forgets to close makes every
client hang after the answer).

## Check runtime host changes quickly

For runtime changes in `aot.bl`, `env.bl` and `lazy_memo.bl`, use
`scripts/check-runtime-hosts`. It uses two sequential, memory-capped VMs:
one compiles changed hosts with the existing compiler, and the other tests
the edited runtime, including the LazyMemo NIF. The compiler source snapshot
stays fixed; the AOT overlay loads after bootstrap. Use these checks for
runtime behavior and a complete floor rebuild for compiler qualification.

Before editing a tree whose floor matches its current sources, save the
bootstrap inputs:

```sh
mkdir -p .local/host-bootstrap
cp priv/host/aot.bl priv/host/env.bl .local/host-bootstrap/
```

Then edit and run focused tests:

```sh
scripts/check-runtime-hosts \
  --bootstrap-hosts .local/host-bootstrap \
  --work-dir .local/host-check \
  test/bl/perf/spawn_cost_test.bl test/bl/lazy_clean_capture_test.bl
```

Omit test paths to run the focused runtime regression set. Unchanged host
beams are reused across runs; tests share one VM and each file has a 120-second
ceiling. Use `--suite-timeout SECONDS` for a longer check. Empty results,
failed assertions and timeouts fail the command.

The checker keeps its image, cache, fixtures and manifest in its private work
directory. Dependencies come from the configured XDG cache. When `HEAD`
contains the seed-matching host sources, `--bootstrap-hosts` is optional.
After runtime checks pass, regenerate and qualify the real floor once.
