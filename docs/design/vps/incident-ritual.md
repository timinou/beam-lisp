# The incident ritual

> Most of an incident's clock time is not diagnosis — it is context-switching
> between tools that each hold one shadow of the truth. The bl incident ritual
> has one tool and one prompt, because the truth was never split.

## The shape of a page

An alert is a datom. It arrives with its own evidence attached:

```clojure
{:alert/id    :p95
 :alert/fired-at 1790000000123
 :alert/value  1840
 :alert/svc    "blog"
 :alert/query  [...]}    ; the exact query that fired — re-runnable
```

You do not wonder what the alert meant. You re-run its query against a later
time and see whether it still fires.

## The five steps

```
1. page        → the alert datom, with its query and value
2. arrive      → ssh ops@vps → capped bl REPL (your key's token, your caps)
3. query       → the incident window, bitemporal, exact:
                   what changed (tx log), what the system believed (as-of),
                   what the reconciler did (:effect/why-delta)
4. reach in    → the live env: mailboxes, reductions, a trace on the hot fn;
                 then hot-fix in place, or drain the env and let desired
                 state respawn it clean
5. close       → the postmortem is transacted into the same db that paged you
```

Step 3 and 4 are the same prompt. That is the entire trick.

## What each question becomes

| incident question | the answer |
|---|---|
| what changed? | `[:find ?tx ?attr :where [?tx :tx/at ?t] [(> ?t window)]]` — deploys, config, secrets, all of it |
| what did the system believe? | `(datom/as-of t0300)` — the db value at the moment it broke |
| what did the automation do? | the effect log: every reconciler action, with its reason |
| is it still happening? | re-run the alert's query against now |
| who touched it? | the audit datoms — REPL sessions transact their commands too |
| what did we do last time? | `[:find ?pm :where [?pm :postmortem/svc "blog"]]` — postmortems are queryable |

## The postmortem loop closes itself

A postmortem conventionally decays into a wiki page nobody queries. Here it is
data:

```clojure
{:postmortem/svc     "blog"
 :postmortem/at      …
 :postmortem/cause   {:tx 1234 :attr :service/src}
 :postmortem/fix     "drained env; contract check now rejects v1.1"
 :postmortem/action  [{:kind :add-alert :query …}]}
```

The action items are datoms — an `add-alert` action is picked up by the
reconciler and becomes a real schedule. The incident *produces* its own
prevention, in the same transaction that records it.

## On-call ergonomics

- the alert, the evidence, the fix, and the record are one store — nothing to
  correlate across vendors at 03:00
- your REPL is capped: an exhausted operator with production access still
  cannot `System/halt` the node — the capability stack is the guardrail when
  judgment is weakest
- every command you ran during the incident is in the audit log, so the
  postmortem's timeline section writes itself from facts, not from memory

## When the ritual is not enough

The ritual assumes the node is alive. If it is not: systemd restarts it, envs
rehydrate from datom (`services-and-schedules.md`), and if the node cannot
come back at all, the ritual moves to a fresh VPS via bootstrap + restore
(`bootstrap.md`, `backups-and-dr.md`). The incident becomes a DR drill that
was already scheduled to be proven quarterly — the difference is that this
time it is for real.
