# Zero-downtime, fully declarative

> The rule: downtime is never *performed*, it is *designed out*. Every level at
> which change can happen has a declared transition, and the transition is data
> in the same system that converges everything else.

## The three levels of change

A bl VPS has exactly three places where code or configuration can change, and
each has its own zero-downtime mechanism:

| level | what changes | mechanism |
|---|---|---|
| 1 — code | a function, a namespace | hot reload: old and new coexist, contract checked, state migrated |
| 2 — service | a whole environment | drain + respawn with state carried by the owner registry |
| 3 — node | the bl closure, OTP, NixOS generation | blue/green node swap under the gateway |

Levels 1 and 2 happen inside the long-lived node and never interrupt anything.
Level 3 is the interesting one.

## Level 1: hot reload is the default

A deploy is a desired-state change (`:src "git@…#v1.1"`). The reconciler loads
the new code *beside* the old (`reload/ward`), proves the new contract or
produces an explanation of how it changed (`z3`), migrates state
(`reload/migrate`), and cuts over. Prior versions stay loaded, so rollback is
a pointer, not a procedure.

A canary is a datom branch: the gateway serves the new version to 5% of
claims, the promotion is a transaction, and the fold-back is another. Nothing
restarts at any point.

## Level 2: environment swap

When a change is too deep for reload — a new supervision shape, a new heap
ceiling — the whole environment is replaced: drain the old env (its processes
finish in-flight work), spawn a new capped fork, and the owner registry hands
across the durable state. From the gateway's side the name is briefly re-claimed;
from the client's side nothing happened.

## Level 3: the node swap — where Nix earns its keep

A new bl closure or a new NixOS generation cannot hot-load (the closure is
immutable; that is the point of Nix). The answer is to treat *the node itself*
as a deployable unit with the same discipline as a service:

```
1. flake builds generation N+1            (pure, off the critical path)
2. systemd starts bl-node@next from it    (second node process, internal ports)
3. envs migrate live:                     state checkpoints to datom,
   drain on old, spawn on next            rehydrate on the new node
4. gateway re-claims each name            connections splice to the new node
5. old node drains to empty, unit stops   the old generation stays bootable
```

Why this works on a bl VPS and is painful elsewhere:

- **The gateway is a separate OS process.** `vm/gateway.bl` already runs
  outside the node it fronts, holding :80/:443 and a route table fed by port
  claims. A node swap is, to the gateway, just a re-claim storm — the same
  event as any service restart. It never lets go of the ports.
- **State is portable by construction.** An env's durable state lives in datom,
  not in the process — so "move the service to the other node process" is the
  level-2 mechanism with a wider target.
- **NixOS generations make the lower stratum symmetrical.** The old closure is
  still on disk and still bootable; a failed swap is `nixos-rebuild
  --rollback` *and* the old node process is still running anyway.

## Declared, not orchestrated

The swap is not a runbook a human executes. Desired state carries
`:node/generation`, and the reconciler's effect vocabulary includes
node-level effects: `start-next`, `migrate-env`, `reclaim`, `stop-prev`. Each
effect is transacted with its reason, so the answer to "what did the last node
upgrade do, step by step" is a datalog query.

The flake declares both node profiles. During a transition the configuration
literally contains two generations; when the reconciler reports the old node
empty, the transition datum is retracted and the configuration collapses back
to one. **The transition is part of the state, not an exception to it.**

## The two honest exceptions

1. **Kernel upgrades need a reboot.** On a fleet: migrate envs to a sibling
   node, reboot, rejoin — the same machinery as level 3, one floor lower. On a
   single node: a maintenance window, or `kexec` to shrink it to seconds.
2. **First boot.** Day 0 is cold by definition (`bootstrap.md`).

Everything else — every deploy, every config change, every bl upgrade — is
zero-downtime, and *declared*: the system knows a transition is happening
because the transition is data.
