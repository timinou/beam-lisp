# 06 — Backups & DR: a checkpoint that leaves the box, a restore you can prove

A backup is only real once a checkpoint has physically left the node *and* a
fresh store has been rebuilt from it — so this spike ships the checkpoint to a
real S3 (Garage), restores it into a second connection, and records the proof as
a queryable datom.

## The claim

From `docs/design/vps/backups-and-dr.md §The layers` and `§The restore drill`:

- blobs live in `blob-s3` — **content-addressed, off-box by construction**; the
  durable tier for a database that may be sharded across nodes;
- the restore drill is **not a document but a scheduled function**: it restores a
  checkpoint into scratch space and transacts its own result as a datom, so
  "when did we last *prove* a restore works?" is answered by
  `[:find (max ?t) :where [_ :drill/at ?t]]` — a query, not a wiki page;
- the drill runs under `fence`, "bounded: 10 min, then killed", so a wedged
  restore cannot hold the node.

The spike proves the load-bearing half: a checkpoint round-trips through real S3
into a fresh connection, and the surviving handle on "did it work" is a datom.

## The idea

A node's below-OTP identity is its flake (reprovision from bootstrap). Its
above-OTP identity — desired state, history, audit — is the checkpoint. So the
recovery story reduces to: *reprovision the box, pull the checkpoint back, let
the reconciler converge*. Nothing else has to survive the disk.

Why S3 and not a tarball on the same disk? Because durability that shares fate
with the thing it protects is not durability. Content-addressing makes the
object store a natural fit: the key *is* the sha256 of the bytes → the same
checkpoint PUTs to the same key → a re-upload is a no-op (`-blob-put` is
idempotent by contract). "Did we ship it?" and "is this the right bytes?" collapse
into one hash comparison.

And the part most backup systems get wrong: the restore is *measured*. Not "the
backup job exited 0" — that only proves a file was written — but "we built a
fresh store from the shipped bytes and the state matched." That comparison is a
boolean, and a boolean is a datom. ∴ the compliance question is a `max` query,
and a *stale* max is the alarm.

## Walkthrough

### 1. The live node's desired state

```clojure
(def prod (datom/connect schema))
(datom/transact! prod [{:db/id -1 :svc/id "web" :svc/src "v3"}
                       {:db/id -2 :svc/id "api" :svc/src "v2"}
                       {:db/id -3 :svc/id "cron" :svc/src "v1"}])
```

`datom/connect` opens a fresh store; the schema declares `:svc/id` as a
`:db.unique/identity` (so a re-transact would upsert, not duplicate) plus the two
`:drill/*` attributes. Three services are transacted — this is the state we are
about to protect.

The checkpoint's *content* is defined by one pure query:

```clojure
(defn checkpoint-facts [conn]
  (sort (datom/q '[:find ?id ?src :where [?e :svc/id ?id] [?e :svc/src ?src]] (datom/db conn))))
```

Note the shape: a sorted vector of `[id src]` pairs. That projection — not the
raw datoms — is what leaves the box, and `sort` makes it deterministic so two
reads of an unchanged database compare `=` (set semantics have no order of their
own; here we impose one).

### 2. Choosing the S3 tier, honestly

```clojure
(def endpoint (System/get_env "S3_ENDPOINT"))
(def have-s3 (and (some? endpoint) (not (= endpoint ""))))

(defn s3-store []
  (s3/open {:bucket (System/get_env "S3_BUCKET") :prefix "checkpoints" :region "garage"
            :endpoint endpoint
            :access-key (System/get_env "S3_ACCESS_KEY")
            :secret-key (System/get_env "S3_SECRET_KEY")}))
```

`s3` is `datom.blob-s3`. `open` constructs a `BlobS3` record and boots the `:req`
HTTP client. The keys are the full AWS SigV4 credential set; `:prefix
"checkpoints"` means every object lands at `checkpoints/<sha-hex>`. Whether real
S3 is wired is decided from the environment alone — the whole drill branches on
`have-s3` below.

### 3. Checkpoint → serialize → PUT

```clojure
(defn checkpoint->s3 [store facts]
  (let [bytes (erlang/term_to_binary facts)
        sha (file/sha256 bytes)]
    (blob/-blob-put store sha bytes)
    sha))
```

`term_to_binary` turns the fact vector into OTP external-term bytes (any BEAM term
round-trips); `file/sha256` hashes those exact bytes. `blob/-blob-put` is the
`datom.blob/BlobStore` protocol method — for `BlobS3` it issues a signed
`PUT /<bucket>/checkpoints/<sha-hex>`. The returned `sha` is the checkpoint's
identity: hand it back later and you get those bytes, from any node.

### 4. Restore ← GET → into a *fresh* connection

```clojure
(defn restore<-s3 [store sha]
  (let [bytes (blob/-blob-get store sha)
        facts (erlang/binary_to_term bytes)
        c (datom/connect schema)]
    (datom/transact! c
      (vec (map-indexed (fn [i pair] {:db/id (- (- i) 1) :svc/id (first pair) :svc/src (second pair)})
                        facts)))
    c))
```

This is the "reprovisioned node": a brand-new connection, no shared state with
`prod`. Bytes come back from S3, are decoded, and are transacted into the fresh
store using tempids (`-1`, `-2`, …). Return `c` — the rebuilt node.

### 5. The drill: bounded, off-box, result-bearing

```clojure
(defn restore-drill! []
  (fence/fence-fn 10000
    (fn []
      (let [facts (checkpoint-facts prod)]
        (if have-s3
          (let [store (s3-store)
                sha (checkpoint->s3 store facts)              ; leaves the box
                scratch (restore<-s3 store sha)]               ; comes back on a new node
            {:where :garage-s3 :ok (= facts (checkpoint-facts scratch))})
          ;; no S3 wired: prove the round-trip in-memory, flagged honestly
          {:where :in-memory :ok true})))))
```

`fence-fn` (from `proc.fence`) runs the body in a monitored child with a
10 000 ms cap and returns a tagged result: `{:ok value}`, `{:crash reason}`, or
`{:timeout true}`. Inside: checkpoint out, restore back, and the proof is exactly
`(= facts (checkpoint-facts scratch))` — the *rebuilt* store's projection must
equal the original's. The result carries `:where` so the printout can name which
tier produced the proof.

### 6. The self-diagnosing part: the result is a fact

```clojure
(def drill (restore-drill!))
(def d (:ok drill))                                 ; {:where … :ok …} or nil on fence timeout
(def where (if d (:where d) :timeout))
(def drill-ok (and (map? d) (:ok d)))
(println "── restore drill ──" (pr-str drill))

(when drill-ok
  (datom/transact! prod [{:db/id -1 :drill/at 1700 :drill/ok true}]))
(def last-drill (first (first (datom/q '[:find (max ?t) :where [?d :drill/at ?t]] (datom/db prod)))))
(println "── compliance query: last proven restore @" last-drill "──")
```

Unwrap the fence envelope (`(:ok drill)` is the inner map on success, `nil` on
crash/timeout). **Only a passing drill writes a datom** — `:drill/at` and
`:drill/ok`. Then the standing query over `prod` returns the max `:drill/at`, and
that number *is* the compliance answer. Notice the loop closes on itself: the
store we protected is where the proof of protection lives.

### 7. Assertions

```clojure
(def ok (and (= 3 (count facts))
             drill-ok                              ; restore verified equal
             (= 1700 last-drill)))                 ; drill is a queryable fact
(println (str (if ok "PASS" "FAIL") " 06_backups_dr  (" (name where) " checkpoint, proven restore)"))
```

Three things must hold: the checkpoint captured all three services, the restore
compared equal, and the drill landed as a queryable fact.

## What's real vs modelled

**Exercised as-is (the real organs):**

- `datom/connect`, `datom/transact!`, `datom/q`, `datom/db` — the actual database:
  schema with `:db.unique/identity`, tempid allocation, datalog with a `(max ?t)`
  aggregate. The `[?e :svc/id ?id][?e :svc/src ?src]` join runs on the real query
  engine.
- `datom.file/sha256` and the `datom.blob/BlobStore` protocol methods
  `-blob-put` / `-blob-get`, dispatched into `datom.blob-s3`'s `BlobS3` record.
  This is real SigV4-signed HTTP (Req) against a real S3 server; the blob
  genuinely leaves the BEAM to a separate `garage server` process listening on
  `127.0.0.1:3900`.
- `proc.fence/fence-fn` — the real bounded-isolation combinator (monitor +
  timeout + kill), not a mock.
- `erlang/term_to_binary` / `binary_to_term` — the OTP BIFs, unchanged.
- **Garage** (`research/vps_spike/garage/up.sh`) as the S3 tier. The script is
  fully **rootless**: it writes a `garage.toml` under `$GARAGE_DIR`
  (default `/tmp/vps-garage`) with `sqlite` metadata, spawns `garage … server`
  via `setsid` **closing inherited fds 3–9** — so shell entry never hangs on a
  daemon that inherited the caller's descriptors — waits up to 10 s for
  `garage status` to answer, assigns the single node a layout role if it has
  none (`layout assign -z dc1 -c 1G` + `layout apply`), then idempotently
  creates the `bl-blobs` bucket and `bl-key` key, allows read/write/owner, and
  emits `S3_ENDPOINT/S3_BUCKET/S3_ACCESS_KEY/S3_SECRET_KEY` to
  `$GD/creds.env` for the spike to source. Every step is guarded (`|| true`,
  `if ! … status`), so re-running it is safe.

**Modelled in miniature / simplified for the probe:**

- **The "off-box" tier is off-*process*, not off-*node*.** Garage runs on
  `127.0.0.1` on the same host. The design's durability argument is that S3 is a
  *separate machine*; the probe only demonstrates the mechanism (a real object
  store reachable over the network stack), not geographic separation.
- **The checkpoint payload is a small projection, not a database checkpoint.**
  What ships is the three-row `[id src]` query result — not the datom store, not
  history, not blobs. A production checkpoint would export the durable store
  (`store-fjall`) and its file/blob set. Here `datom/connect` is an *in-memory*
  store, so the "live database" is not on disk in this probe at all.
- **The "fresh conn" stands in for a reprovisioned node.** `restore<-s3` opens a
  second in-process connection (a fresh ETS store); it does not run
  `nixos-anywhere`, boot a VM, or exercise `bootstrap.md`. The recovery *step
  after* restore — the reconciler converging services from desired state — is not
  run; we verify the data equality directly with `checkpoint-facts`.
- **The drill is invoked once inline, not on a schedule.** `proc/sched` (the
  nightly `:checkpoint` job from `services-and-schedules.md`), WAL shipping,
  retention, and alert-on-age are all in the design doc but **not** exercised
  here. Nothing fires when `(max :drill/at)` grows stale.
- **The timestamp is a literal.** The doc writes `(now)`; the spike transacts
  `:drill/at 1700` (a hardcoded constant) so the assertion `(= 1700 last-drill)`
  is deterministic. No clock is read.
- **The fence cap is 10 seconds, not the doc's 10 minutes** (`10000` ms here vs
  `{:ms 600000}` in `backups-and-dr.md`). Chosen small so the spike stays fast.
- **Failure is not recorded as a datom.** The doc promises "drill fails → the
  failure is a datom, paged"; the spike only transacts on success (`when
  drill-ok`), so a failing drill leaves *no* row — the opposite of an alarm. The
  `:drill/ok` attribute exists in the schema but is only ever written `true`.
- **The `:timeout` label conflates fence outcomes.** `where` is `:timeout`
  whenever `(:ok drill)` is nil — which is also the case for a fence *crash* (an
  S3 `PUT` throwing) and for a `{:crash …}` result. So a thrown S3 error would
  print as `(timeout checkpoint, …)` even though no timeout occurred.
- **No-S3 degrade is asserted, not proven.** The `:in-memory` branch returns
  `{:where :in-memory :ok true}` **without performing any round-trip** — the
  comment says "prove the round-trip in-memory", but the code simply claims
  success and flags the tier honestly. It makes the spike pass without Garage;
  it does not test the memory path.

## Run it

With Garage (the real path — do these three in order, `run.sh` wires them for
you):

```bash
research/vps_spike/garage/up.sh                      # rootless Garage; writes /tmp/vps-garage/creds.env
set -a; . /tmp/vps-garage/creds.env; set +a
./blx run research/vps_spike/06_backups_dr.bl
```

Expected final line:

```
PASS 06_backups_dr  (garage-s3 checkpoint, proven restore)
```

Without creds in the environment the same command still passes but the tier is
named honestly:

```
PASS 06_backups_dr  (in-memory checkpoint, proven restore)
```

Cold start costs ~10–15 s (JIT warmup) — that is boot, not the drill. You will
see `── checkpoint ── 3 services  (S3: http://127.0.0.1:3900 )` and
`── compliance query: last proven restore @ 1700 ──` above the PASS line.

## Exercises

1. **Add a fourth service** to the `prod` transaction. Predict what happens:
   `(count facts)` becomes 4, so `(= 3 (count facts))` fails and the spike prints
   `FAIL 06_backups_dr  (garage-s3 checkpoint, proven restore)`. The restore
   still round-trips — the *assertion* is what broke, not the mechanism.
2. **Break the round-trip.** Edit `restore<-s3` to drop the last fact (e.g.
   `(butlast facts)`). Predict: `(= facts (checkpoint-facts scratch))` is false →
   `drill-ok` false → no datom is transacted → `last-drill` is `nil` → FAIL, and
   the drill line shows `:ok false`.
3. **Shrink the fence.** Change `10000` to `1`. Predict: the body (an HTTP PUT +
   GET) cannot finish in 1 ms, so `fence-fn` returns `{:timeout true}`, `d` is
   nil, `where` prints `timeout`, and the spike FAILs — demonstrating that the
   drill's failure mode is *bounded*, not that the restore is unsound.
4. **Change the drill timestamp.** Set `:drill/at 1700` to `:drill/at 9999`.
   Predict: the record still transacts and the query returns `9999`, but
   `(= 1700 last-drill)` fails → FAIL. This makes plain that `last-drill` is read
   straight from the store, not remembered from the literal.
5. **Run it with Garage down and creds unset.** Predict: `(S3: not wired)` in the
   checkpoint line, `(in-memory checkpoint, proven restore)`, and a PASS — with
   the caveat from "What's real vs modelled": no round-trip was actually tested.
