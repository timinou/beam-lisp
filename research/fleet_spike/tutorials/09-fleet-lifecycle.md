# 09 — The capstone: a whole day in a 2-node fleet

The other eight spikes each teach one algorithm; this one puts them all on one
stage and runs a narrative, so you can watch the per-data-class model compose
into a living system that joins, places, replicates, migrates, survives a
partition, and heals — on real `datom`.

## The problem

You can understand consistent hashing, CRDTs, Raft, gossip, and SWIM perfectly
in isolation and still not know **how they fit together**. A real fleet doesn't
run one algorithm; it runs all of them at once, each on the data class it suits,
and the interesting behaviour is in the *seams* — what happens to events while
desired state is mid-migration, what a node does with routes when it's cut off,
how health and replication interact on heal. A per-algorithm spike can't show
that. This one is built to.

## The idea

Model two nodes as two `datom` connections, and the network as a value you can
cut and restore. Then run a scripted day in seven scenes, and at each scene let
the *right* algorithm do the *real* work:

```
SCENE 1  join        → single-writer election        (06_raft)
SCENE 2  place        → HRW rendezvous                 (01_sharding)
SCENE 3  replicate    → log-shipping (basis-t/facts)   (02 + datom)
SCENE 4  route/emit   → OR-Set + G-Set, union merges   (03, 02)
SCENE 5  migrate      → desired-state delta, gen bump   (the reconciler, 01_reconciler)
SCENE 6  partition    → quorum refuses the fork + SWIM  (06, 07)
SCENE 7  heal         → catch-up ship + LWW health      (04)
```

The thesis the whole day proves: **the classes that must not fork (desired
state) are gated by consensus; the classes that only need to converge (events,
routes, health) merge freely; and the two regimes coexist on one substrate
without fighting.**

## How it works

The load-bearing move is that **all fleet data lives in the same `datom`, but
different attributes are governed by different rules**:

- `:svc/host`, `:svc/gen` — **desired state**. Only the leader writes them
  (single-writer), and a write is legitimate only with a quorum. During a
  partition the minority *cannot* reach quorum, so it cannot write — the fork is
  refused at the arithmetic, not patched up afterwards.
- routes and events — **AP data**. Modelled as an OR-Set and a G-Set; their
  merge is set union, a join-semilattice, so they converge from any order with
  no coordinator. They keep flowing even while desired state is frozen.
- health — an **LWW-Register**; a later timestamp wins, so heal is just a newer
  observation superseding the stale "suspect".

Replication is **log-shipping**: the follower applies the leader's desired-state
facts (`datom/transact!` of the projected `[id host gen]` tuples), and because
`:svc/id` is a `:db.unique/identity`, re-applying the same fact is idempotent —
shipping the log twice changes nothing. That idempotence is what makes catch-up
on heal safe.

## Walkthrough

**The substrate — two nodes, real datom.**

```clojure
(def dstate-schema
  [{:db/ident :svc/id   :db/valueType :db.type/string :db/unique :db.unique/identity}
   {:db/ident :svc/host :db/valueType :db.type/string}
   {:db/ident :svc/gen  :db/valueType :db.type/long}])
(defn new-node [] {:conn (datom/connect dstate-schema) :basis 0})
(def vps1 (atom (new-node)))
(def vps2 (atom (new-node)))
```

Each node is a real `datom` connection plus a `:basis` cursor (its replication
watermark — the same `basis-t` from spike 02).

**Log-shipping — the replication primitive.**

```clojure
(defn ship! [from-node to-atom]
  (let [facts (desired-facts from-node)
        r (datom/transact! (:conn (deref to-atom))
            (vec (map-indexed (fn [i f] {:db/id (- (- i) 1) :svc/id (nth f 0)
                                         :svc/host (nth f 1) :svc/gen (nth f 2)}) facts)))]
    (swap! to-atom assoc :basis (datom/basis-t (:db-after r)))))
```

Project the leader's desired-state facts, transact them into the follower,
advance the follower's basis. Upsert-on-unique makes it idempotent.

**Scene 1 — join & elect.** Single-writer discipline (spike 06): one node owns
desired-state writes. `majority = (inc (quot (count cluster) 2))` = 2 for two
nodes. `vps-1` is the writer.

**Scene 2 — HRW placement.** Each service is placed on the node with the highest
`hash(node|key)` (spike 01), then the leader transacts that desired state:

```clojure
(defn hrw-host [key] (second (reduce (fn [best n]
                                       (let [w (h (str n "|" key))]
                                         (if (> w (first best)) [w n] best)))
                                     [-1 nil] cluster)))
```

The run places `billing → vps-1` and `api → vps-2` — a natural split, balanced
across the two nodes.

**Scene 3 — replicate.** `ship!` copies the leader's facts to the follower; the
scene asserts `(= (desired-facts vps1) (desired-facts vps2))` — converged.

**Scene 4 — coordination-free data.** Routes as an OR-Set (add-wins, spike 03),
events as a G-Set (union, spike 02). Both merge without touching the leader —
this is the AP half of the fleet running in parallel with the CP half.

**Scene 5 — migrate.** The operator flips `billing`'s host and bumps `:svc/gen`
to 2; `ship!` replicates; both nodes now see `billing` on the new host. This is
the reconciler's desired-state delta (spike 01 / 13) crossing a node boundary.

**Scene 6 — partition (the climax).**

```clojure
(defn can-commit? [reachable-count] (>= reachable-count (majority)))
(def follower-write-refused (not (can-commit? follower-alone)))   ; 1 < 2 → true
(def swim-verdict (if (deref network-up) :alive :suspect))
```

The cut-off follower tries a *conflicting* write. Quorum arithmetic refuses it
(1 reachable < majority 2), so reality does not fork. Meanwhile SWIM on the
leader (spike 07) marks the follower `:suspect` after direct and indirect probes
fail. The minority stalls; the leader keeps serving reads. This is the
split-brain guarantee, live.

**Scene 7 — heal.** Network restored, the follower catches up via `ship!`, and
LWW health (spike 04) supersedes `:suspect` with a fresh `:up @ts 20`. The final
assertion: leader and follower desired state are identical again.

## Where it fits the fleet

This *is* the fleet — every data class from
[`../README.md`](../README.md)'s table, doing its job at once:

| scene | data class | algorithm | tutorial |
|---|---|---|---|
| place | placement | HRW | [01](01-sharding.md) |
| events | events | G-Set | [02](02-gset-crdt.md) |
| routes | routes | OR-Set | [03](03-orset.md) |
| heal | health | LWW | [04](04-lww.md) |
| elect/partition | desired state | Raft quorum | [06](06-raft.md) |
| partition | failure detect | SWIM | [07](07-gossip-swim.md) |

The one thing it deliberately shows *not* merging is desired state under
partition — the exception that the whole per-data-class argument is built
around.

## What's real vs modelled

**Real:** two independent `datom` connections with a real unique-identity schema;
real `transact!`/`q`/`basis-t`; real log-shipping with idempotent upsert; real
OR-Set / G-Set / LWW merge algebra; real HRW placement; real quorum arithmetic
refusing a minority write.

**Modelled:** the "network" is an atom (`network-up`) we flip, not real sockets —
partition is simulated by choosing what `ship!` runs and what `reachable-count`
is; the transport in production is BEAM messaging and is not under test. The
Raft layer is the **safety core** (single-writer + quorum refusal), not the full
Ra protocol — production uses **Ra** (rabbitmq/ra), exactly as spike 06's
tutorial explains. SWIM is a single verdict, not the full probe/suspicion state
machine. Events/routes are in-process values, not shipped over a real link.

**The honest 2-node caveat:** with two nodes, majority = 2, so a single node
failure loses quorum and *halts* desired-state writes (reads continue). That is
correct and deliberate — it is exactly why production runs **3 or 5** nodes, so
one can fail and a majority still exists. The spike uses two to keep the
narrative legible; the arithmetic generalizes directly.

## Run it

```
./blx run research/fleet_spike/09_fleet_lifecycle.bl
```

Expected final line (after the seven narrated scenes):

```
PASS 09_fleet_lifecycle  (join→place→replicate→migrate→partition→heal, all algorithms)
```

Cold start ~10-15s (JIT warmup).

## Exercises

1. **Add a third node.** Extend `cluster` to `["vps-1" "vps-2" "vps-3"]`. Predict:
   how does HRW re-place the services? What is the new majority, and can the
   fleet now survive one node failing while still committing desired state?
   (This is the 2→3 fix the caveat points at.)
2. **Partition the leader instead of the follower.** Cut off `vps-1`. Predict:
   can the lone follower elect itself and commit? (With 2 nodes, 1 < majority 2
   — so no; the fleet stalls writes entirely. Now redo with 3 nodes and cut off
   1 — predict which side keeps writing.)
3. **Make events conflict.** Give both nodes an event with the *same* bare id and
   different values, un-tagged by node. Predict what the G-Set union does and why
   the node-tag in the real spike prevents it (cross-reference spike 02's id
   partitioning).
4. **Delay the heal.** Between scene 6 and 7, transact three more desired-state
   changes on the leader. Predict: after `ship!` on heal, does the follower reach
   the *latest* state or an intermediate one, and why does idempotent upsert make
   either safe?
