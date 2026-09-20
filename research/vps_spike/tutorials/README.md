# Tutorials — the VPS spikes, explained

Each spike in `research/vps_spike/` is a runnable proof of one claim from the
design in `docs/design/vps/`. These tutorials explain what each proves, walk the
code, and mark exactly where a real organ is exercised versus modelled in
miniature. Read them in order for the argument; jump by topic with the table.

## The one mental model

Everything rests on a single sentence:

> **Desired state, observed state, history, audit, the deploy proof, and the fix
> are all datoms and live processes in one address space.**

So every devops question is a *query*, every action a *transaction*, every
unsafe change a *refusal with a reason*. The spikes are that sentence, executed —
and the tutorials are why each line of it is true.

## How to run

```
./blx run research/vps_spike/01_reconciler.bl     # one spike, prints PASS/FAIL
research/vps_spike/run.sh                          # all bl spikes (01-13)
research/vps_spike/run.sh --podman                 # + the container platform-swap
```

`blx` runs the checkout-matched `bl-v2026.4` drop with this worktree's stdlib on
`BEAM_LISP_PATH` and a `z3` for the verifier tiers. Cold starts cost ~10-15s
each (JIT warmup) — that latency is boot, not work.

## The tutorials

| # | tutorial | proves | headline organ |
|---|---|---|---|
| 01 | [reconciler](01-reconciler.md) | desired ⇒ observed ⇒ delta ⇒ effect, one pure fn; effects are facts | datom |
| 02 | [capabilities](02-capabilities.md) | the blast radius is a compile error | env cap gate |
| 03 | [services & schedules](03-services.md) | a service is a supervised tree in a capped env; cron is data | super + vm.core + proc.sched |
| 04 | [hot reload](04-hot-reload.md) | app AND bl updates are hot; an incoherent edit is held | reload coherence gate |
| 05 | [observability](05-observability.md) | events are datoms; alerts are facts; latency joins deploys | datom + watch |
| 06 | [backups & DR](06-backups-dr.md) | checkpoint leaves the box to real S3; the drill proves restore | blob-s3 → Garage |
| 07 | [incident ritual](07-incident.md) | page → postmortem in one store | datom (bitemporal) |
| 08 | [upgrade refusal](08-upgrade-refusal.md) | a lacking/unsafe migration is refused, with a reason | z3 |
| 09 | [platform swap](09-platform-swap.md) | blue-green is for the PLATFORM, across containers | podman + socat |
| 10 | [identity](10-identity.md) | one token: mint → attenuate → authorize → RLS → audit → revoke | auth (Biscuit) |
| 11 | [ssh access](11-ssh-access.md) | ssh terminates in a capped REPL, capped by the token | executor.sandbox + auth |
| 12 | [ingress TLS](12-ingress-tls.md) | one listener, a per-name leaf from the node's CA, routed by SNI | vm.ca (real TLS) |
| 13 | [drift & proof](13-drift-and-proof.md) | drift is a choice; the delta is proved before it applies | datom + z3 |

## The three arguments the spikes make together

1. **One address space.** 01, 05, 07, 13 — desired/observed/history/audit/fix are
   all datoms; every question is a query.
2. **Safety is structural, not procedural.** 02, 04, 08, 10, 11, 13 — a wrong or
   unauthorized action does not *fail at runtime*, it *cannot be expressed*:
   an ungranted call does not compile, an incoherent reload is held, an unproven
   migration is refused, a revoked token denies.
3. **The floor is honest.** 03, 06, 09, 12 — where bl meets the OS (systemd,
   S3, containers, TLS), the spikes use the real thing (Garage, podman, `:ssl`)
   and name what is still modelled.

## Real vs modelled — the running tally

Every tutorial has a "Real vs modelled" section. The short version: datom, the
env cap gate, OTP supervision, `fence`, the reload coherence gate, `proc.sched`,
z3 proofs, `vm.ca` TLS, `blob-s3`→Garage, the full `auth` stack, and
`executor.sandbox` admission are all **real**. What remains modelled is called
out per spike (e.g. the reconciler's effect application is direct rather than
through the live `vm.manager`; the socat gateway leaves a ≤1-drop window the real
`vm.gateway` closes with connection draining).
