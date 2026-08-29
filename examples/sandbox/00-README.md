# examples/sandbox — capabilities, forks, and processes under authority

`examples/auth/` tells the **identity** story: a Biscuit token is a value, it
verifies offline, it only ever narrows, and `authorize` is a pure function
over token + request + policy.

This folder is the **enforcement** story — what happens *after* the decision.
A verdict is only worth as much as the boundary it creates, and here that
boundary is a real thing you can hold: an **environment**, a world of callable
code whose rights are the intersection of its parent's and the token's. Code
inside it cannot even *name* what it wasn't granted; processes it spawns carry
the same ceiling; every decision leaves a datom behind.

If `auth/` answers *"who are you and what may you ask?"*, `sandbox/` answers
*"…and what can your code actually reach when it runs, and when it forks a
thousand workers?"*

## The through-line

```
Biscuit token  ──auth/sandbox-fork──▶  env (caps = parent ∩ token)  ──▶  processes
   (identity)                              (the sandbox)                (the work)
        │                                       │                          │
   examples/auth/                         01, 02, 03                  04, 05, 06
```

## The files

| # | file | the idea |
|---|------|----------|
| 01 | `the-env-is-a-world.bl` | an env is a world of callable code; the gate rejects at **compile time** |
| 02 | `forking-only-narrows.bl` | a fork is parent ∩ spec — monotonic, never widening, even for grandchildren |
| 03 | `a-token-becomes-a-sandbox.bl` | `auth/sandbox-fork` turns a token's rights into an env's caps in one call; revoked/expired tokens never fork |
| 04 | `processes-carry-the-env.bl` | env bindings don't cross `spawn`/`Task.async` by accident — `capture`/`bind` carry them **deliberately**; a stale token fails closed |
| 05 | `the-confused-deputy.bl` | a `:global` server leaks its authority to any caller — unless it **conveys** the caller's env |
| 06 | `the-audit-trail.bl` | every verdict, allow *and* deny, becomes one datom: who was turned away, and why |

## The one doctrine to remember

The gate governs **new compilation and dynamic forging inside a capped env**.
It does **not** re-mediate code already compiled at `:global` — by design the
base image is part of the parent's authority (setuid-helper semantics). So the
operator's rule is simple and appears in 05: *anything a sandbox must not do
must not be reachable through a `:global`-loaded wrapper either.*

## Running

```sh
mix beam_lisp.run --path priv examples/sandbox/01-the-env-is-a-world.bl
```

Each file is self-contained and prints its own narration. Read them in order;
01–02 need no auth at all (pure env mechanics), 03 onward tie the token back in.
