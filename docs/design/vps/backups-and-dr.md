# Backups and disaster recovery

> A backup system is judged by one question: when did you last *prove* a
> restore works? On a bl VPS the proof is a scheduled function whose results
> are datoms — so the answer to the question is itself a query.

## The layers

| layer | mechanism |
|---|---|
| live database | `datom` over `store-fjall` — a durable KV on the node's btrfs subvolume |
| blobs | `blob-s3` — content-addressed, off-box by construction |
| checkpoints | a `proc/sched` job: datom checkpoint → S3, nightly plus before every level-3 swap |
| history | bitemporality (`time.bl`) — the past is queryable in place |
| deletion | `excise` on a policy schedule — audited, first-class |

## Checkpoints are ordinary schedules

```clojure
(proc.server/defserver backups
  (sched (daily 03 00 :checkpoint checkpoint! {:catch-up :coalesce})
         (every 6 :hours :wal-tail ship-wal! {:catch-up :skip})))
```

Because schedules are data (`services-and-schedules.md`), the backup policy is
part of desired state: change the retention, change the datom. Because every
occurrence is recorded, "did the backup run last night" is answered by the
same database the backup protects — and if the database is down, the *absence*
of the checkpoint datom on S3 is itself the alarm.

## Restore is bootstrap plus one step

A dead node:

```
nixos-anywhere --flake .#vps-1 root@<new-ip>   # day 0 again (bootstrap.md)
→ node boots, transacts birth, syncs or restores datom from latest checkpoint
→ reconciler converges services from desired state
```

The machine's below-OTP identity is the flake; its above-OTP identity is the
checkpoint. Nothing else needs to survive.

## The restore drill

The drill is not a document. It is a scheduled function:

```clojure
(defn restore-drill! []
  (fence {:ms 600000}                    ; bounded: 10 min, then killed
    (let [scratch (restore-into-scratch-env (latest-checkpoint))]
      (transact! {:drill/at (now)
                  :drill/result (smoke-query scratch)
                  :drill/checkpoint (checkpoint-id)}))))
```

`fence` bounds the drill so a wedged restore cannot hold the node. The result
lands in datom, where the standing query
`[:find (max ?t) :where [_ :drill/at ?t]]` is the compliance answer, and an
alert fires when that max ages past its policy.

## Bitemporality replaces log rotation

Conventional stacks rotate logs because the past is expensive. Datom's past is
the index — `as-of` queries answer "what did the system believe at 03:12" at
any depth, for free. Retention is then a *deliberate* act: `excise` with a
declared policy, each excision itself a transacted, audited fact. GDPR-style
deletion is a feature of the store, not a grep over rotated files.

## Failure arithmetic

| failure | answer |
|---|---|
| node disk dies | reprovision from flake + restore checkpoint; RPO = last WAL ship |
| S3 unavailable | checkpoints queue locally; the missed occurrence is a datom and an alert |
| bad data transacted | as-of rollback to before the transaction — a value, not a restore |
| drill fails | that is the drill working: the failure is a datom, paged, fixed |
| split-brain restore | one writer rule enforced at the reconciler; see `fleet.md` |
