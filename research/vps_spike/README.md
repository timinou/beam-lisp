# vps_spike — the design, made runnable

Seven spikes, each a runnable `.bl` file that PASSES on the real beam-lisp
runtime, together touching every element of the VPS design in
`docs/design/vps/`. Each spike ends in a `PASS`/`FAIL` line and asserts its own
claim, so the suite is a regression gate, not a demo.

```
research/vps_spike/run.sh      # runs all seven cold, prints PASS/FAIL
```

Runtime: `./blx` (a symlink to the `bl-v2026.4` drop that ships `datom`,
`vm.core`, `super`, `fence`, `reload`, `flow`). The stderr line
`env.bl: unknown key schedules` is a harmless mismatch between the checkout's
`env.bl` and the drop; `run.sh` filters it.

## The spikes and what they prove

| spike | proves | design doc | stands on |
|---|---|---|---|
| `01_reconciler.bl` | desired ⇒ observed ⇒ delta ⇒ effect is one pure fn; every effect is a queryable fact | `the-reconciler.md` | **real** datom |
| `02_capabilities.bl` | the blast radius is a *compile error* — a right the token never granted is unspeakable; attenuation only narrows | `devops.md` §identity, `fleet.md` §blast radius | **real** env cap gate |
| `03_services.bl` | a service is a supervised tree in a capped env; `systemctl restart` = OTP restart; drain = total teardown | `services-and-schedules.md` | **real** super + vm.core |
| `04_zero_downtime.bl` | a backend swap under a stable gateway drops zero requests (exactly one cutover); rollback is a `as-of` value | `zero-downtime.md` | **real** datom; gateway modelled as a routing atom |
| `05_observability.bl` | events are datoms; a dashboard re-runs live on tx; an alert's firing is itself a fact; latency JOINS the deploy boundary | `observability.md` | **real** datom + `datom/watch` |
| `06_backups_dr.bl` | checkpoint/restore round-trips; the restore drill is fence-bounded and its result is a fact ("when did we last prove restore?" = a query) | `backups-and-dr.md` | **real** datom + fence |
| `07_incident.bl` | page→postmortem in one store: the page carries its query, the window is bitemporal, automation and operators share one audit log, the postmortem's action is a datom | `incident-ritual.md` | **real** datom |

## Real vs modelled

Honesty about the boundary — a spike is a probe, not the product:

- **Real, exercised as-is:** datom (facts, datalog, `as-of`/`since`, `watch`),
  the env capability gate (`env/fork` + compile-in-env denial), OTP supervision
  via `super`, env isolation and teardown via `vm.core`, `fence`.
- **Modelled in miniature** (the full organ exists in the tree but is either
  checkout-only or too heavy for a spike): the gateway routing table (a plain
  atom here; `vm/gateway.bl` is the real reverse proxy), the scheduler wheel (a
  due-list here; `proc/sched.bl` is the real declarative cron), the node
  blue/green swap (two backend fns here; the real thing swaps OS node
  processes), checkpoint-to-S3 (an in-memory fact set here; `blob-s3.bl` is the
  real store).

## The below-OTP stratum

`flake.nix` in this folder is the declarative artifact for everything below
OTP (kernel, firewall, the one systemd unit). It is not run here — this host
has `nix` but not `nixos-rebuild` — it stands as the concrete shape the
`bootstrap.md` design refers to: the machine's below-OTP identity as one
evaluable value.

## The whole point, in one line

Desired state, observed state, history, audit, and the fix are all datoms and
live processes in one address space — so every devops question is a query and
every devops action is a transaction. The spikes are that sentence, executed.
