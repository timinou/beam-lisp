# Realms: one warm VM per user and build

> Design. What the machine looks like when every bl process you run is a
> thing you can see, name, and stop — and what a *project that is alive* is
> called.

This folder is the map. Read this file; open the others when you need the
territory.

## The picture, in one screen

```
 DECLARES   project   env.bl + .env.local.bl                  on disk
 CODE       build     an immutable drop (ed7cf863)             on disk
 ─────────────────────── the OS boundary ───────────────────────────────
 CONTAINS   vm        one beam.smp · one build · one role      a process
 ─────────────────────── the in-process boundary ───────────────────────
 ISOLATES   realm     a project, alive inside a vm             env + members
 DOES       member    a run · an app · a repl · a schedule     a process
 ─────────────────────── the wire ──────────────────────────────────────
 REACHES    route     a name → a port                          a claim file
```

Five nouns, each answering one question:

| noun | question it answers | where its truth lives |
|---|---|---|
| **vm** | what is *running on this machine*? | one registry record per VM |
| **realm** | what is *my project doing*? | the in-VM table (`realm.manager`) |
| **member** | what *work* is in flight? | the owner registry |
| **route** | how do I *reach* it? | a claim file per name |
| **build** | which *code* is it? | an immutable directory |

## The one rule that keeps the CLI small

> **`bl realm` is about the project in front of you. `bl vm` is about the
> machine.**

```
bl realm            this project's realm: address, routes, members
bl vm               every VM on the machine, with the realms inside each
```

Everything else is a verb on one of those two nouns. See [`commands.md`](commands.md).

## Why one VM per user per build

A BEAM node loads each module once. Two builds cannot share a node, so *build*
is part of a VM's identity. Nothing else is: a user's projects are realms
inside the VM of the build they run, isolated from each other by an `env`
fork, not by an OS process.

- **Cheap.** One ~200 MB node instead of one per checkout.
- **Warm everywhere.** A scratch directory with no `env.bl` gets a realm, not a
  cold start.
- **Easy to track.** `bl vm` has one row per build, not one per tree.
- **Honest about the cost.** A native fault or a runaway allocation reaches
  every realm in that VM. [`caveats.md`](caveats.md) says how that is bounded,
  and what is not.

## The documents

| file | read it for |
|---|---|
| [`vocabulary.md`](vocabulary.md) | each noun in full: what it is, what it is not, its lifetime, when to reach for it |
| [`architecture.md`](architecture.md) | the layers, the registry record, liveness, the data flow for a command |
| [`commands.md`](commands.md) | every verb, its flags, its output, its exit codes |
| [`console.md`](console.md) | the `bl vm ui` machine page: views, actions, the design rules it follows |
| [`security.md`](security.md) | the trust model: who may stop what, and why the page cannot be turned on you |
| [`caveats.md`](caveats.md) | what breaks, what is not yet true, what to watch while building it |

The build order is the PLAN in `!tasks/plans/`. This folder says what the
system *is*; the plan says how to get there.

## What exists today, and what does not

Written down so nobody has to guess:

| exists and is used | `vm.manager`, `vm.core`, `vm.owner`, `vm.scope`, `vm.osenv`, `vm.spec`, `vm.net`, `vm.wire`, `vm.ports`, `vm.gateway`, `vm.http` |
| exists, not yet true | many realms in one VM. Requests already route to a realm by directory, but the index, the root and the page are bound to *one* root at boot |
| new in the first slice | the VM registry, the inventory, `bl vm`, `bl realm`, the machine page |
