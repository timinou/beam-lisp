# A VPS that is one lisp machine

> Design vision. A VPS where beam-lisp is the *only* environment: every devops
> need — access, deploys, routing, secrets, observability — is fulfilled by the
> language itself, on one long-lived BEAM node. The OS is a bootloader for OTP.

This document is the map. Later documents in this folder take each territory.

## The one move

A conventional server is four formats that never join: state in files, truth in
processes, history in logs, intent in wiki pages. Devops pain is the impedance
mismatch between them.

A bl server collapses all four into one address space:

> **Desired state, observed state, history, and code are all queryable datoms
> and live processes in one runtime.**

"Managing the server" stops meaning *editing YAML and restarting things*. It
means *transacting new desired state and letting the node converge* — then
querying the living system to watch it happen.

The language is the harness is the runtime is the application. This design
extends the sentence one level down: **is the operating environment.**

## The shape of the machine

```
NixOS (kernel + systemd + nftables, one flake)
  └─ one systemd unit ──► bl node          (erts + the bl closure)
      ├─ executor/ssh        :2222         humans and agents get a capped REPL
      ├─ vm/gateway :80/:443 + vm/ca       all HTTP ingress, TLS by name
      ├─ datom (durable)                   desired state, events, history
      ├─ reconciler                        desired → observed, continuously
      ├─ vm.core environments              one per service, capped and owned
      └─ MCP transport                     agent operators, same door as humans
```

The base is NixOS, strongly: everything below OTP is one declarative flake, and
everything above OTP is desired-state datoms. The rule that organizes the whole
design: **Nix declares what must exist for the node to boot; datom declares
what may change while it runs.** Zero-downtime is declared, not performed —
hot reload for code, env swap for services, blue/green node generations under
the gateway for the node itself (`zero-downtime.md`).

## The mapping, need by need

| conventional | on a bl VPS |
|---|---|
| bash over sshd | `executor/ssh.bl` — ssh terminates in a **capped bl REPL**, rights enforced at compile time, memory and disk ceilings on the session |
| N systemd units | one unit for the node; services are processes under `super.bl` trees inside it |
| nginx + certbot | `vm/gateway.bl` reverse-proxies by `Host:`; `vm/ca.bl` mints a leaf cert per service name |
| postgres + redis | `datom` — durable, datalog, time travel, branches, RLS |
| ansible / terraform | desired-state datoms + a reconciler that diffs against live claims |
| prometheus + grafana | events are datoms; datalog answers the questions; `live/web` draws the rest |
| sudoers | `auth` — Biscuit-style tokens, attenuation, row-level security, audit trail |
| secrets vault | capped vars in env forks, unreadable from sibling environments |
| CI runner | a watcher transacts new desired state on push; `z3` can prove a change against a service's contract before reload accepts it |

None of these is hypothetical wiring — the organs exist in the tree today:
`priv/std/executor/ssh.bl`, `priv/std/vm/*`, `priv/lib/datom/*`,
`priv/std/reload/*`, `super.bl`, `z3pool.bl`. The design is noticing that they
already form a whole.

## A day on the box

**Arriving.** `ssh ops@vps` lands you in a `bl>` prompt, in a sandbox derived
from *your key's* token. There is no bash to miss. The system you came to
inspect is the same process space your REPL lives in:

```clojure
bl> (datom/q '[:find ?svc ?lat :where [?svc :svc/p95 ?lat]] (metrics/now))
bl> (vm.core/drain (vm "billing@main"))     ; one service ends; the node does not
```

**Adding a service.** You transact desired state. The reconciler does the rest —
fetches the source, forks a capped env, claims the name on the gateway, mints
the cert:

```clojure
{:services [{:id "blog" :src "git@…#v1.0"
             :hosts ["blog.example.com"]
             :heap-words 50_000_000}]}
```

**Deploying.** No restarts. New code loads beside the old, contracts are
checked, state migrates, cutover happens. A bad deploy is undone by pointing
the environment back at prior module versions — rollback is a value, not a
procedure. A canary is a datom branch serving 5% of the gateway's claims until
promoted.

**Investigating an incident.** "What changed at 03:12" is a datalog query over
the transaction log, not archaeology across `/var/log`. And when you find it,
you do not file a ticket and wait for a maintenance window — you fix the
function, hot, in the same REPL you diagnosed it from. The observer and the
observed are one thing. This is the feature conventional stacks cannot copy:
you do not scrape metrics from a black box; you query the box, then reach in.

**Giving an agent a job.** An AI operator connects over MCP and receives
exactly what a human receives: a capped REPL behind a token. Attenuate the
token for the task (`deploy` → `deploy blog` → `deploy blog for 10 minutes`),
and the audit log — datoms, like everything else — records every effect.

## Honest edges

Three places where the design touches the floor honestly:

1. **The kernel.** Firewall rules, sysctls, mounts live below OTP. They are
   handled by one small audited module driving an `exec` port with op-scoped
   capabilities — not by pretending the layer is pure.
2. **Bootstrap.** The first five minutes of a fresh VPS are conventional:
   install a static `bl` drop, write one systemd unit. Everything after that
   minute is bl.
3. **Isolation strength.** bl environments give capability and heap isolation,
   not syscall isolation. That is exactly right for your own services and
   agents, and wrong for hostile multi-tenant workloads — which this design
   does not host.

The single point of failure has a simple answer: supervision above, systemd
below, exactly one layer of each. If the node dies, systemd restarts it and
environments rehydrate from durable datom and specs.

## Why this works

A server was always a live-programming problem: processes that must not stop,
state that must not be lost, changes that must not break the contract. The
industry answered with frozen artifacts and orchestrators that treat machines
as replaceable. This design answers with the opposite conviction — a machine
you keep *alive*, whose state you can time-travel, whose code you can replace
mid-flight, whose every component is a value you can query.

The BEAM already knows how to keep a system running for decades. Datom already
knows how to remember everything without losing the present. Auth already knows
how to say who may do what. A bl VPS is those three sentences, applied to the
whole machine.

## The documents in this folder

- *(this file)* — the map
- `devops.md` — every devops need, its mechanism, its daily ritual
- `bootstrap.md` — day 0: one flake, one command, the birth transaction
- `zero-downtime.md` — the three levels of change, all declared
- `the-reconciler.md` — the heart: desired / observed / delta / effect
- `services-and-schedules.md` — systemd and cron, dissolved upward
- `backups-and-dr.md` — checkpoints, restore drills, bitemporal retention
- `observability.md` — the inversion: the system is the dataset
- `incident-ritual.md` — one prompt from page to postmortem
- `fleet.md` — many nodes, one truth, and the honest frontier
