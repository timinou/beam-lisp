# Services and schedules — systemd and cron, dissolved upward

> A service on a bl VPS is a supervised tree inside a capped environment. A
> scheduled job is a clause inside a process. Neither systemd units nor cron
> daemons exist above the one node unit — their jobs are done better by values
> you can inspect.

## What a service is

```clojure
(super/defsupervisor blog
  (strategy :rest-for-one)
  (intensity 3 5000)
  (child :web   (web/serve {:port :claim :hosts ["blog.example.com"]}))
  (child :house housekeeping))
```

The tree lives inside a `vm.core` environment: a capped fork of a warm base
env with a heap ceiling and an owned process set. The environment is the unit
of isolation; the supervisor is the unit of liveness.

Three properties fall out for free:

- **the definition is data** — `(super/children s)` returns the running tree
  as a value; there is no `systemctl cat` because the definition and the
  runtime were never two things
- **the tree is verifiable** — `system/verify` can prove each child's
  invariant from source before the reconciler starts it
- **teardown is total** — draining the env kills exactly its owned process
  set; there are no orphaned children because ownership is the substrate's
  bookkeeping, not a convention

## The verb mapping

| conventional | on a bl VPS |
|---|---|
| `systemctl start blog` | reconciler spawns the env (a consequence of desired state) |
| `systemctl restart blog` | `(super/restart s :web)`, or drain + respawn the env |
| `systemctl status` | `(super/children s)` + the env's process table |
| `journalctl -u blog` | datalog over the service's event datoms |
| `OOMScoreAdjust` | the env's `max-heap-words` ceiling — one service dies, the node lives |
| `WatchdogSec` | supervision intensity budgets + the reconciler's liveness reads |
| `crontab -e` | a `sched` clause, transacted |

## Schedules are data with a clock you can swap

```clojure
(proc.server/defserver housekeeping
  (sched (every 15 :minutes :reap   reap!)
         (daily  03 00       :backup backup! {:catch-up :coalesce})
         (at     1790000000000 :go-live switch-to-live!)))
```

`proc/sched` keeps one timer for the whole server — the wheel is a map in the
process state, re-armed at the earliest due on every fire. The operational
verbs are the point:

```clojure
(proc.sched/next    h :backup)   ; {:at … :in-ms … :runs 41 :last-run …}
(proc.sched/spec    h)           ; the declaration, as data
(proc.sched/pause   h :reap)
(proc.sched/run-now h :backup)
```

And because the clock is injectable, "does the backup fire after a DST
transition?" is a test that runs a week in a millisecond — not a hope.

Every occurrence has a deterministic id (`"<schedule-id>@<due-ms>"`) and runs
at most once per process. Missed occurrences are a declared policy
(`:catch-up :skip | :coalesce | :run`), never a surprise.

## Failure arithmetic

| failure | what happens |
|---|---|
| a worker crashes | OTP restarts it; intensity budget guards a crash loop |
| a service exceeds its heap | the env ceiling trips; the env drains; siblings unaffected |
| the scheduler's server crashes | supervision restarts it; the wheel is data, rebuilt from the declaration |
| the node dies | systemd restarts the node; envs rehydrate from datom + specs |

Exactly one layer of supervision above (super trees), exactly one below
(systemd). The middle layers that conventional stacks accumulate — monit,
supervisord, docker restart policies — have nothing left to do.

## Deploying a new service

You do not start services; you *declare* them. Transacting
`{:service/id "blog" …}` is the whole act — the reconciler
(`the-reconciler.md`) fetches the source, forks the env, starts the tree,
claims the name. Removing the service is retracting the datom. The operator's
job is authoring truth; the machine's job is consequences.
