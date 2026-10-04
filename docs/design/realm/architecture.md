# Architecture

How the nouns are stored, found, and kept honest.

## One truth per noun

Two things describing one VM is how a machine ends up with ghosts. Each noun has
exactly one source of truth, and everything else is *derived and read live*.

| noun | stored in | written | removed |
|---|---|---|---|
| vm | `<runtime>/vms/<id>.rec` | once, when the VM starts | by the VM, on a clean stop |
| realm | `vm.manager`'s table, inside the VM | on first command | on `drain` |
| member | `vm.owner`'s registry, inside the VM | on spawn | on the process's death (monitor) |
| route | `<runtime>/ports/<name>[@tree]` | when an app claims | on release, or swept when its owner is gone |
| build | the drop directory | at install | by GC when nothing runs it |

`<runtime>` is `$XDG_RUNTIME_DIR/beam_lisp` (0700), else `/tmp/beam_lisp-<uid>`.

## The VM record

```
{:id      "a238fa91-4821"     build + OS pid
 :role    :warm | :gateway | :job
 :build   "a238fa91"          "src" for a checkout
 :pid     4821
 :ticks   129411400           /proc/<pid>/stat field 22
 :started 1790000000
 :label   "blueprint"
 :log     "/…/vm.log"}
```

Everything that *changes* — memory, uptime, realms, routes — is read live. The
record holds only what is true for the VM's whole life, so there is no update to
race and nothing to go stale except the VM's own existence.

### Liveness is a pair, not a pid

A machine that has been up for a week reuses pids. A record naming pid 4821 may
now describe an unrelated program. So a record is live when **the pid exists
and began when the record says** (`:ticks`). The kernel's start time for a pid
never repeats for a different process.

Rows adopted from older files have no ticks. For those, the pid existing is the
only check, and **stopping them additionally requires that the command line says
`beam.smp`** — never signal something that is not provably a BEAM node.

Where `/proc` is absent (non-Linux) a record is *respected*, not swept:
refusing to clean up is recoverable; stopping the wrong process is not.

### Memory counts swap

`VmRSS` alone lies. A VM idle for hours had **8 MB resident and 237 MB swapped**
on this machine; another showed **36 MB resident and 7.0 GB swapped**. A listing
that says "8M" tells a person it is free to keep. The figure is resident **plus**
swapped.

## The inventory join

`vm.inventory` joins the sources into one tree. It reads; it never writes except
`stop!` and `prune!`, which say so.

```
registry records ─┐
.meta files ──────┼─▶ VM rows ──▶ + realms (roots from .meta and claims)
gateway endpoint ─┤              + routes (claims, URL resolved once)
port-claim owners ┘              + memory, uptime (live)
```

### Adoption: the road from today to the registry

A VM that started before the registry has no record. Listing only records would
make every running warm VM **invisible the day this ships** — the opposite of the
goal. So a live `.meta`, a live port claim, and the gateway endpoint each *adopt*
their pid as a row marked `:legacy`. It is listed, it can be stopped, and it
becomes an ordinary row the next time that VM starts. Adoption is the migration
path; once no legacy VMs remain it can be deleted.

### Attention

Only concrete problems, each stating a fact and the command that resolves it:

| fact | fix |
|---|---|
| names are claimed and no gateway answers | `bl vm start gateway` |
| files from VMs that are gone | `bl vm prune` |
| a warm VM runs a different build than this command | `bl vm stop ID` |
| VMs started before the registry | restart them |

There is deliberately no health score.

## Stopping: a ladder, never a guess

```
1  ask      the VM's own control socket, once per root it serves
            → it drains its realms and removes its own files
2  TERM     if still running AND provably a bl node (ticks, or beam.smp)
3  KILL     only with --force
```

A VM **never stops the VM it is running inside** — that would cut the command off
mid-answer. A query that matches several VMs is an error that lists them; it
stops none.

To reach a VM on a *different build*, the client names that build in the hello
and dials that build's endpoint (`<tree>-<build>.sock`). A warm VM rejects a
client that expects another build with `restart_required`, so naming it is not
optional.

## Pruning

Removes only what belongs to VMs that are gone:

- registry records whose VM is not live;
- `.sock/.token/.meta/.pid` groups where **the socket accepts nobody and the
  meta names no live pid**. Both conditions, so a warm VM mid-start (socket not up
  yet, pid alive) is never swept.

Port claims are swept by `vm.ports` as it reads them, so they need no pass.
`--dry-run` lists and removes nothing; reading never mutates.

## A command's path (today, and in the target)

```
bl <cmd> ──▶ launcher ──▶ warm VM for (user, build)? ──yes──▶ realm for cwd ──▶ member (run)
                              │ no
                              └─▶ run cold; start the warm VM in the background
```

Today the launcher keys the warm VM by **tree**, so `(user, build)` is the
*target*. See [`caveats.md`](caveats.md) for what has to change before one VM can
host many realms.

## The console

The page and `/api/vms` render the same rows as `bl vm`. They are mounted on the
existing session HTTP server (`/machine`), with their own Host guard and token
check (see [`security.md`](security.md)). The first slice mounts them there; the
target hosts them in the gateway, which outlives every VM and can see every
token.

## Namespaces

| now | role |
|---|---|
| `vm.registry` | the record: publish, retract, liveness, sweep |
| `vm.inventory` | the join: rows, attention, resolve, stop, prune |
| `vm.machine` | the page and API, with the Host and token guards |
| `bl.vm`, `bl.realm` | the verbs |

The existing `vm.*` namespaces that really mean *realm* (`core`, `owner`, `scope`,
`osenv`, `spec`, `manager`, `sched`, `index`, `repl`, `inspect`) are renamed
**last**, mechanically, once behaviour is settled.
