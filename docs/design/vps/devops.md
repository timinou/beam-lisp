# Devops on a bl VPS — the full surface

> The domain-by-domain companion to `README.md`. Every devops need, the bl
> mechanism that fulfils it, and the daily ritual it produces. The base OS is
> NixOS; deployment is fully declarative and zero-downtime by construction
> (see `zero-downtime.md`).

## The two strata

One rule organizes everything:

> **Nix declares what must exist for the node to boot.
> Datom declares what may change while it runs.**

Below OTP — the kernel, the firewall, users, the one systemd unit, the bl
closure itself — a NixOS flake is the only source of truth. Above OTP —
services, routes, schedules, secrets, certs — desired-state datoms are the
only source of truth. There is no imperative layer in between: nobody sshes in
to edit a file. Both strata are data; both have a converger (`nixos-rebuild`
below, the reconciler above); both keep history (generations below, the
transaction log above).

## Day 0: provisioning

A new VPS is claimed by one command from anywhere:

```
nixos-anywhere --flake .#vps-1 root@<ip>
```

The flake declares the disk layout (disko), the firewall (nftables — the one
kernel surface, declared in Nix, never touched by hand), the `bl-node` systemd
unit, and the bl closure. First boot: the node transacts its birth certificate
(`{:host :born-at :bl-version :flake-rev}`), generates its CA, opens ssh on
:2222, and asks the reconciler what it should run.

Adding a second machine is the same command plus a join token (a Biscuit
attenuated to `:fleet/join`). The node dials the cluster, syncs datom, and
converges to its slice of desired state. **Provisioning is transacting
membership.**

## Services & supervision

Each service is a `vm.core` environment — a capped fork of a warm base with a
heap ceiling and an owned process set — containing a `super.bl` tree:

```clojure
(super/defsupervisor blog
  (strategy :rest-for-one)
  (intensity 3 5000)
  (child :web   (web/serve {:port :claim :hosts ["blog.example.com"]}))
  (child :house housekeeping))

(proc.server/defserver housekeeping
  (sched (every 15 :minutes :reap  reap!)
         (daily  03 00        :backup backup! {:catch-up :coalesce})))
```

The conventional verbs dissolve upward:

| conventional | on a bl VPS |
|---|---|
| `systemctl restart blog` | `(super/restart s :web)` or drain + respawn the env |
| `journalctl -u blog` | datalog over the service's event datoms |
| OOM-killer | the env's `max-heap-words` ceiling trips first — one service dies, the node lives |
| `crond` | `proc/sched` — schedules are inspectable data with deterministic occurrence ids and an injectable clock |

Supervision above, systemd below, exactly one layer of each. systemd's only
job is that the node exists. Full treatment: `services-and-schedules.md`.

## Configuration = desired state, reconciled

The heart of the machine is a loop:

```
desired  := datalog over :service/desired          ; what you asked for
observed := vm.ports claims + process table + envs ; what is
delta    := reconcile/diff desired observed        ; a pure function
effect   := spawn / drain / reload / re-route      ; capped, logged
```

Every effect is transacted with its reason (`:effect/why-delta`), so "why did
web restart at 03:12?" is a query, not archaeology. Drift is not an error — it
is observed-state change the reconciler reports, and you either commit it to
desired or revert it. Full treatment: `the-reconciler.md`.

## Ingress, TLS, naming

`vm/gateway.bl` holds :80/:443 as its own small OS process, routes by `Host:`,
and serves per-name leaf certs from the node's own CA (`vm/ca.bl`). Daily life:

- a new public name is one attribute in desired state; route, claim, and cert
  appear together
- renewal is a `proc/sched` daily job — no certbot cron, no reload dance
- internal-only names resolve only on the cluster interface

The gateway being a *separate* process from the node is what makes
zero-downtime node upgrades possible: it keeps answering while the node under
it is swapped (`zero-downtime.md`).

## Storage, backups, DR

| layer | mechanism |
|---|---|
| live db | `datom` over `store-fjall` (durable KV) |
| blobs | `blob-s3` — content-addressed, off-box by construction |
| backup | a scheduled job checkpoints datom to S3; restore = bootstrap + `(datom/restore checkpoint)` |
| history | bitemporality (`time.bl`) — you query as-of instead of rotating logs |
| retention | `excise` on a policy schedule — deletion is a first-class, audited op |

The DR drill is a scheduled function: restore yesterday's checkpoint into a
scratch env, run a smoke query, transact the result. "When did we last prove
restores work?" is itself a query. Full treatment: `backups-and-dr.md`.

## Observability — the inversion

Conventional stacks scrape metrics from a black box into a second system, then
alert from a third. On a bl VPS the system *is* the dataset:

- events are datoms transacted at the source
- dashboards are `live/web` pages over datalog queries that re-run on
  tx-report (`watch.bl`, `broadcast.bl`)
- alerts are `proc/sched` clauses whose conditions — and every firing — are
  datoms, so alert fatigue is debuggable
- when an alert fires you do not switch tools: you query the live env, inspect
  the mailbox, and fix hot

Full treatment: `observability.md`.

## Deploys

One verb, three safety nets:

```clojure
(deploy! "blog" "git@…#v1.1")
;; 1. z3 proves v1.1 against blog's contract, or explains the contract change
;; 2. reload ward/migrate: new code beside old, state migrated
;; 3. canary: a datom branch serves 5% of gateway claims; promote or fold
```

Rollback is a value: prior module versions are still loaded, prior db state is
as-of reachable. Node-level changes (a new bl closure, a NixOS generation) go
through the blue/green node swap — declared in the same desired state,
converged by the same reconciler. Full treatment: `zero-downtime.md`.

## Identity, secrets, blast radius

One capability story end to end: ssh key → Biscuit token → attenuation →
capped env fork → RLS-scoped queries. Secrets are vars in env forks that
sibling envs cannot name — the compile gate makes them unspeakable, so there
are no `chmod 600` files to leak. Rotation is a transacted spec change; the
reconciler re-forks the env and the owner registry carries state across.

A leaked token attenuated to `{:svc "blog" :for 10m}` can do one thing for ten
minutes — and everything it did is in the audit datoms.

## Incident response

```
page → ssh → capped REPL →
query the incident window (bitemporal, exact) →
inspect the live process →
hot-fix in place, or drain the env →
transact the postmortem into the same db that paged you
```

Five tools collapse into one prompt. Most of an incident's clock time is
context-switching between tools; that is the time this design deletes. Full
treatment: `incident-ritual.md`.

## Fleet

BEAM distribution with Biscuit in place of the cookie. Desired state is one
datom cluster, RLS-partitioned per host; each node's reconciler sees only its
slice. Moving a service is drain-here, spawn-there, re-claim the name. The
lower stratum scales with the same flake — the fleet is one NixOS
configuration evaluated per host. The open problem is datom consistency across
nodes; `fleet.md` is honest about it.

## The gaps, honestly

| gap | answer |
|---|---|
| nftables / sysctl / mounts | declared in the NixOS flake — the kernel is Nix's problem, solved |
| cgroups | systemd unit properties on the node; per-env heap ceilings cover the rest |
| compliance exports | a `flow.bl` consumer streams datalog → ndjson; pull-shaped, so export can never hurt the node |
| node self-upgrade | blue/green node generations under the gateway (`zero-downtime.md`) |
| kernel reboot | fleet-level env migration; single-node accepts a maintenance window or kexec |
| datom split-brain | the real frontier — unsolved, documented in `fleet.md` |
