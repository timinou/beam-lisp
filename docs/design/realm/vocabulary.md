# The vocabulary

Seven words. Each names exactly one thing, and each thing has exactly one name.
If you find yourself needing an eighth, one of these is doing two jobs.

```
project ──declares──▶ realm ◀──hosts── vm ◀──runs── build
                        │                │
                        ├─ members       └─ the OS boundary
                        └─ routes ──▶ the gateway
```

## project

**What it is.** A directory with an `env.bl`. The file is a map: the name, the
ports, the tasks, the capabilities, the schedules. `.env.local.bl` (gitignored)
is deep-merged over it for one developer's private choices.

**What it is not.** Running. A project is a declaration; nothing about it
occupies memory.

**Reach for it when** you are saying *what you want*: pin a port, declare a task,
narrow a capability.

## build

**What it is.** One immutable set of code: a drop (`~/.local/share/drop/<sha8>/`),
or `src` for a source checkout. A build has an id.

**What it is not.** A thing that runs. It is what a VM runs.

**Why it is in the vocabulary.** A BEAM node loads each module once, so one node
can run one build. That single fact is why *build* is part of a VM's identity
and nothing else is.

## vm

**What it is.** One operating-system process: a `beam.smp` running one build.
It has a pid, a start time, a memory footprint, and a role.

| role | what it does | how many |
|---|---|---|
| `warm` | hosts realms; answers commands without a cold boot | one per user per build |
| `gateway` | routes names to ports | at most one per user |
| `job` | a long-lived `serve`/`watch`/`monitor` | as many as you start |

**What it is not.** A project, or an isolation boundary *between* projects. It
is the boundary between *you and the operating system's process model*: the
unit that can crash, be killed, be measured, or hold a privileged port.

**Reach for it when** you want to answer *what is running on my machine?*, or to
stop, restart, or measure something.

**Lifetime.** Until stopped, crashed, or idle-expired. The registry record is
written once, at start, and removed on a clean stop.

## realm

**What it is.** A project, alive inside a vm. It has an identity
(`<name>@<instance>`, where the instance is the git branch or a hash of the path,
so two worktrees of one project never collide), a capped `env` fork, and a set of
owned processes.

**What it is not.** An OS process. Many realms share one vm. Not a REPL session,
and not a live-app *viewer session* (that is a different domain: per-socket state
in a live view).

**Reach for it when** you mean *my project, right now*: its address, its routes,
its tasks, its index.

**Lifetime.** From the first command in a directory, until it is drained
(`bl realm stop`), its vm exits, or its idle timer fires.

**Why "realm" and not "session".** Session is already how people say *a REPL
session* and *a browser session*. A realm is a place with its own laws —
capabilities, a heap ceiling, a name — inside a larger world. That is exactly
what an `env` fork is.

## member

**What it is.** One process owned by a realm, with a role: a `run` (one command),
an `app` (a side-app such as `:web`), a `repl`, a `schedule`, an `index`.

**The one rule.** When a realm ends, exactly its members end — `vm.owner/halt`
walks that set and nothing else. A member that dies removes itself from the set
(it is monitored), so the set is always the truth.

## route

**What it is.** A name that reaches a port: `ui.blueprint.test → 127.0.0.1:33091`.
One small file per claim under the runtime dir. A route belongs to a realm
through the `app` member that holds the port.

**What it is not.** Reachability *infrastructure*. The gateway is the thing that
answers names; a route is just the fact that a name was claimed.

## env (a mechanism, not a noun you type)

**What it is.** The runtime primitive in `priv/std/env.bl`: a forked scope with
variables, a capability set, and an optional heap ceiling, bound to a process
with `env/with-env`. It is cheap to fork.

**Where it shows.** A realm *is* an env fork plus its members plus an identity.
Tests, agents and tenants use env forks directly, with no realm and no listing.

**Why it is not a user-facing noun.** "env" already means three things here —
the project file, the fork primitive, and a process's OS variables. Users meet
*realm*; the fork is how a realm is built.

## The three words people will confuse

| they say | they mean | the word |
|---|---|---|
| "my warm VM" | my project, alive and warm | **realm** |
| "the process" | the OS process | **vm** |
| "env" | the project file | **project** (`env.bl`) |

## What each one answers

| question | noun | command |
|---|---|---|
| what is running on this machine? | vm | `bl vm` |
| is my project warm, and where is it? | realm | `bl realm` |
| why is it using 7 GB? | vm | `bl vm show ID` |
| what is this command doing right now? | member | *(planned: `bl realm members`)* |
| what is the address? | route | `bl realm open` |
| which code is this? | build | the BUILD column |
