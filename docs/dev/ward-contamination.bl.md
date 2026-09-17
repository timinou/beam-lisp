# A test that passes alone and fails in the suite

> This is a **literate program**. Every `beam-lisp` block below runs:
> `bl run docs/dev/ward-contamination.bl.md`. The prose is the narrative; the
> code is the proof.

Some tests pass on their own and fail in the suite. The failure moves when you
reorder the files, and it is never the tested code's fault: a file's answer was
computed from state the file did not create. BUG-041 is that class — six suites
of the tree disagreed with themselves depending on what ran before them.

Isolation was the cure (each file forks the var registry, runs in its own
worker process, and the analyzer's memos are keyed by env). **This walkthrough
is the instrument**: `bl test --diagnose` looks at the surfaces a fork does not
own, and says — by name — what crossed.

```beam-lisp
(ns guide.ward-contamination
  (:require [reload.ward :as ward] [reload.ward-diag :as wd] [env]))
```

```bl-result cell0
:guide.ward-contamination
```

## The shape of the leak

Three things outlive one test file, and each needs a different fix:

| surface   | what a fork does not own                        | the fix pattern |
|-----------|--------------------------------------------------|-----------------|
| `mailbox` | the process that runs it: `receive` sees every message in that queue | **narrow the receive**, or run the file in its own process (ward does) |
| `os-env`  | `System/put_env` is one table for the whole node | snapshot and restore it around the file (ward does) |
| `<memo>`  | a VM-global cache (`lsp/analyzed`, `lsp/diagnostics`, …) | **memo key discipline**: put the env id in the key |

The ledger watches all three at every file boundary. A finding names the
surface, the file it was observed under, and the key — what a reader needs to
go look.

## A deliberate contamination, named

Two files: one minds its business, one sends the *runner* a message the runner
did not send itself. That is the mailbox half of BUG-041, made deliberate.

```beam-lisp
(def quiet
  "(ns guide.quiet)\n(deftest ok (is true))\n")

(def noisy
  "(ns guide.noisy)\n
   (let [r (reload.ward-diag/runner)]\n
     (when (some? r) (erlang/send r [:ward-diag-probe 1])))\n
   (deftest ok (is true))\n")

(wd/clear!)
(ward/run (list quiet noisy) (wd/observer))
(println (wd/report))
```

```bl-result quiet

Testing guide.quiet

Testing guide.noisy
── ward: contamination ledger ──

  ⚠ mailbox     guide.noisy — the runner received a message it did not send: [:ward-diag-probe 1]

  2 file(s) watched, 1 warning(s)
:ok
```

The warning names the surface (`mailbox`), the file (`guide.noisy`), and the
message itself. `guide.quiet` is not mentioned, because nothing crossed under
it — a ledger that blamed every file would be noise.

## A clean run says nothing

The same boundaries, with nothing to report. This is the property that makes
the instrument usable in CI: no warnings, no output.

```beam-lisp
(wd/clear!)
(ward/run (list quiet) (wd/observer))
(println "clean run prints:" (wd/report))
```

```bl-result cell2

Testing guide.quiet
clean run prints: nil
:ok
```

## The memo half: it is all in the key

lsp memoized an analysis under `[sha256]`. Two forks analyzing the same bytes
therefore shared one slot, and the second fork read the first fork's *dirty*
bundle — the 0 → 6 phantom diagnostics of BUG-041. The fix is not a lock or a
flush; it is the key carrying the env that wrote it, so a fork can only ever
hit its own entry.

The ledger can see the difference. Here is the pre-fix shape, keyed by the
source alone:

```beam-lisp
(wd/clear!)
(def pre-fix (atom []))
(wd/register! "demo/analyzed"
              (fn [] (map (fn [p] {:key (get p 0) :owner nil}) (deref pre-fix))))
(wd/watch! {})
(wd/file-start! "guide.one")
(swap! pre-fix conj [["d43be878…"] :a-bundle])
(wd/file-done! "guide.one")
(println (wd/report))
```

```bl-result pre-fix
── ward: contamination ledger ──

  ⚠ memo        guide.one — demo/analyzed key d43be878… carries no env-id; any fork can read it

  1 file(s) watched, 1 warning(s)
:ok
```

`any fork can read it` is the whole failure in five words: the key carries no
env, so the entry belongs to no one and to everyone. Add the env id — what
`priv/lib/lsp.bl` now does — and the same write becomes ordinary:

```beam-lisp
(wd/clear!)
(def scoped (atom []))
(wd/register! "demo/analyzed"
              (fn [] (map (fn [p] {:key (get p 0) :owner (get p 1)}) (deref scoped))))
(wd/watch! {:deep true})
(wd/file-start! "guide.one")
(env/isolated (fn [] (swap! scoped conj [[(env/id) "d43be878…"] (env/id)])))
(wd/file-done! "guide.one")
(println (wd/report))
```

```bl-result scoped
── ward: contamination ledger ──

  ✓ no state crossed a file boundary

  watched surfaces:
  demo/analyzed   1 entry  env-scoped: e1
      e1 d43be878…

  memo writes this run:
  · guide.one wrote demo/analyzed e1 d43be878…  (e1)

  1 file(s) watched, 0 warning(s)
:ok
```

The write is still *recorded* (deep mode names the key each file wrote, and
whether the key is env-scoped), but it is not a warning: the scope is what
keeps it out of every other fork.

## Running it on your own suite

```
$ bin/bl test --diagnose test/fixtures/ward/leaker.bl test/fixtures/ward/bystander.bl
── ward: warm isolated test run ──

  ✓ fixtures.ward.leaker  0 passed
  ✓ fixtures.ward.bystander  1 passed

  2 file(s) passed, 0 failed, 0 incoherent
  ✓ all green
── ward: contamination ledger ──

  ⚠ mailbox     fixtures.ward.leaker — the runner received a message it did
                 not send: [:ward-diag-probe 1]

  2 file(s) watched, 1 warning(s)
```

`--deep` adds the watched surfaces, every key they hold, and the keys each file
wrote (`lsp/analyzed  4 entries  env-scoped: e1`, …). `--json` puts the same
findings in the report under `:contamination`, so a CI gate can read them
without parsing prose. Without `--diagnose` the ledger is not even loaded and
costs nothing.

`--diagnose` uses the isolated runner, so it refuses `--shared` / `--async`:
the concurrent runners share one process, and there is no per-file boundary to
observe.

## Where this lives

- `priv/std/reload/ward_diag.bl` — the ledger: surfaces, boundaries, findings.
- `test/bl/reload/ward_diag_test.bl` — a contaminated run is named, a clean run
  is silent, an env-less key warns, an env-scoped write does not.
- `test/fixtures/ward/leaker.bl` — the deliberate contamination (inert unless a
  ledger is watching), with `bystander.bl` as the control.
