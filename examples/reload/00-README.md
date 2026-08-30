# reload — the running image is the source of truth, by example

A live-reload layer for beam-lisp where **an edit is a transaction over the
running system**. You stage edits into a *bundle* (the changes since the last
coherent image) and commit; a coherent bundle applies atomically, an incoherent
one is *held* — printing every reason it does not yet make sense — while the old
code keeps serving, until a later edit completes it. Nothing half-applied is
ever observable.

The thesis, in one line: **a `.bl` file is a live handle to a running namespace,
and coherence is checked before anything runs.** The stale-`.beam` bug that
started this whole line of work (`undefined var` from a compiled module that
lagged its source) becomes *unrepresentable as an observable state* — the same
discipline, lifted from build artifacts to live edits.

Design: `!tasks/plans/PLAN-056-*.org`. The layer lives in `priv/reload.bl`
(the reconcile loop) and `priv/reload/migrate.bl` (verified in-flight message
migration), with a dev filesystem watcher in `lib/beam_lisp/reload_watcher.ex`.

Run any file with:

```
mix beam_lisp.run --path priv examples/reload/NN-name.bl
```

## The ladder — zero to the whole thing

| # | file | teaches |
|---|---|---|
| 01 | `01-identity-swap.bl` | redefine a pure fn; callers never notice — the simplest hot swap |
| 02 | `02-dangling-half-bundle.bl` | a half-finished edit is **held**, old code serving, until it is completed |
| 03 | `03-promise.bl` | a `(declare x)` with no definition holds; keeping the promise applies it |
| 04 | `04-bundle-atomicity.bl` | a caller of a new name lands **together** with its callee, or not at all |
| 05 | `05-migrate-verified.bl` | an in-flight message migration, **verified** — R deduced, no annotation |
| 06 | `06-migrate-blocked-repair.bl` | a wrong migration is **blocked** at commit, with a synthesized repair |
| 07 | `07-quiesce.bl` | "pending calmness" — swap only once no message is in flight (a query) |
| 08 | `08-reroute.bl` | transform in-flight messages to the new contract, mid-flight, no loss |

## The one idea per example

- **01** — a live namespace is downstream of its source, so redefining a pure fn
  is an atomic per-var swap; a caller in flight finishes on its captured body.
- **02** — the transaction unit is the *bundle*, not the file, and reload is
  *namespace-level*: the staged source IS the namespace, so a name it drops is
  truly removed. A dangling reference — or a rename that leaves a reference on a
  removed name — holds the whole bundle; the old code serves the entire time.
- **03** — an unfulfilled promise is the static analogue of a queued message: a
  commitment the bundle must honour before it can go live.
- **04** — namespace-level atomicity, the additive face: introducing a caller of
  a *new* name requires the callee in the same bundle, or the caller would
  dangle. All-or-nothing (removal is the other face — see 02).
- **05** — a message queued in a mailbox is an unfulfilled promise; a migration
  fulfils it under the new contract, and `:reroute` verification is **mandatory**
  — the relation it must preserve is *discovered*, no annotation.
- **06** — a migration that could break the invariant is rejected **before** it
  ships, and the checker offers the fix, not just a rejection.
- **07** — quiesce moves *time*: wait until the mailboxes drain. Calmness is a
  datalog-style query over live mailboxes, not a sleep.
- **08** — reroute moves *data*: rewrite each in-flight message to the new shape,
  so a contract change costs no dropped messages.
- **09** — the final boss of monitorability: a pure-`.bl` web server that renders
  the live image and pushes a fresh view to the browser on every reload, so you
  watch namespaces change, holds appear in red with their reason, and migrations
  land — live, no page reload. `reload/subscribe` is the push; `reload/inspect`
  is the read-model behind both this and the CLI monitor.
- **10** — `ward`, a warm isolated test runner built on the reload machinery:
  each file runs in its own env fork (isolation), a load-time crash is contained,
  the source is always-latest, and the base is warm. One misbehaving file can
  never contaminate another — the app-shutdown fragility dissolved by construction.

## Beyond the ladder — the live tooling

The same `reload/inspect` read-model drives two monitors and a runner:

- **CLI monitor** — `mix beam_lisp.reload.monitor DIR` watches a directory and
  repaints the live image (namespaces, vars, journal) after every commit.
- **Web monitor** — demo 09; the browser view of the same snapshot, pushed live.
- **ward** — `mix beam_lisp.ward FILE...` runs `.bl` test files warm, isolated,
  coherence-advised, and always-latest; exits non-zero unless every file is green.

## Namespace-level, and prod-safe

Reload is **namespace-level**: the staged source *is* the namespace, so a name it
no longer defines is genuinely removed (demo 02) — a rename must move every
reference, in-namespace and across namespaces, or the bundle is held. And it is
**prod-safe**: reading the live image is always available, but *mutating* it is
gated — allowed in dev, refused in a release unless `BEAM_LISP_RELOAD=1` opts in,
per node, with a bounded window. The guarantee lives in the running system.
