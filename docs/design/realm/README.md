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

## One VM per project, or one VM shared

A BEAM node loads each module once, so *build* is part of a VM's identity: two
builds are two VMs. What else belongs to its identity is the project's choice.

| the project says | the VM is |
|---|---|
| nothing (the default) | its own: one VM per project tree |
| `:vm "shared"` in `env.bl`, or `--share-vm` on a command | the one VM its build runs for every project that said so |

A source checkout (build `src`) always has its own VM: it runs its own sources,
so sharing it would answer one project with another's code.

**Why sharing is a choice, not the default.** Two projects that each define a
namespace named `app` meet in one node, and the node keeps one `app`. Measured:
the second project got the first one's code, and a project's `:env` leaked into
the node's environment. A project that has checked it can live beside others opts
in; nobody is shared by surprise.

**What sharing buys.** One ~200 MB node instead of one per project, and a
directory you have never run `bl` in gets a realm from the warm VM instead of a
cold start. The realm is chosen *per request*, from the request's working
directory: the nearest directory at or above it that holds an `env.bl`.

**What it costs.** A native fault or a runaway allocation reaches every realm in
that VM. [`caveats.md`](caveats.md) says how that is bounded, and what is not.

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

## What is built, and what is not

| built | `vm.manager`, `vm.core`, `vm.owner`, `vm.scope`, `vm.osenv`, `vm.spec`, `vm.net`, `vm.wire`, `vm.ports`, `vm.gateway`, `vm.http`, the VM registry, the inventory, `bl vm`, `bl realm`, the machine page |
| built | **realms in a shared VM**: `vm.realm` opens a realm on its first request and closes it on `bl realm stop`; `vm.index` keeps one index owner per realm |
| not built | per-realm pages under one console: a shared VM serves no dashboard (its pages read one root) |
| not built | project-local code and environment in a shared VM: a namespace defined by two projects is one namespace |
