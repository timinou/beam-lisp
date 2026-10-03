# vps_spike — the design, made runnable

Eight `.bl` spikes and one container demo, each ending in a `PASS`/`FAIL` line
that asserts its own claim, together touching every element of the VPS design
in `docs/design/vps/`. The suite is a regression gate, not a slideshow.

```
research/vps_spike/run.sh            # bl spikes 01-08 (brings Garage up for 06)
research/vps_spike/run.sh --podman   # + 09 platform-swap, real containers, capped
```

**Every spike has a step-by-step tutorial in [`tutorials/`](tutorials/README.md)** —
what it proves, a walk of its code, and an honest real-vs-modelled boundary.

Runtime: `./blx` — runs THIS checkout from source (`bin/bl`) with this worktree's
`priv/std` + `priv/lib` on `BEAM_LISP_PATH` (so the REAL `proc.sched`, `reload`,
`vm.*` load) and a `z3` for the verifier tiers. It used to exec a prebuilt
`bl-v2026.4` drop; a prebuilt drop is a generation behind the tree it is asked to
run, and the file is gone. The stderr line `env.bl: unknown key schedules` is a
harmless env mismatch; `run.sh` filters it. After pulling main, run `./bin/bl build`
once — a stale build tier is the one thing that makes a spike fail for a reason
that is not the spike's.

## The spikes and what they prove

| spike | proves | design doc | stands on |
|---|---|---|---|
| `01_reconciler.bl` | desired ⇒ observed ⇒ delta ⇒ effect is one pure fn; every effect is a queryable fact | `the-reconciler.md` | **real** datom |
| `02_capabilities.bl` | the blast radius is a *compile error* — a right the token never granted is unspeakable; attenuation only narrows | `devops.md` §identity | **real** env cap gate |
| `03_services.bl` | a service is a supervised tree in a capped env; `systemctl restart` = OTP restart; drain = total teardown; cron is `proc.sched` arithmetic with declared catch-up policies | `services-and-schedules.md` | **real** super + vm.core + **proc.sched** |
| `04_hot_reload.bl` | app AND bl-stdlib updates are HOT (atomic per-var swap, no restart); an incoherent edit is HELD with old code still serving | `zero-downtime.md` §L1 | **real** `reload` coherence gate |
| `05_observability.bl` | events are datoms; a dashboard re-runs live on tx; an alert's firing is itself a fact; latency JOINS the deploy boundary | `observability.md` | **real** datom + `datom/watch` |
| `06_backups_dr.bl` | checkpoint leaves the box to **real S3 (Garage)** and restores into a fresh conn; the fence-bounded drill records its own result, so "when did we last prove restore?" is a query | `backups-and-dr.md` | **real** datom + fence + **blob-s3 → Garage** |
| `07_incident.bl` | page→postmortem in one store: the page carries its query, the window is bitemporal, automation and operators share one audit log, the postmortem's action is a datom | `incident-ritual.md` | **real** datom |
| `08_upgrade_refusal.bl` | an upgrade is PROVEN or REFUSED: a missing/unsafe **data** migration and a missing/unsafe **message** migration are each held with a distinct z3-checked reason — never half-shipped | `zero-downtime.md` §L1, `the-reconciler.md` | **real** z3 (`migration-preserves?`, `simulates?`) |
| `09` `podman/blue_green.sh` | a PLATFORM update (new container/OTP/OS closure) is blue-green across real rootless-podman containers behind a stable gateway: one clean cutover, ≤1 in-flight drop | `zero-downtime.md` §L3, `bootstrap.md` | **real** podman + socat + two bl node containers |
| `10_identity.bl` | one capability, end to end: mint → attenuate → authorize → RLS → audit → revoke, all fail-closed | `devops.md` §identity, `fleet.md` §blast radius | **real** `auth` (Ed25519 Biscuit) |
| `11_ssh_access.bl` | ssh terminates in a capped REPL whose caps come from the identity token; forged token forks nothing; per-user memory quota is real | `devops.md` §access | **real** `executor.sandbox/admit` + `auth` |
| `12_ingress_tls.bl` | one TLS listener, a per-name leaf minted by the node's own CA, routed by SNI to the right backend — a real handshake | `devops.md` §ingress | **real** `vm.ca` + Erlang `:ssl` |
| `13_drift_and_proof.bl` | drift is a recorded choice (commit-to-desired vs revert); the reconciler's delta is z3-proved before it applies, and refused with a reason if it would break an invariant | `the-reconciler.md` §drift + §failure-posture | **real** datom + z3 |

## The L1/L3 distinction this suite encodes

The corrected model, and why there are two separate spikes:

- **App + bl updates are HOT** (`04_hot_reload.bl`). Inside the one long-lived
  node, a `defn` swap is atomic per var; the coherence gate refuses anything
  that would dangle. Nothing restarts. This is the common case.
- **Platform updates are blue-green** (`09`). A new container image, a new OTP,
  a new OS closure cannot hot-load — so a *new node generation* comes up beside
  the old and a stable gateway re-claims the public port. This is the rare case,
  reserved for the floor below bl.

Conflating them (an earlier draft blue-greened app deploys) is the mistake this
split exists to prevent.

## The verifier tier is the headline

`08_upgrade_refusal.bl` is the spike that could not be modelled — it runs real
z3 proofs. `migration-preserves?` asks whether the state at rest still satisfies
the invariant after the migration fn; `simulates?` asks whether the new message
handler simulates the old so a queued message survives the swap. A missing or
wrong migration is REFUSED before it ships, the process never stopping. That is
the guarantee the BEAM's own hot-code-load lacks, made into a deploy gate.

## Real vs modelled

- **Real, exercised as-is:** datom (facts, datalog, `as-of`/`since`, `watch`);
  the env capability gate (`env/fork` + compile-in-env denial); OTP supervision
  (`super`); env isolation + teardown (`vm.core`); `fence`; the `reload`
  coherence gate; `proc.sched` recurrence algebra; z3 upgrade/migration proofs;
  `blob-s3` against a real Garage S3; rootless podman containers running real bl
  nodes.
- **Modelled in miniature** (the organ exists but is heavier than a probe needs):
  the gateway is a socat re-point (`vm/gateway.bl` is the real reverse proxy
  with connection draining — it would close even the ≤1-drop window that socat
  leaves); the reconciler's effect application is direct rather than through the
  live `vm.manager`.

## Containment — why 09 runs detached under a cgroup

The container demo is heavy, and this host runs near its memory ceiling with
zram swap. Run synchronously it can thrash the machine. So `run.sh --podman`
launches it **detached** as a transient systemd unit with a hard cap and polls a
file for the verdict:

```
systemd-run --user --unit=bl-bg --collect \
  -p MemoryMax=1200M -p MemorySwapMax=0 -p TasksMax=96 -p RuntimeMaxSec=150 \
  -p StandardOutput=file:/tmp/bg.out  bash podman/blue_green.sh
```

A runaway dies in its own cgroup, the host untouched — the design's
blast-radius thesis applied to the harness itself. `podman/scoped.sh` wraps the
same caps for a foreground run. (Cold `blx` starts cost ~10-15s each for JIT
warmup, so the full 8-spike sweep takes a couple of minutes; that latency is
boot, not work.)

## The infra artifacts

- `flake.nix` — the below-OTP stratum (kernel, firewall, the one systemd unit),
  the declarative shape `bootstrap.md` refers to. Parses under `nix`; not
  applied here (no `nixos-rebuild`).
- `garage/up.sh` — brings up a local Garage S3 (the off-box durable tier),
  rootless, idempotent, emitting creds for `06`.
- `podman/node.bl` — a minimal concurrent bl HTTP node, one per generation.
- `podman/blue_green.sh` + `podman/scoped.sh` — the platform-swap demo and its
  cgroup wrapper.

## The whole point, in one line

Desired state, observed state, history, audit, the deploy proof, and the fix
are all datoms and live processes in one address space — so every devops
question is a query, every action a transaction, and every unsafe upgrade a
refusal with a reason. The spikes are that sentence, executed.
