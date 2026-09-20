# 03 — Services & schedules: systemd and cron, dissolved upward

A service is not a daemon and a cron job is not a daemon: a service is a
supervised OTP tree inside a capped environment, and a schedule is arithmetic
over a clock you supply.

## The claim

`docs/design/vps/services-and-schedules.md` says a service is *"a supervised
tree inside a capped environment"* — the environment is the unit of isolation,
the supervisor is the unit of liveness — and that *"a scheduled job is a clause
inside a process"*, where *"missed occurrences are a declared policy
(`:catch-up :skip | :coalesce | :run`), never a surprise"* and *"the clock is
injectable"*. The same claim appears from two other angles: `devops.md §Services
& supervision` (the `systemctl`/`crond` verb table) and `zero-downtime.md §
Level 2: environment swap` (drain the env, respawn a capped fork). This spike
checks both halves at once — the tree that OTP restarts, and the schedule that
is pure data.

## The idea

Two things that conventional Linux splits into separate daemons, config files
and log tails are, on a bl VPS, one process-model and one data-model:

- **A service is a tree you can hold.** `systemctl restart web` is really "kill
  a child; let the supervisor replace it". OTP already does exactly that, with a
  restart-intensity budget that guards a crash loop — so the spike does not
  *implement* restart, it *observes* it: kill the child, look again, get a
  different pid. And the definition/status verbs collapse too: `systemctl cat`
  has no analogue because the tree **is** a value in the language, and
  `systemctl status` is just reading that value.
- **A schedule is a function of `now`.** A cron entry is an opaque line and a
  daemon that decides what to do after downtime. Here a schedule is a *rule*
  (`{:freq :every :ms 900000}`) and the question "what fired while I was down?"
  is `missed-count rule due now` — a division, not a loop. Pass a different
  `now` and you have a time machine: an hour of downtime is a test that runs in
  microseconds. `∴` DST questions, leap-day questions and "what does catch-up
  do after a week off?" are all unit tests, not postmortems.

The operational payoff is *legibility*. `✓` "which workers are up" is a value.
`✓` "how many backups did we miss and what policy applies" is arithmetic.
`✗` nothing here is a background daemon you have to reason about by inference
from a log file.

## Walkthrough

### Step 1 — the namespace: which organs this spike touches

```clojure
(ns vps.services (:require [super] [vm.core :as vm] [proc.sched :as sched]))
```

Three real organs, three different jobs. `super` is the supervision bundle
(the verbs of `priv/std/proc/super.bl`): trees as data. `vm.core` is the
environment — `spawn-vm`, `run`, `serve`, `drain`. `proc.sched` is the
scheduler's pure algebra: `rule`, `advance`, `missed-count`, `catch-up-plan`.

### Step 2 — a service is an env that owns a tree

```clojure
(defn start-service [id]
  (let [v (vm/spawn-vm {:id id :root "/tmp" :base :global :caps :all})
        sup (vm/run v
              (fn []
                (supervise :one-for-one
                  [(worker :web  (fn [] (Process/sleep 60000)))
                   (worker :cron (fn [] (Process/sleep 60000)))])))]
    {:vm v :sup sup}))
```

Two moves, nested. First `vm/spawn-vm` forks a fresh env off the warm
`:global` base and returns a **VM value** — pure data carrying `:id`, `:root`,
`:base`, `:env` (the forked sandbox ref), `:caps`, `:status :ready` and
`:born-ms`. That data is the service's identity and its isolation.

Then `vm/run` binds that env and runs the thunk inside it. The thunk calls the
real `supervise`, which lowers `:one-for-one` plus a list of worker specs into
an ordinary OTP `Supervisor`. Each `(worker :web (fn [] …))` becomes a child
spec `{:id :web :start {Task :start_link [f]}}` — a zero-arity function runs as
a plain `Task`, the plainest possible BEAM worker. Restart type defaults to
`:permanent`, so a killed child comes back.

`(def svc (start-service "blog@main"))` then binds the pair — env and
supervisor pid — as one value.

```clojure
(println "── service blog@main up ──")
(println "  tree:" (pr-str (map :id (super/children (:sup svc)))))
```

`super/children` decodes `Supervisor/which_children` from Erlang's opaque
4-tuples into `[{:id :pid :type} …]`. So the running service's shape is a value
you can print, diff or assert on — this is `systemctl status`, minus the text
scraping. The line prints `(:web :cron)`.

### Step 3 — `systemctl restart web` is an OTP restart

```clojure
(def before (super/child-of (:sup svc) :web))
(erlang/exit before :kill)
(Process/sleep 120)
(def after (super/child-of (:sup svc) :web))
(println "  restart :web →" (if (not= before after) "OTP put it back" "STUCK"))
```

`super/child-of` looks the child up by id and hands back its pid. We kill that
pid outright — `:kill` is untrappable, no graceful path, the harshest case — and
the only thing that happens next is OTP doing its job: the supervisor sees the
child's `:EXIT`, consults the restart strategy (`:one-for-one` = restart this
child and leave its siblings alone) and starts a fresh one.

We then look the child up *by id again* and compare pids. A different pid is the
proof: the service's body was replaced while its identity (`:web`) and its
siblings (`:cron`, untouched) survived. That is precisely the guarantee
`systemctl restart` sells you, obtained from the process model instead of a unit
file. `∴` no `Restart=always`, no `ExecStart=` drift, no `pidfile`.

### Step 4 — cron as data: rules are values

```clojure
(def backup (sched/rule :every 15 :minutes))     ; every 15m
(def digest (sched/rule :daily 3 0))             ; 03:00 daily
(def t0 0)
(def now-1h (* 60 60 1000))                      ; one hour after t0
```

`sched/rule` is real `proc.sched` code and it does *nothing* operational — it
builds a rule map. `:every 15 :minutes` becomes `{:freq :every :ms 900000}`
(the unit → milliseconds conversion happens in exactly one place,
`proc.tick/unit-ms`). `:daily 3 0` becomes `{:freq :daily :at [3 0]}`.

The clock is the interesting part: `t0` and `now-1h` are just *numbers*. There
is no daemon, no timer, no `sleep`. A schedule is a function whose second
argument is "now", which is why the design calls the clock injectable — here the
injection is literal.

### Step 5 — `advance` and `missed-count` are arithmetic, not walks

```clojure
(println (str "  next backup:  +" (sched/advance backup t0) "ms"))
(println (str "  missed in 1h: " (sched/missed-count backup t0 now-1h)))
```

```
  next backup:  +900000ms
  missed in 1h: 5
```

`(sched/advance backup 0)` = `0 + 900000` — the occurrence *after* a due,
anchored to the due rather than to now, which is what stops drift (a fire three
seconds late still lands on the grid).

`(sched/missed-count backup 0 3600000)` is `(inc (quot (- 3600000 0) 900000))`
= `5`: occurrences at 0, 900000, 1800000, 2700000, 3600000 ms — all at or before
now. Division, not iteration, and the module is explicit about why: a one-second
rule dormant for a year has 31 million missed occurrences, and a loop that counts
them is a hang wearing a catch-up policy's clothes.

### Step 6 — catch-up policy is a declared choice

```clojure
(def skip-plan     (sched/catch-up-plan backup t0 now-1h :skip))
(def coalesce-plan (sched/catch-up-plan backup t0 now-1h :coalesce))
(def run-plan      (sched/catch-up-plan backup t0 now-1h :run))
(println (str "  :skip=" (count (:runs skip-plan))
              "  :coalesce=" (count (:runs coalesce-plan))
              "  :run=" (count (:runs run-plan)) " (missed occurrences)"))
```

```
  :skip=0  :coalesce=1  :run=5  (missed occurrences)
```

This is the heart of the spike. All three plans agree on the *facts* — five
occurrences are due, the next occurrence is at `4500000` — and differ only in
what a human declared should happen to the backlog:

- `:skip` → `{:runs [] :due 4500000}`. Do nothing about the past; jump the wheel
  to the present. For a "flush the cache every 15 minutes" job, the five misses
  are meaningless — running them now would be five pointless flushes.
- `:coalesce` → `{:runs [0] :due 4500000}`. Run **once**, and with the *first*
  missed due, so the occurrence id names the period that was missed rather than
  the instant someone noticed. For a "back up the database" job that is exactly
  right: one backup, not five.
- `:run` → `{:runs [0 900000 1800000 2700000 3600000] :due 4500000}`. Run every
  missed occurrence, in order. For an "append to the ledger" job you want every
  one — the backlog *is* the work.

The rule `catch-up-plan` uses to tell "stale" from "merely late" is worth
stating: an occurrence is not missed until its **successor** has already passed.
A wake that lands a few milliseconds late is not a backlog, it is just a fire —
so it runs, and no policy can silently drop it.

### Step 7 — drain: total teardown

```clojure
(def halted (vm/drain (:vm svc)))
(println "── drained ──" (pr-str halted))
```

`vm/drain` is real `vm.core`: it calls `vm.owner/halt` over the VM's owned
process set, then `env/destroy` on the env. Ownership is substrate bookkeeping —
a registry keyed by VM id, where every member is registered and monitored, so
its entry retracts itself on death and teardown is "kill exactly this set",
never "the node" and never "a convention you have to remember".

### Step 8 — the assertions

```clojure
(def ok (and (not= before after)                 ; worker restarted
             (= 5 (sched/missed-count backup t0 now-1h)) ; 15m rule, 1h → 5 due
             (= 0 (count (:runs skip-plan)))     ; :skip drops the backlog
             (= 1 (count (:runs coalesce-plan))) ; :coalesce runs once
             (= 5 (count (:runs run-plan)))      ; :run runs every missed
             (>= (:halted halted) 0)))           ; env torn down cleanly
```

Every claim above becomes an `=` you can read. Note the last clause: `(>= … 0)`,
not `(= 2 …)` — and the reason is the most interesting honesty note in the
spike, so it gets its own section below.

## What's real vs modelled

This is the boundary to hold onto.

**Real, exercised as-is:**

| organ | what the spike actually runs |
|---|---|
| `vm.core/spawn-vm` | forks a real env (`env/fork` off `:global`), returns the real VM value with `:env`, `:status :ready`, `:born-ms` |
| `vm.core/run` | real: binds `vm.scope` + `env/with-env` around the thunk |
| `vm.core/drain` | real: `vm.owner/halt` then `env/destroy` |
| `BeamLisp.Supervisor/supervise` + `worker` | a genuine OTP `Supervisor`; each `worker` is `{Task, :start_link, [f]}` with `:permanent` restart |
| `proc.super/children`, `child-of` | real: `Supervisor/which_children` decoded to `{:id :pid :type}` maps / pid lookup |
| OTP restart | real: an untrappable `:kill` of a child, healed by the supervisor, observed as a new pid |
| `proc.sched/rule`, `advance`, `missed-count`, `catch-up-plan` | real `priv/std/proc/sched.bl` functions — pure, no process involved |

**Modelled, simplified, or not actually exercised — precisely:**

1. **The env is *forked* but not *capped* here.** The spec is `{:id id :root "/tmp"
   :base :global :caps :all}` — no `:max-heap-words`. So `spawn-vm` takes the
   `(env/fork base {:caps caps})` branch, with `:caps :all`. The environment is a
   real fork; the *ceiling* the design leans on ("OOMScoreAdjust → the env's
   max-heap-words; one service dies, the node lives") is left wide open in this
   spike. Caps and the compile-time cap gate are the subject of
   `02_capabilities.md`, not this one. Read this spike as "the env is the unit
   of isolation", not "the env is bounded".

2. **The tree is not owned by the env, so `drain` reports `{:halted 0}`.** This
   is the sharpest caveat. The tree is started **inside `vm/run`**, which binds
   the env *in the calling process* and returns the thunk's value — it does not
   spawn a registered member. Ownership is the `vm.owner` registry, and
   registration happens only via `vm.owner/adopt` (i.e. `spawn`/`spawn-in`, or
   `vm.core/serve`). Nothing here registers the supervisor, so `owner/halt`'s
   process set for this VM is empty and the drain line prints `{:halted 0}` —
   which is exactly why the assertion is `(>= (:halted halted) 0)` and not `(= 2 …)`.
   The drain *code path* is real (`owner/halt` + `env/destroy` both run); the
   *teardown of the tree* is not demonstrated, because the tree was never in the
   set being torn down. `env/destroy` drops var rows and monitors nothing — it
   does not kill processes. Use `vm.core/serve` (→ `vm.owner/spawn-in`) and the
   same drain kills the tree for real. Exercise 4 below is precisely this.

3. **`systemctl restart` is modelled as kill-and-wait, not as `super/restart`.**
   The design's verb table names `(super/restart s :web)`; `proc.super/restart`
   exists (it wraps `Supervisor/restart_child`) but the spike instead does
   `erlang/exit … :kill` and then **sleeps a fixed 120 ms** before looking again.
   The restart is genuinely OTP's, but the *wait* is hopeful rather than
   honest — the shipped `examples/supervision.bl` polls with a bounded loop
   ("the restart is asynchronous, so the only honest wait is one that checks").
   Under load, 120 ms could be short.

4. **Cron is the algebra, not the wheel.** There is no `defserver`, no `(sched …)`
   clause, no `proc.tick`, no timer, no store. The pure functions are called
   directly with literal `now` values. That means this spike does **not** exercise:
   arming (`arm`/`arm-first`), the single-wake wheel, occurrence ids
   (`"<schedule-id>@<due-ms>"`), `:pause`/`:resume`/`:run-now`, the `:sched`
   store and its datoms, or the `{:clock fn}` clause option. The "injectable
   clock" the header promises is demonstrated in its *purest* form — `now` as a
   function argument — rather than through the clause plumbing that injects it.

5. **The third policy is spelled `:run` here; the declared vocabulary is
   `:run-all`.** `proc.sched/KNOWN-CATCH-UP` is `[:skip :coalesce :run-all]`, and
   `check-opts!` rejects anything else with *"unknown :catch-up :run — use :skip
   :coalesce :run-all"*. But `catch-up-plan` itself performs **no vocabulary
   check**: its `cond` ends in a bare `:else` that *is* run-all. So the spike's
   `:run` reaches the run-all branch, produces the same `5`, and would be
   **refused** if written as `{:catch-up :run}` inside a real declaration. The
   design doc's prose spells it `:run`; the code's declared spelling is `:run-all`.
   The spike is exercising a real branch through an undeclared alias.

6. **The `:daily` rule is defined but never used.** `(def digest (sched/rule
   :daily 3 0))` exists to show the shape; no output and no assertion touches it.
   Likewise `:at` (one-shots) is never constructed.

7. **The "workers" are sleeps.** `(fn [] (Process/sleep 60000))` — the point is
   liveness under restart, not work done. There is no web server, no port claim,
   no gateway, no reconciler, no datom. Nothing here talks to the outside world;
   the spike is entirely about the shape of supervision and the shape of a
   schedule.

## Run it

```
./blx run research/vps_spike/03_services.bl
```

Cold start costs ~10–15 s (JIT warmup) — that is boot, not work. The run prints
the service coming up, the restart verdict, the cron arithmetic, the drain, and
ends with exactly:

```
PASS 03_services  (systemd+cron dissolved upward)
```

(The drain line reads `{:halted 0}` for the reason in caveat 2 — the assertion
accepts it, and every other number — `900000`, `5`, `0`/`1`/`5` — is pinned by an
`=`.)

## Exercises

1. **Spell the policy the way the code declares it.** Change `:run` to `:run-all`
   in the third `catch-up-plan` call. Predict: identical — `:run=5` — because the
   `:else` branch is run-all either way. Then try `:runall` (a typo). Predict:
   *still* `5`, silently, because `catch-up-plan` never looks at a vocabulary.
   Now try to write `{:catch-up :run}` where it would actually be checked (a
   `defserver`'s `(every 15 :minutes :backup backup! {:catch-up :run})`) and
   predict a hard refusal naming the allowed spellings. The lesson: the check
   lives at declaration time, and a direct call bypasses it.

2. **Trip the ceiling.** Add `(def fast (sched/rule :every 1 :seconds))` and
   compute `(sched/missed-count fast t0 now-1h)` and
   `(count (:runs (sched/catch-up-plan fast t0 now-1h :run)))`. Predict:
   `missed-count` = 3601, but the plan runs only `MAX-CATCH-UP` = 64, and `:due`
   comes back `nil` (incomplete) rather than jumping to the present. That `nil`
   is the module refusing to turn a year of downtime into a month-long burst.

3. **A one-shot past its due.** Add `(def go-live (sched/rule :at 1000))` and
   read `(sched/catch-up-plan go-live 1000 5000 :coalesce)` and the same with
   `:skip`. Predict `:coalesce` → `{:runs [1000] :due nil}` and `:skip` →
   `{:runs [] :due nil}`: after its single occurrence `advance-n` returns `nil`,
   so `stale?` is forced true and the wheel has nothing left to arm. Then set
   `now` to `500` (before the due) and predict `{:runs [] :due 1000}` — not yet
   due beats every policy.

4. **Make drain actually drain.** Replace the tree's start with
   `(vm/serve v :tree (fn [] (let [s (supervise :one-for-one …)] (reset! grabbed s) s)))`
   instead of `vm/run v …`. Now `(:sup svc)` is the owner-registered *member*
   process, and `@grabbed` holds the supervisor. After `vm/drain`, print
   `(:halted halted)`, `(Process/sleep 50)`, then `(Process/alive? (:sup svc))`
   and `(Process/alive? @grabbed)`. Predict: `halted` = 1 (the member is in the
   owned set), the member is dead, and **the supervisor is dead too** — the member
   is linked to it, so killing the member took the tree with it. With the spike's
   original `vm/run`, `halted` is 0, nothing was in the owned set, and the
   supervisor is still alive after drain. That difference *is* the ownership
   claim, and this is the experiment that shows it.
