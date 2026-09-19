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
