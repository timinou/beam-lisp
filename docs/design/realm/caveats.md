# Caveats

What breaks, what is not yet true, and what to watch while building the rest.
Each item says **how we know** (measured / read in source / inferred), because a
caveat nobody can check is a rumour.

## 1. Sharing a VM: what is isolated and what is not

**Built.** A shared VM boots with no project. Each request carries its working
directory; the VM finds the project (`bl.env/find`) and opens its realm on the
first request, once, however many requests arrive together (the manager decides
which caller created it). A realm has its own env fork, its own index owner and
its own declared schedules. `bl realm stop` closes one realm and leaves the VM
and every other realm running.

**Isolated (measured).** Two projects answer from their own working directory;
twelve concurrent requests with different environments each saw only their own;
closing one realm left the other's index owner the same process.

**Not isolated (measured).** *Code.* Two projects that define a namespace of the
same name get one namespace: the second sees the first one's. *Environment.* A
project's `:env` is written into the node's OS environment by `bl.cli/with-project`,
so a process that never bound a project reads the last one's values. These are
why sharing is a project's declaration, not the build's default. Fixing them means
making namespace publication and project binding realm-local (FUP-151).

**Not built.** One console with a page per realm. A shared VM starts no dashboard,
because the dashboard's pages read one root.

**Watch for.** Anything stored in `persistent_term`, an ETS table or a named
process in a `vm.*` namespace is a singleton. Grep for it before declaring a
namespace realm-safe. `vm.exec`, `vm.repl` and `vm.gateway` still are.

## 2. Blast radius

**Known.** One VM hosting many realms means a native fault, an out-of-memory
kill, or a runaway allocation takes every realm in that VM with it.

**What bounds it, measured.**

- `:max-heap-words` is a **per-process** limit (OTP `max_heap_size`), not a
  per-realm quota. Twelve members of about 5 MB each lived under an 8 MB cap. The
  total a realm holds is unbounded.
- A member that outgrows the cap is killed at once; its siblings and the owner
  registry are untouched.
- Eight busy-loop processes on four schedulers did not delay a sleeping process
  (21 ms): the scheduler preempts by reductions.
- `vm.scope` denies `System/halt`.

**Not bounded.** Aggregate memory, ETS tables, binaries, NIF memory, the atom
table, file descriptors and process count. The default `:caps :all` also grants
the node's halt.

**If it bites.** Leave `:vm` unset: the project keeps its own VM.

## 3. The VM is not an isolation boundary for code

**Measured.** A BEAM node loads each module once. An env fork isolates *names and
capabilities*, not *code*: two projects cannot run different versions of a
namespace in one node. That is why **build is part of a VM's identity**, and why a
project that needs different code needs its own VM.

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

- A namespace that uses a `defserver` clause (`(registry …)`) must require the
  namespace that registers it **bare** as well as aliased: an aliased require is
  demand-driven, so the clause is not registered when the `defserver` compiles
  (`unknown clause registry`). `vm.owner` and `live.app` do.
- The dashboard's first render takes about 5 s (it builds the model). A test that
  waits less reads the timeout as a failure; the console tests wait 30 s.
- A qualified call `alias/name` whose `name` is also a core name (`count`, `get`,
  `first`) compiles to the core function when the alias's namespace is not yet
  loaded: `(owner/count id)` answers the length of the id string (BUG-111). Until
  the compiler is fixed, call `(count (owner/procs id))`.
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
