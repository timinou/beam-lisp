# veritas, grown for the one who writes most of the code

Status: design proposal, 2026-09-28. Nothing here is built. It extends the
`veritas.*` family (`docs/one-verb-over-generators.md`) and changes no
existing verb. It draws on the connector work of the same day
(`docs/connectors/entities-and-projections.md`; knowledger docs 21 and 22).

Zero context. veritas today is **one verb over generators**:
`(check {:q :exists|:for-all :var :gen :pred})` escalates z3 → exhaustive
enumeration → sampling, and returns a verdict whose **modality**
(`:proven` / `:witnessed` / `:refuted` / `:unknown`) states how much it
actually knows. Three layers sit on it: `mock` (a contract run backwards),
`fault` (a mutant per law, analysed in datalog) and `property` (run a function,
check its output, shrink a counterexample).

This document asks what veritas would need to be the tool an **agent**
reaches for first when it must know whether code is right. The answer below
is written from the agent's side, from what this session actually lacked.

---

## 0 · What I needed today, and did by hand

| need (this session) | what I did | what veritas could not do |
|---|---|---|
| Is a *generated* datalog query equivalent to the hand-written one it replaces? | printed it and read it | reason about **datalog**: veritas quantifies over scalars |
| Does the sync executor converge, whatever the order of moves, trashes, revisions and returns? | 14 hand-picked scenarios | generate **sequences of operations** against a model and shrink a failing *history* |
| A fake Microsoft Graph that remembers a cursor and answers 410 on an expired one | designed a hand-written server (doc 22) | `veritas.mock` answers each key with one value derived from a contract. It has **no state** |
| "Firm B's store never contains firm A's folder name" | grepped file bytes by hand | state and check a **non-interference** property |
| "Only `access.bl` writes `:grant/*`" | a proposed grep test | ask the code graph a **structural law** |
| Which claims in my docs are still true after the code changes? | none | **claims that stay attached to code** and are re-checked |
| Report what I verified vs what I inferred | prose, by discipline | a **verdict ledger** the report is generated from |

The pattern: veritas is strong on "is this predicate true for all values of
this type", and has nothing for **state, time, histories, structure, or its own
memory**. Those are the everyday questions.

---

## 1 · Design principles (kept from the core, and two added)

1. **One verb, modal verdict.** Every new capability returns the same verdict
   shape and never upgrades a sample into a proof.
2. **Generators are the only domain notion.** New domains (histories, datom
   databases, requests) are new `Gen` records, not parallel mechanisms.
3. **Predicates are quoted forms**, never strings.
4. **New: a verdict is data that persists.** It is a datom with what it
   checked, how, against which code, and when. What was verified becomes a
   query rather than a memory.
5. **New: every refutation is a replayable artifact.** A seed, a shrunk
   witness and a one-line command that reproduces it. Agents lose context, and
   a counterexample that cannot be replayed from a cold start is lost.

---

## 2 · The verdict, made durable: `veritas.ledger`

Everything else builds on this.

```clojure
(require '[veritas.ledger :as vl])

;; any check can be recorded; recording is how a claim becomes checkable later
(vl/record! (v/for-all port "x" (v/int-of 0 100) '(>= (* x x) 0))
            {:claim  "squares are non-negative on 0..100"
             :about  ['my.math/square]          ; code the claim depends on
             :by     "agent:session-7f3"})
;; → {:verdict/id "vd-01J…" :modality :proven :engine :oracle}
```

A verdict is stored as datoms in a `veritas.fjall` store per project:

```clojure
:verdict/id        string, unique
:verdict/claim     string                 ; the human sentence
:verdict/query     term                   ; the exact query, re-runnable
:verdict/modality  keyword                ; :proven :witnessed :refuted :unknown
:verdict/engine    keyword                ; :oracle :enumerate :sample :model :graph
:verdict/tried     long                   ; samples / states / histories explored
:verdict/witness   term                   ; shrunk, a real bl value
:verdict/replay    string                 ; `bl veritas replay vd-01J…`
:verdict/about     ref, many              ; code entities (codebase graph ids)
:verdict/basis     term                   ; content hash of each `about` entity at check time
:verdict/by        string
:verdict/at        long
```

**Staleness is a query, not a guess.** The codebase graph (`priv/std/codebase.bl`)
records functions (`:fn/name`, `:fn/ns`, `:fn/line`), calls and namespace
requires, but **no content hash** today (checked 2026-09-28). U2 adds one,
`:fn/hash` = sha256 of the definition's normalised form, and the call graph
supplies the closure. A verdict is **stale** when any `about` function, or
any function it transitively calls, hashes differently from `:verdict/basis`:

```clojure
(vl/stale)            ; → verdicts whose code moved since they were checked
(vl/recheck! :stale)  ; re-runs them; each gets a new verdict, the old one stays (history)
(vl/about 'knowledger.access/grant!)   ; every claim resting on this fn, with modality
```

**Reports are generated from it**, which is the honesty trigger made
mechanical:

```clojure
(vl/report {:since session-start})
;; ## Verified
;; - proven (z3): owed-query ≡ hand-written OWED under the sync schema   [vd-…]
;; - witnessed (2 000 histories, 0 failures): executor converges        [vd-…]
;; ## Refuted
;; - retire while paused drops a live origin — witness: [move trash pause retire] [vd-…] replay: bl veritas replay vd-…
;; ## Not verified (claims with no verdict)
;; - "fjall frees the lock on close!"                                    (stated in docs/21 §7)
```

**CLI:**

```console
$ bl veritas ls --stale
$ bl veritas replay vd-01J8…      # re-runs the exact query with the recorded seed
$ bl veritas recheck --stale
```

---

## 3 · Stateful models: `veritas.model`

The biggest gap. Everything with a lifecycle (a keep, a queue, a projection,
the grant door, a fake service) is a **state machine**. Classic
property-based state-machine testing (QuickCheck `eqc_statem`, Hypothesis
`RuleBasedStateMachine`) fits the core almost directly: a history is a value,
so it is just another generator.

### 3.1 · Declaring a model

```clojure
(require '[veritas.model :as vm])

(vm/defmodel drive-sync
  "A remote tree mirrored into a library through the :sync/doc projection."
  {:state  {:tree   {}             ; model state: remote id → {:parent :rev :trashed}
            :bound  #{}}           ; the reference ("what should be true")
   :init   (fn [] (setup-world))   ; the REAL system under test, per history

   :commands
   {:add    {:args  (v/tuple-of (vm/fresh :item) (vm/pick :folder))
             :pre   '(contains? (:folders state) parent)
             :next  (fn [s [id parent]] (assoc-in s [:tree id] {:parent parent :rev 1}))
             :run   (fn [sys [id parent]] (mirror! sys id parent))}
    :move   {:args  (v/tuple-of (vm/pick :item) (vm/pick :folder)) …}
    :trash  {:args  (vm/pick :item) …}
    :bump   {:args  (vm/pick :item) …}
    :pause  {:args  (v/bool-of) …}
    :drain  {:args  nil
             :run   (fn [sys _] (apply-owed! sys) (retire-stale! sys))}}

   :invariants                     ; checked after EVERY command
   {:no-dup-sources  '(= (count (sources sys)) (count (distinct (map :hash (sources sys)))))
    :live-iff-origin '(every? (fn [s] (= (live? s) (seq (origins s)))) (sources sys))}

   :eventually                     ; checked after a final :drain
   {:converged       '(and (empty? (owed sys)) (empty? (stale sys)))
    :matches-model   '(= (live-origins sys) (member-files state))}})
```

- `:next` updates the **model**. `:run` drives the **real** system. An
  invariant can read both, which is how "the real thing agrees with the model"
  is written.
- `vm/fresh` and `vm/pick` are generators whose domain is the current state, so
  a command only receives arguments that make sense. `:pre` filters the rest.

### 3.2 · Checking it

```clojure
(vm/check drive-sync {:histories 2000 :max-len 40 :seed 7})
;; → {:modality :witnessed :engine :model :tried 2000
;;    :coverage {:commands {:add 11834 :move 9310 …} :transitions 212}}
;;
;; or
;; {:modality :refuted
;;  :witness  [[:add :a :root] [:drain] [:move :a :out] [:pause true] [:drain] …]   ; as found
;;  :shrunk   [[:add :a :root] [:drain] [:pause true] [:move :a :out] [:drain]]     ; minimal
;;  :broke    :live-iff-origin
;;  :replay   "bl veritas replay vd-…"}
```

**Shrinking a history** is the thing a human cannot do by hand: delete
commands, then shrink the arguments of the rest, keeping only histories that
still pass `:pre` and still fail. The result is the shortest story that breaks
the system. The current shrinker only walks integers toward 0, so this is a
real extension.

**Modality stays honest.** A model check is `:witnessed` (it sampled
histories). It becomes `:proven` only when the state space is finite and fully
enumerated within `:max-len`, and the verdict says which.

### 3.3 · Linearizability, for concurrent things

```clojure
(vm/check-concurrent proc-queue-model {:clients 3 :histories 500})
```

This runs command sequences from N processes against the real system, records
the interleaved history with invocation and response times, and searches for
**one** sequential order of the model that explains every observed response
(Wing–Gong, as Jepsen's Knossos does). If none exists, the history is the
counterexample. This is what `proc.queue`'s claim/CAS and the reconcile
executor's "at-least-once, re-judge in perform" actually need.

### 3.4 · Faults inside histories

`veritas.fault` already builds a mutant per law. A model gains fault commands
for free:

```clojure
:commands {… :crash {:run (fn [sys _] (vm/kill! sys :executor))}
             :partition {:run (fn [sys _] (vm/drop-next! sys :http 3))}}
```

`vm/kill!` and `vm/drop-next!` act on processes and transports registered with
the model's `:init`. The model check then covers crash and retry as ordinary
moves, which is gate G2 of `entities-and-projections.md` ("kill between apply
and record, converge") without a hand-written crash test.

---

## 4 · Stateful mocks: a model, served

The Microsoft fake of knowledger doc 22 is "a state machine that answers HTTP".
A model already is a state machine. Serving it is one function:

```clojure
(vm/defmodel graph-drive
  {:state {:items {} :cursor-snapshots {} :expired #{}}
   :commands
   {:delta   {:request  [:get "/drives/:d/root/delta" {:token ?t}]
              :pre      '(not (contains? (:expired state) t))
              :next     (fn [s req] (snapshot s))
              :response (fn [s req] (delta-page s req))}
    :expired {:request  [:get "/drives/:d/root/delta" {:token ?t}]
              :pre      '(contains? (:expired state) t)
              :response (fn [_ _] {:status 410 :headers {"Location" …}})}
    …}})

(def fake (vm/serve graph-drive {:port 0 :state (load-tree "~/.knowledger/fake-m365")}))
(:url fake)   ; → "http://127.0.0.1:53811"
```

- `vm/serve` routes each request to the command whose `:request` pattern
  matches and whose `:pre` holds, applies `:next`, and returns `:response`.
- **The same model generates tests of the client.** `vm/check` drives the
  *connector* with random server-side events (edits, moves, expiries,
  throttles) between its calls. The fake and its test generator are one
  artifact, so they cannot drift.
- **Contract check against the real service**: `vm/conforms?` replays recorded
  real responses (doc 22 §3.2) and checks that each one is a response the
  model could have given in that state. Differences come back as named
  commands.
- `veritas.mock` keeps its role: a stateless contract becomes a one-command
  model with no state, so the stateless mock is a special case of `serve`
  rather than a second server.

---

## 5 · Datalog as a theory: `veritas.datom`

Today a predicate ranges over ints, reals, strings, enums and collection
lengths. Much of what an agent writes in this ecosystem is **datalog queries
and transaction functions**. The gap is a generator of databases and a few
query-level questions.

### 5.1 · Generating databases from a schema

```clojure
(v/db-of sync-schema {:entities 30 :refs :acyclic :cardinality-many 3})
```

`db-of` is a `Gen` record:
- `gen-sample` builds small datom databases that respect the schema: types,
  uniqueness, cardinality, and `:acyclic` for parent-style refs.
- `gen-enumerate` enumerates **all** databases up to a small bound (for
  example 4 entities × the attributes a query reads, which `:reads` and
  BUG-100's walker already compute). An exhaustive pass over those gives
  `:proven` *within the bound*, and the verdict records the bound
  (`:modality :proven :bound {:entities 4}`). This is the Alloy / small-scope
  hypothesis, stated rather than implied.
- `gen-constrain` stays nil for now (see §5.3).

### 5.2 · Query-level questions

```clojure
(v/equivalent? port q1 q2 {:gen (v/db-of schema {…}) :inputs {…}})
;; ∀ db. (q q1 db) = (q q2 db)  — the question I needed for "generated ≡ hand-written"

(v/monotone? port q {:in :attr :file/parent})
;; adding datoms of this attribute never removes rows (safe to maintain incrementally)

(v/reads-sound? port 'files/:~file/under)
;; a relation's declared :reads covers every attribute that can change its answer:
;; for random db, random tx touching only OTHER attributes, the answer does not move.
;; This is the BUG-100 class of bug, checked for every registered relation.

(v/tx-preserves? port tx-fn invariant-query {:gen (v/db-of …)})
;; the transaction function never produces a db where invariant-query has rows
```

Each returns the usual verdict. A refutation carries a **minimal database**
(shrunk by deleting datoms, then entities), printed as transaction data you can
paste into a test.

`reads-sound?` alone would have found BUG-100 before it shipped. It is a
`for-all` over `(db, tx)` pairs, which `tuple-of` already supports.

### 5.3 · Later: symbolic datalog

Bounded non-recursive datalog with negation translates to SMT (entities become
a finite sort, attributes become relations). For those queries, `equivalent?`
could return a true `:proven`. This is research-sized and deliberately out of
the first cut: the enumerated bound gets most of the value.

---

## 6 · Structural laws over code: `veritas.code`

Some laws are about the **shape** of the program, not its values. The
codebase graph and `system.footprint` already know that shape.

```clojure
(v/code-law "only the access door writes grants"
  '(for-all [f (fns-in "knowledger")]
     (=> (writes? f :grant/*) (in-ns? f 'knowledger.access))))

(v/code-law "the fake is never reached from production code"
  '(not (reaches? 'knowledger.main 'connector.microsoft.fake)))

(v/code-law "no handler reads a file per row"            ; the dirty-IO lesson
  '(for-all [h (handlers)] (not (calls-in-loop? h 'File/*))))   ; codebase.bl already has :call/loop-depth
```

- `writes?`, `reads?`, `reaches?`, `calls?` are footprint and call-graph
  queries. Footprint modes (`:R :A :W :S :K :X`) already exist per resource,
  and a datom attribute is a resource.
- The verdict is `:proven :engine :graph` when the graph is complete for the
  scope, and `:unknown` when a dynamic call (`apply`, a var holding a fn) makes
  the answer undecidable. The unknown site is named in the verdict, so the
  honest answer points at the exact line to look at.
- Code laws live next to the code (`(deflaw …)` in the namespace) and run in
  `bl test`. That turns the "grep test" of knowledger doc 21 §6.2 into a law
  the compiler's own graph checks.

---

## 7 · Non-interference: `veritas.flow`

The isolation claim ("firm B never sees firm A's folder names") is a
**noninterference** property: varying a secret input must not change what an
observer sees.

```clojure
(v/non-interfering? port
  {:system   (fn [secret] (run-two-firm-world {:a-folder-name secret}))
   :secret   (v/string-of "PRIV-" 8 16)
   :observe  (fn [world] (bytes-under (:root world) "northstar"))})
;; runs the system twice with different secrets (a two-run "product"), compares observations.
;; → :witnessed after n pairs; :refuted with the two secrets and the differing observation
```

This replaces the positive control plus grep with a property that cannot pass
by accident: if the observation changes when only the secret changes, the
secret leaked. The same verb answers "does the chat agent's answer for user U
depend on library L that U cannot read?", which is walls v2's real question.

---

## 8 · Ergonomics for an agent

**One entry point that picks the engine**, with the reason stated:

```clojure
(v/verify 'knowledger.sync/apply-one!)
;; reads the fn's :veritas metadata (laws, models, code-laws declared next to it),
;; runs each with the strongest engine, records them, returns a table:
;; law                              modality    engine     tried   replay
;; re-judges before acting          proven      graph      —       vd-…
;; converges (model drive-sync)     witnessed   model      2000    vd-…
;; target-first order               refuted     model      412     vd-… ← [:apply :crash :drain]
```

**Laws declared where the code is:**

```clojure
(defn apply-one!
  {:veritas {:laws  ['(=> (not (owed? ctx row)) (= :not-owed (apply-one! ctx p row)))]
             :model 'sync-model/drive-sync
             :code  ["never writes :proj/* before the target"]}}
  [ctx p row] …)
```

**Budgets instead of sample counts:** `{:budget-ms 20000}`. veritas spends it
on the strongest engine first, then samples until the budget ends, and reports
what it managed. An agent has a time limit, not a preference for "n = 32".

**Explain the modality:** every verdict carries `:why`, for example
`"sampled: predicate uses `some` over elements (outside the SMT fragment)"`.
Today the escalator knows this and drops it.

**Coverage of the check itself**: `:coverage` reports which commands,
transitions or guard clauses the samples reached. A `:witnessed` verdict that
never exercised `:pause` says so, instead of looking like evidence.

**Deterministic by default:** every sampling engine takes `:seed` (default
derived from the claim's id), so the same claim samples the same values on
every machine, and `replay` is exact.

---

## 9 · Upstream changes, in build order

| # | change | where | why first |
|---|---|---|---|
| U1 | `:why` and `:seed` on every verdict; seeded sampling in `run-sample` | `veritas.bl` | small, and everything else reports through it |
| U2 | `veritas.ledger`: verdict datoms, `record!`, `:fn/hash` in the codebase graph, `stale` over the call closure, `report`, `bl veritas` CLI | new `priv/lib/veritas/ledger.bl`, `priv/std/codebase.bl`, `priv/std/bl/cli.bl` | makes every later capability durable |
| U3 | general shrinking: a `Shrink` protocol beside `Gen` (vectors, maps, strings, tuples, histories, databases) | `veritas.bl` | the model and datalog layers depend on it; today only ints shrink |
| U4 | `veritas.model`: `defmodel`, `check`, history shrinking, `kill!`/`drop-next!` hooks | new `priv/lib/veritas/model.bl` | the largest single gain |
| U5 | `vm/serve` and `vm/conforms?`; `veritas.mock` becomes a stateless model | `veritas/model.bl`, `veritas/mock.bl` | the M365 fake becomes a model (knowledger doc 22) |
| U6 | `veritas.datom`: `db-of`, `equivalent?`, `reads-sound?`, `tx-preserves?`, `monotone?` | new `priv/lib/veritas/datom.bl` | `reads-sound?` over every registered relation catches BUG-100's class |
| U7 | `veritas.code`: `code-law`, `deflaw`, graph and footprint predicates | new `priv/lib/veritas/code.bl` | needs the codebase graph's footprint export |
| U8 | `check-concurrent` (linearizability) | `veritas/model.bl` | for `proc.queue` and the projection executor |
| U9 | `veritas.flow`: `non-interfering?` | new `priv/lib/veritas/flow.bl` | walls v2 and firm isolation |
| U10 | `v/verify` + `:veritas` metadata + budgets | `veritas.bl` | the ergonomic front door, once there is something behind it |

**First consumers, so each step is proven on real code:**
- U4 and U5: the knowledger sync executor model and the Microsoft Graph fake
  (doc 22 §1.4 scenarios become model commands).
- U6: `defprojection`'s generated queries (`equivalent?` against the
  prototype's hand-written ones) and `reads-sound?` for `:~file/under`.
- U7: knowledger doc 21 §6.2, the grant-door law.
- U9: the two-firm isolation assertion of the sync-store prototype.

## 10 · Non-goals

- A general theorem prover. `:proven` keeps meaning "z3, a complete
  enumeration, or a complete graph", always with its bound.
- Replacing `deftest`. Examples stay examples; veritas adds the quantifiers.
- Symbolic datalog in the first cut (§5.3).
- Hiding cost: every verdict reports `:tried` and elapsed time.

## 11 · Open questions

- Where the ledger lives for a multi-repo change (a knowledger claim about a
  beam-lisp function): one store per repo with cross-repo `about` references,
  or one per workspace.
- Whether `:verdict/basis` should cover the whole call closure (precise,
  costly, and blind to data-driven dispatch) or only the direct definitions
  plus the namespaces they require (cheap, coarse). A measurement on this
  repo's graph should decide.
- How much of the history shrinker can reuse `veritas.fault`'s datalog
  analysis, for example grouping failing histories by the invariant they break.
