# The reconciler — the heart of the machine

> Every other document in this folder describes a client of this loop. The
> reconciler is the only thing on a bl VPS that *acts*; everything else is data
> waiting to be diffed.

## The loop

```
desired  := datalog over :service/desired           ; what you asked for
observed := vm.ports claims + process table + envs  ; what is
delta    := reconcile/diff desired observed         ; a pure function
effect   := spawn / drain / reload / re-route       ; capped, logged
```

The loop wakes on events, not on a timer: a transaction against desired state,
a process exit, a claim expiring. Between events the reconciler does not exist
as a cost — it is a `proc.server` waiting on messages.

## Why the delta is a pure function

`reconcile/diff` takes two values and returns a third. It touches nothing.
That purity buys three things:

1. **Testable.** "If desired has two services and observed has one, the delta
   is `spawn`" is a unit test over maps, not an integration test over a
   machine.
2. **Explainable.** A delta is data you can print, log, and — before applying
   — show to a human: *"I am about to drain `billing@main` because desired
   retracted it."*
3. **Provable.** The delta can be handed to `z3` before the effect runs: does
   this set of effects preserve the invariant that every claimed host has a
   live backend? If not, the reconciler transacts the refusal instead of the
   effect.

## Effects are facts

Every applied effect is transacted:

```clojure
{:effect/kind      :spawn
 :effect/svc       "blog"
 :effect/why-delta {:desired 2 :observed 1}
 :effect/at        1790000000123}
```

This single habit replaces most of what conventional infra calls
"observability of the control plane". Why did web restart at 03:12? A query.
What did the last deploy actually do? A query. Has the reconciler ever fought
a human? A query — because human interventions are also datoms (a capped REPL
session transacts its commands), and the two histories join.

## Drift is a participant, not an enemy

Someone hot-fixes a function in a live REPL at 02:00. Conventional infra calls
this configuration drift and fights it with re-runs of the same playbook.

The reconciler treats it as observed-state change and reports the delta. The
operator then chooses, explicitly, in data:

- **commit** — transact the live change into desired state (the fix becomes
  the truth)
- **revert** — the reconciler re-applies desired state (the fix was a
  temporary measure)

The choice is recorded either way. There is no silent third option where the
machine and the truth diverge forever.

## The desired-state schema

Desired state is ordinary datom data. The core attributes:

```clojure
{:service/id        "blog"
 :service/src       "git@…#v1.1"      ; level-1 deploys (zero-downtime.md)
 :service/hosts     ["blog.example.com"]
 :service/heap-words 50_000_000
 :service/schedules [...]             ; services-and-schedules.md
 :service/env-spec  {...}}            ; secrets as capped vars

{:node/generation   "a1b2c3"}          ; level-3 swaps (zero-downtime.md)
```

Observed state is never *stored* — it is read live from `vm.ports`, the
process table, and the env registry at diff time. Storing observations would
create a second truth; the design has exactly one stored truth (desired +
effect history) and one sampled truth (the living node).

## Failure posture

The reconciler is the most important process on the node, so it is also the
most conservative:

- it sits under a `super.bl` tree with a restart budget; its state is
  reconstructible from datom at any moment, so a restart loses nothing
- an effect that fails is retried with backoff, and the *failure* is a datom
- a delta it cannot prove safe (z3 says no, or times out) is transacted as a
  refusal with the counter-example — it errs toward stillness
- it never acts below the OTP line: kernel and firewall are Nix's strata, and
  the reconciler's only below-line verb is *requesting a node generation
  change*, which systemd and NixOS execute
