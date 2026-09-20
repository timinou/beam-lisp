# 06 — Raft: one agreed truth, or none at all

**Thesis.** Raft is the consensus algorithm a fleet uses for its *desired state* — the one data class
where converging to *any* answer is not good enough, because a convergent-but-wrong answer ("billing
runs on vps-1" *and* "billing runs on vps-3", both believed) is a split brain; Raft's whole job is to
make that outcome impossible by refusing to make progress at all without a majority.

Spike: [`research/fleet_spike/06_raft.bl`](../06_raft.bl). Design context:
[`research/fleet_spike/README.md`](../README.md).

## The problem

Start with the naive answer. Every node keeps a copy of the fleet's desired state and writes go to
whichever node you happen to talk to. On a quiet network with no failures this looks fine: everyone
eventually hears about every change and they all agree.

Then the network partitions.

```
        {n1 n2}   ╎   {n3 n4 n5}
     (client A)   ╎   (client B)

A: "billing runs on vps-1"   ╎   B: "billing runs on vps-3"
```

Both sides keep serving writes, because neither can see the other and nothing tells it to stop. Each
side is internally consistent. Each side tells its client "done." The partition heals and now you
have two mutually contradictory facts that are *both* marked committed: one of them is guaranteed to
be a lie, and nothing in the system knows which. The reconciler then fails over a service that was
already running somewhere else, or worse, two hosts both believe they own the recovery of the same
database.

This is the *desired state* problem (see the README's table, row 1). Which host runs `billing` is not
a value that can be merged — it is not a set you can union, it is not a version you can take the max
of. The fleet needs **one truth**, and the honest way to get one truth under partition is to *choose
correctness over availability*: one side keeps working and the other side stops accepting writes,
loudly, until the network heals.

The critical failure mode to internalise is that a "convergent" algorithm is *worse* here, not
better. A CRDT would happily merge the two conflicting placements above into some definite value.
That value would be wrong — it would name one host for a service that another half of the fleet
already committed to a different host. Consistency in the sense of "everyone agrees" is not the goal;
*agreement on the right thing* is. That distinction is the entire reason this spike exists.

## The idea

Give the cluster a way to pick **one** node whose opinion counts, and then make sure that at most one
such node can exist at a time. Call that node the **leader**. Followers don't accept writes; they
forward to the leader or reject. Now there is a single serialisation point and desired state is
totally ordered.

How do you elect exactly one leader, ever, with a network that lies and machines that crash?

Two ideas, composed:

**1. Terms — a logical epoch.** Every node carries an integer `term`, monotonically increasing. A
term is a round number: "the cluster is now operating in election-round 7." Terms make time
comparable without clocks. If a node sees a message from a *higher* term, it knows it is behind and
steps down to follower. Term arithmetic is just integers — no wall clocks, no skew, no NTP.

**2. Strict majority — a quorum.** A node becomes leader only by collecting votes from a **majority**
of the cluster; an entry is **committed** only once a majority has stored it. For 5 nodes a
majority is 3 (⌊5/2⌋+1 = 3).

Now the whole safety argument falls out of one piece of arithmetic:

```
any two majorities of a 5-node cluster have ≥1 node in common
   |M₁| + |M₂| = 3 + 3 = 6  >  5 = n
   ∴ M₁ ∩ M₂ ≠ ∅                    (two subsets of size ≥3 of a 5-set must overlap)

no node votes twice in the same term
   ∴ two leaders in one term would need two overlapping majorities,
     and the shared node would have to vote twice ✗
   ∴ ≤ 1 leader per term ✓           — and the same overlap
     protects commits, not just elections
```

That `6 > 5` is not a detail. It is the load-bearing fact. Everything else in Raft — heartbeats,
log matching, election timeouts — exists to make this overlap *usable* at runtime. The spike asserts
the overlap itself, and then demonstrates the consequence: a side with fewer than a majority can
neither elect nor commit, so the minority stalls. Stalling is the point. A stalled minority is a
loud, correct "I don't know" — infinitely better than a confident wrong answer.

## How it works

The mechanism, stated as the law the spike maintains:

> **Law (majority safety).** A decision (a leader's election, a log entry's commit) is valid only if
> a strict majority of the *cluster* has endorsed it. Two valid decisions of the same kind therefore
> share a node; that shared node never endorses two conflicting decisions, so conflicting decisions
> cannot both be valid.

Break it down:

- **State per node.** `:term` (epoch), `:voted-for` (who this node endorsed this term, or `nil`),
  `:role` (`:follower`/`:candidate`/`:leader`), `:log` (the ordered entry list), `:commit` (the
  highest log index this node knows to be committed). The spike carries all of these fields in the
  node map; see the fidelity note below about which ones it actually exercises.
- **Election.** A candidate bumps its term (`new-term = term + 1`) and asks for votes. A voter grants
  iff the candidate's term is at least its own and it has not already voted in that term. Count
  ≥ ⌊n/2⌋+1 → leader.
- **Replication.** The leader appends entries (commands) to its log and ships them to followers. An
  entry is *committed* when a majority has stored it; only then may the state machine apply it. THIS
  is the step that makes the desired state durable and single-valued.
- **Why the overlap covers commits too.** Suppose two conflicting entries both "committed." Each
  needed a majority to store it. Two majorities overlap → some node stored both → that node's log
  contains a contradiction, which the log-matching property (one leader per term, entries never
  rewritten) forbids. Same overlap, second application.
- **Why a minority must stall.** A minority side can *try* to elect and *try* to commit; it simply
  cannot reach ⌊n/2⌋+1. So its writes never become committed truth. When the partition heals, the
  majority's log is the log; the minority's uncommitted speculation is discarded and the minority
  catches up. Reality has one history.
- **The CAP reading.** Under partition you may keep consistency or availability. Desired state is the
  class where the fleet picks **C over A**, deliberately. That is what "the minority cannot commit"
  means operationally — the price is paid in availability, on purpose.

Note what Raft does *not* claim: it does not make progress without a majority. Safety holds always
(no forks, ever); liveness is conditional on a majority being reachable and the network eventually
delivering messages. That is the correct trade for desired state and the wrong trade for events or
routes — which is exactly why the fleet is factored per data class instead of picking one algorithm.

## Walkthrough

Every stage below is a block of `06_raft.bl`. Reproducing the arithmetic by hand gives the printed
lines shown; the file prints one section header per stage and ends with a single `PASS`/`FAIL` line.

### Stage 0 — node state and the majority rule

```clojure
(defn node [id] {:id id :term 0 :voted-for nil :role :follower :log [] :commit 0})
(def cluster ["n1" "n2" "n3" "n4" "n5"])           ; 5 nodes ⇒ majority = 3
(defn majority [ids] (inc (quot (count ids) 2)))    ; 3
```

A node is a plain map. `majority` is the strict-majority function: `quot` is integer division, so for
5 nodes `(quot 5 2)` is 2 and `inc` gives **3** — strictly more than half. The `inc` matters: for an
even cluster of 4 it yields 3, not 2, because 2-of-4 is *not* a majority and would let two disjoint
sides each claim one (the classic even-split ambiguity Raft forbids). `:role` starts `:follower` —
nobody is born leader. This one function is reused for both the election threshold and the commit
threshold; there is exactly one definition of "majority" in the spike.

### Stage 1 — a healthy election

```clojure
(defn request-votes [nodes candidate-id reachable]
  (let [cand (get nodes candidate-id)
        new-term (inc (:term cand))
        voters (filter (fn [id] (contains? (set reachable) id)) (keys nodes))
        granted (filter (fn [id]
                          (let [v (get nodes id)]
                            (or (= id candidate-id)              ; votes for self
                                (>= new-term (:term v)))))       ; fresh enough term
                        voters)]
    {:term new-term
     :votes (count granted)
     :elected (>= (count granted) (majority cluster))
     :voters granted}))
```

`request-votes` is the election as a pure function: nodes in, tally out. Walk it:

1. `new-term` — the candidate advances the epoch by one (`term + 1`). Nothing mutates; the function
   *computes* the term a real election would run in.
2. `voters` — only nodes that are **reachable**. This is where the network enters the model. The
   candidate can only count votes it can actually collect; a partitioned-away node is not a vote,
   even though it is a member.
3. `granted` — the candidate votes for itself, and each reachable node grants iff the candidate's
   term is at least its own (`>= new-term (:term v)`). Since every node starts at term 0 and the
   candidate proposes term 1, that holds for all of them.
4. `:elected` — compare the tally against `(majority cluster)`, i.e. 3, **not** against the size of
   the reachable set. This is the crux: quorum is a property of the *cluster*, so shrinking the
   reachable set shrinks the votes without shrinking the bar.

Driving it with all five reachable:

```clojure
(def nodes0 (into {} (map (fn [id] [id (node id)]) cluster)))
(def elect-all (request-votes nodes0 "n1" cluster))
```

prints:

```
── election, all 5 reachable ──
  n1 runs in term 1, got 5 votes (need 3) → elected: true
```

Five votes, three needed, leader elected. Note the candidate counted its own vote — that is real
Raft, and it is why the smallest useful cluster is 3 (a lone node plus one peer still can't reach a
majority of 3 by itself).

### Stage 2 — replicate desired state, commit by majority

```clojure
(defn replicate [reachable value term]
  (let [stored (count (filter (fn [id] (contains? (set cluster) id)) reachable))]
    {:value value :term term
     :stored stored
     :committed (>= stored (majority cluster))}))
```

`replicate` is the commit decision, also pure. The leader proposes `value` at `term`; the function
counts how many cluster members stored it and commits iff that count is a majority — again measured
against `(majority cluster)`, never against the reachable set. `(contains? (set cluster) id)` is a
membership filter: only real members count toward a quorum (an impostor's copy is worthless). The
return value is the whole verdict: `{:value :term :stored :committed}`.

```clojure
(def commit1 (replicate cluster {:service "billing" :host "vps-2"} (:term elect-all)))
```

The value being replicated is literally a desired-state assertion — "billing runs on vps-2" — and the
term is the one from Stage 1, tying the committed entry to the epoch that elected the leader.

```
── replicate desired state {billing→vps-2} ──
  stored on 5/5 → committed: true
```

### Stage 3 — split brain: partition the cluster

```clojure
(def minority ["n1" "n2"])
(def majority-side ["n3" "n4" "n5"])
(def elect-min (request-votes nodes0 "n1" minority))
(def elect-maj (request-votes nodes0 "n3" majority-side))
```

The partition is expressed by handing each candidate only its own side as `reachable`. Both calls
start from `nodes0` (everything at term 0), so both candidates propose term 1 and each counts votes
from its own side: n1 gets 2, n3 gets 3.

```
── partition: {n1,n2} | {n3,n4,n5} ──
  minority n1: 2 votes → elected: false
  majority n3: 3 votes → elected: true
```

Exactly the promised asymmetry. The minority *cannot* elect — 2 < 3 — while the majority side elects
normally. Note that both sides believe they are campaigning for term 1; the difference is not the
term, it is whether the votes reach a quorum.

### Stage 4 — two conflicting commits, one survivor

```clojure
(def commit-min (replicate minority {:service "billing" :host "vps-1"} (:term elect-min)))
(def commit-maj (replicate majority-side {:service "billing" :host "vps-3"} (:term elect-maj)))
```

Both sides write a desired state for the same service, to *different hosts*. This is the fork we are
trying to prevent, handed to the algorithm on purpose.

```
── each side tries to commit a CONFLICTING placement ──
  minority commit {billing→vps-1}: false  (stored 2/5)
  majority commit {billing→vps-3}: true  (stored 3/5)
  ∴ no split-brain: the minority CANNOT commit; reality does not fork.
```

The minority's `{billing→vps-1}` exists only as uncommitted speculation. It is not truth, will never
be handed to the reconciler, and dies on heal. The majority's `{billing→vps-3}` is the single
committed reality. Two conflicting values were *attempted*; only one became real. That is the
guarantee, demonstrated rather than asserted in prose.

### Stage 5 — the safety core, stated as arithmetic

```clojure
;; Any two subsets of size >= majority(5)=3 share at least one node. That node
;; would have to vote twice in one term, which it refuses — so ≤1 leader per term.
(def overlap-guaranteed (> (* 2 (majority cluster)) (count cluster)))  ; 2*3 > 5
```

This is the same `6 > 5` from `## The idea`, now a computable predicate: twice the quorum exceeds the
cluster size. `overlap-guaranteed` is `true`, and it is checked in the assertions, so the spike does
not merely *use* the majority rule — it *proves* the majority rule has the overlap property on this
cluster. If someone changed `majority` to something weaker, this assertion is what would go red.

### Stage 6 — the verdict

```clojure
(def ok (and (:elected elect-all)          ; healthy election succeeds
             (:committed commit1)          ; majority commits desired state
             (not (:elected elect-min))    ; minority CANNOT elect a leader
             (:elected elect-maj)          ; majority side CAN
             (not (:committed commit-min)) ; minority CANNOT commit → no fork
             (:committed commit-maj)       ; only the majority commits
             overlap-guaranteed))          ; two majorities always overlap
(println "")
(println (str (if ok "PASS" "FAIL") " 06_raft  (majority elects & commits; minority stalls; no split-brain)"))
```

Seven assertions, and the split is instructive: three are positive (the healthy path works), three
are negative (the partitioned minority is *refused*), and one is the theorem. A spike that only
asserted the positives would pass for an algorithm that elects everyone; the negative assertions are
what pin down *safety*. If any single one fails, the line reads `FAIL` and the suite's `run.sh` goes
red.

## Where it fits the fleet

This spike serves **desired state** — row 1 of the README's per-data-class table: *which host runs
`billing`, routes, config*. Its properties are exactly the fleet's needs for that class: one truth,
no split-brain, and a low write rate (desired state changes when a human or a reconciler changes it,
not per request — which is what makes paying consensus latency affordable).

Why *this* algorithm and not another — the neighbours, and why each is wrong for desired state:

- **`02_gset_crdt.bl` (events, G-Set).** Union-merge is perfect for append-only facts, and it is
  precisely the wrong tool here: merging conflicting placements would *succeed*, producing a definite
  and wrong answer. Events want "any convergent answer"; desired state wants "*the agreed* answer."
- **`03_orset.bl` (routes/claims, OR-Set).** Add/remove with convergence is what routes need — but a
  route table tolerates a moment of disagreement; a placement decision does not, because acting on a
  wrong placement means two hosts claiming one service.
- **`04_lww.bl` + `07_gossip_swim.bl` (membership/health, LWW + SWIM).** Last-writer-wins decides by
  timestamp, so a clock skew or a partition can silently pick a loser. Health status can tolerate
  that; "billing runs here" cannot.
- **`05_vector_clocks.bl` (causality).** Vector clocks can *detect* that two placements are concurrent
  — and then what? Detection is not resolution. Raft resolves.
- **`01_sharding.bl` (placement, HRW).** Answers a *different* question: given agreement that a
  service exists, which node should own it. Sharding decides distribution; Raft decides truth.
- **`08_ot_vs_crdt.bl`.** The design-choice spike: it justifies why the AP classes get CRDTs and this
  one does not, side by side.

The clean way to hold the whole suite in your head: CRDTs for the classes where the merge is the
answer, Raft for the one class where the merge would be the *wrong* answer. The README's boundary
section states it as the sharpest line in the design, and this spike is where that line is defended
by running code.

### datom's log *is* Raft's log

The fleet does not bolt a database onto Raft; the database's transaction log already *is* a
replicated log, and a Raft state machine is just a deterministic fold over one. The README draws the
mapping — reproduced here because it is the reason this algorithm belongs in *this* suite:

```
transact!   → :tx-datoms [[e a v tx op] …]   the command
basis-t     → monotonic tx id                 the log index
since       → datoms after t                  the log tail / catch-up
load-facts! → apply pre-analyzed facts        the state-machine apply
```

So: `transact!` produces the command that a leader would append; `basis-t` is the monotonically
increasing log index that tells you how far the fold has run; `since` is how a lagging follower
catches up (the log tail); `load-facts!` is the deterministic `apply` that folds the log into the
queryable state. Desired state commits as entries in that log, and every node that has applied the
same prefix is in the same state — which is the definition of the state-machine replicated at the
heart of Raft. That is Datomic's architecture (a single transactor → storage → peers) with Raft
supplying the HA that open-source `datom` lacks.

## What's real vs modelled

**Real, computed by bl, and asserted:**

- The term arithmetic (`term + 1` per election), the strict-majority threshold (`(inc (quot n 2))`,
  reused for both election and commit), the vote tally over a reachable set, the commit decision, and
  the split-brain refusal (`(not (:elected elect-min))` and `(not (:committed commit-min))`).
- The safety core as a *numerically checked theorem*: `overlap-guaranteed = (> (* 2 majority) n)`,
  i.e. two majorities of this cluster must share a node.
- The consequence: the minority cannot elect and cannot commit, so reality does not fork. That is the
  property, executed.

**Modelled, not real:**

- **The nodes are plain maps in one process.** The "network" is a `reachable` vector you pass in by
  hand; there are no sockets, no heartbeats, no election timeouts, no message loss or reordering, and
  no `AppendEntries`/`RequestVote` RPC. The production transport would be BEAM messaging; that is not
  what is under test here (see the README's fidelity note).
- **One vote per term is represented, not enforced.** `request-votes` recomputes the term from the
  candidate's own state and tallies *distinct* reachable members; the node's `:voted-for` field is
  carried in the record but never written or read back — there is no persisted ballot box. The reason
  the modelled election is still safe is that each side of the partition is handed a **disjoint**
  voter set, so no node is asked to vote twice; the overlap arithmetic is what the spike proves, and
  a full implementation would add the durable `:voted-for` bookkeeping to make that rule survive
  retries and re-campaigns within a term.
- **Log entries are not threaded into node state.** The node map carries `:log` and `:commit` so the
  *shape* of real Raft is legible, but `replicate` computes the commit verdict as a pure function of
  the reachable set without mutating those fields. What is under test is the commit *rule*, not a
  log-matching implementation; real Raft also needs the log-freshness (log-matching) property, which
  this spike does not model.
- **No timers, no leadership transfer, no snapshots, no membership change.** Randomised election
  timeouts, `AppendEntries` heartbeats that suppress spurious elections, log compaction, and joint
  consensus for reconfiguration are all part of a usable Raft and all absent here.

**In production, the implementation is [Ra](https://github.com/rabbitmq/ra)** (rabbitmq/ra) — a
multi-Raft library that is Jepsen-tested — which is what RabbitMQ moved to for its new Khepri store
after a decade of being burned by Mnesia's "let distributed Erlang handle it" approach to
split-brain. The spike implements the safety core (terms, majority vote, commit-by-majority,
split-brain refusal) as pure state functions so the mechanism is visible; Ra supplies the timers,
the RPC, the durability, and the log matching.

Contrast with **`02_gset_crdt.bl`**, which is *not* a simulation of the data it operates on: it runs
on **real `datom` tx-datoms**, exercising the actual log as a G-Set. Here the node state is the
modelled part — 5 maps, a hand-passed network — while the majority logic is real.

## Run it

```sh
./blx run research/fleet_spike/06_raft.bl
```

(The suite runs all spikes with `research/fleet_spike/run.sh`.) Cold start takes roughly **10–15
seconds** for the first `blx` invocation, then the spike runs in milliseconds. The script prints the
election, replication, partition, and conflicting-commit stages described above and ends with exactly
this line:

```
PASS 06_raft  (majority elects & commits; minority stalls; no split-brain)
```

`FAIL` instead of `PASS` means one of the seven assertions in Stage 6 did not hold.

## Exercises

1. **Even-sized cluster.** Change `cluster` to `["n1" "n2" "n3" "n4"]` and put the partition at
   `{n1 n2} | {n3 n4}`. Predict the output of both `request-votes` calls *before* running.
   `majority` now returns `(inc (quot 4 2)) = 3`, so neither side can elect and the whole cluster
   stalls. Then try `{n1 n2 n3} | {n4}`: the 3-side elects, the 1-side does not. What does this say
   about why production clusters use odd sizes?

2. **Spoofed quorum.** `replicate` counts entries in `reachable` after filtering by cluster
   membership, so duplicates count twice. Call `(replicate ["n3" "n3" "n4"] value 1)` and predict the
   verdict. It reports `stored 3 → committed true` even though only two *distinct* nodes stored
   anything. Explain why a real Raft must count distinct voters (and how a malicious or buggy leader
   could otherwise fabricate a commit), then sketch the one-line fix.

3. **Unanimity instead of majority.** Redefine `majority` as `(fn [ids] (count ids))`. Predict all
   four partition outcomes and re-check `overlap-guaranteed` (the formula `2n > n` is still `true`,
   but is that the right guard anymore?). You should find that a single crashed node makes the
   cluster unwritable — availability collapses while safety gains nothing. This is the cost of
   quorums larger than necessary.

4. **One vote per term, for real.** As noted in *What's real vs modelled*, `:voted-for` is never
   written. Call `request-votes nodes0 "n1" cluster` and `request-votes nodes0 "n3" cluster` — both
   reachable sets are the full cluster, so predict what both return (both report `elected: true` in
   term 1, which real Raft forbids). Then add the missing rule: make a voter's grant depend on
   `(:voted-for v)` being `nil` or the candidate, thread the updated ballots through, and confirm the
   second campaign over the same term is refused. That exercise is the difference between modelling
   the majority arithmetic and implementing the election.
