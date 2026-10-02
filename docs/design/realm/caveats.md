# Caveats

What breaks, what is not yet true, and what to watch while building the rest.
Each item says **how we know** (measured / read in source / inferred), because a
caveat nobody can check is a rumour.

## 1. Many realms in one VM is designed, not yet true

**Known (read in source).** A request already routes to a realm by directory:
`bl.daemon/handle-in-vm` calls `spec/read cwd`, then `mgr/ensure`, then
`mgr/run`. So one VM *can* host several realms.

**Not yet true.** Boot is single-root. `vm.session/start` calls
`(index/start {:root root})`, stores `root` in `PT-ROOT`, and calls
`(start-ui root)` — all bound to the *one* root the VM was started for. The
launcher also keys the warm VM by **tree**, not by (user, build).

**What has to change, in order:**

| singleton today | becomes |
|---|---|
| `PT-ROOT` (`persistent_term`) | a per-realm table in `vm.manager` |
| `index/start {:root}` | one index per realm, started on `ensure` |
| `start-ui root` | one console per VM; per-realm pages under it |
| `sched/start-for` | already per-VM-spec: verify it is idempotent per realm |
| socket name `<tree>-<build>` | `<user>-<build>`; the realm is a request field |
| launcher `resolve_root` | send `cwd`; the VM resolves the realm |

**Watch for.** Anything stored in `persistent_term` or a named process in a
`vm.*` namespace is a singleton. Grep for it before declaring a namespace
realm-safe.

## 2. Blast radius

**Known.** One VM hosting many realms means a native fault, an out-of-memory
kill, or a runaway allocation takes every realm in that VM with it.

**What bounds it.** An env fork carries `:max-heap-words`, and `vm.scope` denies
`System/halt`. **Not verified:** what the heap cap bounds — per process or per
realm — or that a runaway *member* cannot starve the scheduler. This must be
measured before one-VM-per-user is the default.

**Mitigation if it bites.** `bl vm start --isolated` for a project that needs its
own OS process. The nouns do not change; that realm just gets its own VM.

## 3. The VM is not an isolation boundary for code

**Inferred (not tested).** A BEAM node loads each module once, and
`vm/generation.bl` documents its hotpatch set as process-global. So an env fork
isolates *names and capabilities*, not *code*: two realms cannot run different
versions of a module. That is why **build is part of a VM's identity**, and why
a project that pins a different build gets a different VM.

## 4. Existing warm VMs are invisible without adoption

**Measured.** On this machine two warm VMs from before the registry were running
(one for 2½ days). Listing only records would have shown an empty machine.
`vm.inventory` therefore adopts live `.meta` files, port-claim owners and the
gateway endpoint as `:legacy` rows.

**Cost.** Adoption has no start ticks, so it cannot prove a pid was not reused.
Stopping an adopted row requires its command line to say `beam.smp`. Delete the
adoption path once no legacy VM remains.

## 5. Memory figures lie unless swap is counted

**Measured.** `VmRSS` was 36 MB for a VM whose `VmSwap` was **7.0 GB**; another
read 8 MB with 237 MB swapped. The listing sums both. **Caveat:** that includes
memory the kernel may have compressed to zram, so the figure is *what the VM
holds*, not *what it costs in RAM right now*.

## 6. Test harness

**Measured.**

- `vm.owner` defines a `defserver` with the `(registry …)` clause. Under the
  **ward-isolated** test run (the default) that clause is not registered in the
  forked VM, so any test that starts a warm VM session fails with
  `unknown clause registry`. Under `--shared` it passes. This is **pre-existing**:
  `session_test.bl` fails the same way on unmodified HEAD. New tests that start a
  session therefore run with `--shared`.
- `test/bl/vm/http_test.bl` has a **pre-existing** alternating failure on
  `GET /` (two assertions, every other run), identical on unmodified HEAD.
- `re-find` and `re-pattern` are not in scope inside `vm.*` namespaces; use
  `:re` directly.
- `bl.json` is not loaded for you in a namespace reached on its own; `(:require
  [bl.json])` explicitly. `vm.http` calls it without requiring it and works only
  because something else loaded it first.

## 7. Fresh worktrees do not boot in source mode

**Measured.** A new worktree of `main` fails to boot: `bl native build` itself
needs the `lazy_memo` NIF it is meant to produce. Copying the `.so` files from a
checkout with identical `native/` sources into `priv/native/` (gitignored) fixes
it. This is a bootstrap problem independent of this design, and it costs the
first hour of anyone's first worktree.

## 8. Things that are inherently racy

- **Two starts for one endpoint — measured: the second one wins, silently.**
  `vm.net/listen` runs `(File/rm sock-path)` *before* it binds. Calling it twice
  for the same root in one VM returned `{:ok …}` **both times**, left both accept
  loops alive, and the path now reaches the *second*. The first keeps running and
  is unreachable by name. The only guard is `client/start-foreground`'s probe,
  which is a check followed by a bind, not atomic.
  - Three simultaneous `bl realm start` for one root produced one warm VM (the
    probe happened to serialise them; the other two died loading modules while the
    first was compiling). Not proof the probe is sound — only that it held there.
  - **Fix before auto-start ships:** bind first and treat `eaddrinuse` as "someone
    else won"; or take `<base>.start` (already named in `vm.paths/endpoints`) with
    `O_EXCL`. Auto-start turns this from rare to routine.
- **`prune` against a VM that is starting.** Handled: a group is swept only when
  its socket accepts nobody **and** its meta names no live pid. *Tested.*
- **A pid reused between `rows` and `stop!`.** Handled by start ticks. *Tested.*
- **A VM that stops itself while `stop` is waiting.** The poll treats
  "no longer live" as success. *Tested.*

## 9. The console

- It is mounted on a **session** VM's HTTP server, so it lives and dies with that
  VM. If that VM is the one you stop, the page goes away. The target hosts it in
  the gateway.
- It polls nothing yet: it is a snapshot with a reload on action. Live updates
  need server-sent events or polling and a no-layout-shift diff.
- The page cannot tell you *why* a VM is using 7 GB. It shows the number.

## 10. Impeccable

**Measured.** `impeccable detect` on the new page: **0 findings**. On the old
dashboard it found 8 (7 warnings, 1 advisory). **Caveat:** the detector covers
61 rules and says itself that a clean scan is not a design review. Contrast was
computed separately (WCAG AA, both themes: lowest body-text ratio 6.48:1,
muted text on a tinted row). `detect` needs Node and a browser, so it can be an
optional check, never a hard gate in `bl test`.
