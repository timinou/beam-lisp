# Fleet — many nodes, one truth, and the honest frontier

> A single bl VPS needs nothing above it. A fleet needs exactly one new idea —
> shared desired state — and inherits one hard problem: keeping that state
> consistent across nodes. This document is honest about both.

## What scales and what does not

The two strata scale differently:

- **Below OTP** (NixOS): trivially. The fleet is one flake evaluated per
  hostname; `nixos-rebuild` per node, or a blue/green swap per node
  (`zero-downtime.md`). Nix has solved fleet-wide declarative OS config for
  years; we inherit the solution whole.
- **Above OTP** (datom desired state): this is the frontier. One logical
  desired-state store, RLS-partitioned per host, every node's reconciler
  converging only its own slice.

## The topology

```
              datom cluster (desired state, events, audit)
              ┌─────────────┬──────────────┐
        node vps-1      node vps-2     node vps-3
        reconciler      reconciler     reconciler   ← each sees only its slice
        gateway :80/443 gateway        gateway      ← any node can front any name
```

BEAM distribution connects the nodes, with a Biscuit in place of the shared
cookie — cross-node calls carry capabilities, not ambient trust
(`vm/wire.bl` is the embryo). The gateways agree on names through the port
claims and the cluster interface: a name is claimed on whichever node hosts
the service, and the others forward.

## Moving a service between hosts

The level-3 node swap (`zero-downtime.md`) with a wider target:

1. desired state now says `{:service/host "vps-2"}`
2. vps-2's reconciler sees a spawn delta; vps-1's sees a drain
3. state checkpoints to the shared store; the env rehydrates on vps-2
4. the name is re-claimed; the gateways' route tables converge

No orchestrator decided this — there is no scheduler above the nodes, because
the datalog *is* the scheduling input and each reconciler is its own executor.
Nomad and Kubernetes dissolve the way systemd did: their job was to reconcile
desired state across machines, and both halves of that already exist here.

## The hard problem: datom consistency

Single-node datom is a solved story (durable store, bitemporal, branches). A
clustered datom must choose, and the choice is real:

| option | gives | costs |
|---|---|---|
| single writer + replicas | simplicity, strong consistency | writer is a SPOF for *transacts* (reads still served during failover) |
| Raft-replicated log | no SPOF, linearizable writes | an actual consensus implementation to maintain |
| CRDT-style merge | partition tolerance | conflicts become possible — desired state with merge conflicts is a new failure mode |

The design's leaning: **single writer with Raft-elected failover**, because
desired state is low-write (deploys and config changes, not request traffic),
events are partitionable per node and merged read-side, and simplicity in the
control plane is worth more than write availability during a partition.

This is deliberately documented as *unsolved and chosen-tentatively* — it is
the one place where the bl VPS design has real engineering ahead of it rather
than assembly of existing organs.

## Blast radius in a fleet

The capability story holds across nodes because tokens, not topology, carry
authority. A compromised node can transact only what its token allows — its
own slice — and every transact is audited. A token attenuated to
`{:host "vps-2" :svc "blog"}` cannot see vps-1's desired state at all (RLS),
so a lateral-movement attempt hits a query that returns nothing, not a
permission error that reveals the shape of what it cannot see.

## Failure arithmetic

| failure | answer |
|---|---|
| a node dies | its services' desired state re-targets to survivors (or waits, per policy); restore on reprovision is `bootstrap.md` |
| the writer node dies | Raft elects a new writer; transacts pause for the election — seconds, and reads never pause |
| network partition | each side keeps serving (envs are local); transacts happen only on the writer's side; the minority side's reconcilers refuse to act on stale reads |
| the whole fleet dies | the flake + the checkpoints rebuild it; the drill for this is the same restore drill, run fleet-wide |
