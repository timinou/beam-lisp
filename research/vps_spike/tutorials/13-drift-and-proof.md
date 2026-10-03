# 13 — Drift and proof

Drift is not fought but surfaced as a delta and settled by a *recorded* operator
choice, and every delta the reconciler would apply is first **proved safe by
z3** — an unprovable one is refused, with the reason transacted as a fact, and
nothing happens.

## The claim

From `docs/design/vps/the-reconciler.md`, the section **"Drift is a participant,
not an enemy"**: when someone hot-fixes a live service, conventional infra calls
it drift and fights it by re-running a playbook — but the reconciler treats it as
observed-state change, reports the delta, and lets the operator choose *in data*
between **commit** (the fix becomes desired truth) and **revert** (re-apply
desired). From the section **"Failure posture"**: a delta the machine cannot
prove safe — "z3 says no, or times out" — is *transacted as a refusal with the
counter-example*; it "errs toward stillness". This spike proves both on the
**real datom** and the **real z3** (`system.core/migration-preserves?`), so the
refusal is a proof, not a lint. The invariant it proves is the level-3 ordering
discipline from `docs/design/vps/zero-downtime.md`: *a claimed host always has at
least one live backend* — spawn before route, never route-then-drain.

## The idea

Two habits that conventional config management does not have.

**1 — Drift is a choice, not a crime.** A script-based system asks "is the
machine in the desired state?" and, if not, quietly overwrites the machine — so
the 02:00 hot-fix is gone and nobody wrote down that a human had made it. The
reconciler separates *observing a divergence* from *deciding what to do about
it*: it computes the delta as data and reports it. The operator then picks
`commit` or `revert`, and **the pick is itself a datom**. → "who decided to keep
that hot-fix, and when?" is a query. There is no silent third option where the
living node and the stored truth drift apart forever.

**2 — Prove before you apply.** The dangerous moment in devops is the act, not
the plan. Here the candidate effect set is handed to a solver first, with an
invariant attached: *does applying this keep every claimed host with a backend?*
If the solver proves it does (`unsat` on the negation) the reconciler applies;
if it finds a counter-model — or cannot decide — the reconciler **refuses** and
transacts *why*, changing nothing. The running system keeps serving; the change
is simply not made. A refusal here is not a crash, it is the machine keeping its
promise: stillness over a change it cannot stand behind.

Concretely, the interesting delta is the *ordering* of a platform-level move: a
host's backend count going `b → b + 1` (spawn the new backend, then route) stays
`≥ 1`; `b → 0` (route to nothing) does not. That `(+ b 1)` versus `0` is the
whole difference, and the spike asks z3 to tell the two apart rather than
trusting a runbook.

## Walkthrough

### Step 1 — One schema, three kinds of fact

The spike opens against the real `datom` library and declares the attributes for
desired state, the drift decision, and the refusal — all in one store:

```clojure
(ns vps.drift (:require [datom] [system.core :as sys] [z3]))

(def schema
  [{:db/ident :svc/id  :db/valueType :db.type/string :db/unique :db.unique/identity}
   {:db/ident :svc/src :db/valueType :db.type/string}
   {:db/ident :svc/desired :db/valueType :db.type/boolean}
   {:db/ident :drift/svc :db/valueType :db.type/string}
   {:db/ident :drift/choice :db/valueType :db.type/keyword}
   {:db/ident :refusal/why :db/valueType :db.type/string}])

(def conn (datom/connect schema))
```

`:svc/id` is `:db.unique/identity`, so transacting an existing id **upserts** onto
the same entity instead of forking. `:svc/desired` is a boolean marker for *the
intended source*; `:drift/choice` and `:refusal/why` are the history side. Intent,
decision, and refusal are the same kind of data — the tutorial README's "one
address space" in miniature.

### Step 2 — Desired state is a query

```clojure
;; ── desired state: web at v1 ────────────────────────────────────────────────
(datom/transact! conn [{:db/id -1 :svc/id "web" :svc/src "v1" :svc/desired true}])

(defn desired-src [db]
  (first (first (datom/q '[:find ?s :where [?e :svc/id "web"][?e :svc/desired true][?e :svc/src ?s]] db))))
```

`desired-src` does not read a field labelled "desired"; it *asks* for it — a
datalog query joining `web`'s entity to the source that carries
`:svc/desired true`. Because `:svc/id` is identity-unique, a later transaction
that adds a new `:svc/src` to the same id simply moves the truth, which is
exactly what the commit below needs.

### Step 3 — Drift is detected, and reported as a value

```clojure
;; ── DRIFT: an operator hot-fixes web to v1-hotfix live at 02:00 ─────────────
;; observed diverges from desired. The reconciler computes the delta as data.
(def observed-src "v1-hotfix")
(def drift-delta {:svc "web" :desired (desired-src (datom/db conn)) :observed observed-src})
(println "── drift detected ──")
(println "  desired:" (:desired drift-delta) "  observed:" (:observed drift-delta)
         "  diverged:" (not= (:desired drift-delta) (:observed drift-delta)))
```

The observed value is a literal string standing in for a live sample. The
divergence is turned into *data* — `drift-delta` is a plain map with `:desired`,
`:observed`, and a computed `diverged` — and printed rather than acted upon:

```
── drift detected ──
  desired: v1   observed: v1-hotfix   diverged: true
```

Handing the divergence to the operator as a value is the "participant, not
enemy" move: the machine has *not* reverted anything yet.

### Step 4 — The operator chooses, and the choice is a fact

```clojure
;; the operator COMMITS the drift to desired (the fix becomes the truth)
(datom/transact! conn [{:db/id -1 :svc/id "web" :svc/src observed-src :svc/desired true}
                       {:db/id -2 :drift/svc "web" :drift/choice :commit}])
(println "── operator chose: commit-to-desired ──")
(println "  desired now:" (desired-src (datom/db conn)))
(def choice (first (first (datom/q '[:find ?c :where [?e :drift/choice ?c]] (datom/db conn)))))
(println "  choice recorded as a fact:" choice)
```

One transaction, two entities:

- `{:db/id -1 :svc/id "web" :svc/src "v1-hotfix" :svc/desired true}` upserts onto
  the existing `web` entity (via the unique id), so **the hot-fix becomes the
  desired source** — commit-to-desired.
- `{:db/id -2 :drift/svc "web" :drift/choice :commit}` is a *separate* entity
  recording the decision.

Then the desired source is re-read through the same query, and the choice is read
back with a query of its own — it is not a local variable that evaporates, it is
a row:

```
── operator chose: commit-to-desired ──
  desired now: v1-hotfix
  choice recorded as a fact: :commit
```

The doc's alternative is `:revert` (re-apply desired, dropping the hot-fix);
this run exercises the commit branch, but either choice is written the same way.
There is no unrecorded decision.

### Step 5 — The invariant, and the two candidate deltas

```clojure
;; ── PROOF: prove a candidate effect set before applying ─────────────────────
;; invariant: a claimed host's backend count is ≥ 1 (never route to nothing).
(def port (z3/open))
(defn inv [v] (str "(>= " v " 1)"))
(def decls "(declare-const b Int)\n(declare-const b2 Int)\n")

;; a GOOD delta: spawn one backend then route (b2 := b + 1, stays ≥1)
(def good-delta-ok
  (sys/migration-preserves? port inv decls "b" "b2" "(+ b 1)"))
;; a BAD delta: route first, drain backend to 0 (b2 := 0 — breaks ≥1)
(def bad-delta-ok
  (sys/migration-preserves? port inv decls "b" "b2" "0"))
```

`z3/open` starts the supervised solver pool and returns its handle. The invariant
is `(>= v 1)` over a host's backend count; `b` is the count now, `b2` the count
after the candidate delta. `system.core/migration-preserves?` encodes one
obligation:

```
assert   inv(v1) ∧ (v2 = migrate) ∧ ¬inv(v2)
check-sat   unsat  ⟹  the migration is safe
```

Run it on each delta:

- **safe**, `migrate = "(+ b 1)"`: `b ≥ 1 ∧ b2 = b+1 ∧ ¬(b2 ≥ 1)`. The last
  conjunct forces `b2 < 1`, i.e. `b < 0`, contradicting `b ≥ 1`. No model exists
  → `unsat` → `good-delta-ok` is `true`.
- **unsafe**, `migrate = "0"`: `b ≥ 1 ∧ b2 = 0 ∧ ¬(b2 ≥ 1)`. Take `b = 1`,
  `b2 = 0` — a model → `sat` → `bad-delta-ok` is `false`.

The distinction is the level-3 ordering discipline: *spawn then route* stays
`≥ 1`; *route to nothing* does not. z3 draws the line, not a reviewer.

### Step 6 — Prove-before-apply: apply, or refuse-and-transact

```clojure
(println "── prove-before-apply (z3) ──")
(println "  spawn-then-route delta preserves 'host has a backend':" good-delta-ok)
(println "  drain-to-zero delta preserves it:" bad-delta-ok)

;; the reconciler applies the proven-safe delta, and REFUSES the unsafe one
(defn admit-delta [label ok?]
  (if ok?
    (do (println (str "  ✓ apply " label)) :applied)
    (do (datom/transact! conn [{:db/id -1 :refusal/why (str label ": would leave a claimed host with no backend")}])
        (println (str "  ✗ REFUSE " label " (transacted a refusal with the reason)"))
        :refused)))
(def a-good (admit-delta "spawn-then-route" good-delta-ok))
(def a-bad  (admit-delta "drain-to-zero"   bad-delta-ok))
```

`admit-delta` is the reconciler's posture in three lines: the proof's boolean is
the gate. A proven delta is **applied**; an unproven one is **refused** — the
effect is *not* performed, and the reason is transacted as a `:refusal/why`
datom. This is the doc's "errs toward stillness": the machine would rather do
nothing than apply a delta whose safety it cannot establish.

```
── prove-before-apply (z3) ──
  spawn-then-route delta preserves 'host has a backend': true
  drain-to-zero delta preserves it: false
  ✓ apply spawn-then-route
  ✗ REFUSE drain-to-zero (transacted a refusal with the reason)
```

### Step 7 — The refusal is queryable, and the assertions

```clojure
(def refusals (datom/q '[:find ?w :where [?e :refusal/why ?w]] (datom/db conn)))
```

Just like the drift choice, the refusal is read back with a query — the answer to
"what did the machine refuse, and why?" is a datalog question.

```clojure
(def ok (and (not= (:desired drift-delta) (:observed drift-delta)) ; drift was real
             (= "v1-hotfix" (desired-src (datom/db conn)))          ; commit-to-desired applied
             (= :commit choice)                                     ; the choice is a fact
             (= true good-delta-ok)                                ; safe delta proves
             (= false bad-delta-ok)                                 ; unsafe delta fails the proof
             (= :applied a-good) (= :refused a-bad)                 ; reconciler acts on the proof
             (= 1 (count refusals))))                               ; refusal is a recorded fact
```

The self-assertion pins every half of the two claims: drift was genuinely
divergent; commit wrote the hot-fix into desired (`"v1-hotfix"`); the choice is a
fact (`:commit`); the safe delta proved `true` and the unsafe one `false`; the
reconciler applied exactly the former and refused exactly the latter; and exactly
one refusal was recorded. If any link broke, the run prints `FAIL`.

## What's real vs modelled

**Real, exercised as-is:**

- `datom/connect`, `datom/transact!`, `datom/db`, `datom/q` — the production
  store. The drift decision and the refusal are **genuine datoms** written by
  real transactions (tempids, upsert through `:db.unique/identity`), and both the
  `desired-src` read, the choice read, and the refusal read are **real datalog**
  with real set semantics.
- `z3/open` — the real solver is a **supervised resource** now
  (`priv/std/z3pool.bl`): `open` returns the pool's leased handle (`:z3-leases`),
  starting the tree if it is not up. The `port` argument is kept for call-site
  compatibility and **ignored**.
- `system.core/migration-preserves?` — the **real obligation** for a hot-upgrade
  code change: `inv(v1) ∧ v2 = migrate ∧ ¬inv(v2)`, `unsat ⟹ safe`. The boolean
  it returns is `oracle/proven?`, i.e. the solver's verdict (`:status = :unsat`).
  So `good-delta-ok = true` and `bad-delta-ok = false` are **decisions of z3 over
  real SMT-LIB** (native SMT, no NIF), not a hardcoded lint. A solver that times
  out returns `:unknown`, which `proven?` treats as *not* proven → the same
  refusal, which is the fail-safe direction the doc describes.
- **The refusal is a transacted fact.** The unsafe delta is refused *and* a
  `:refusal/why` row is written; nothing is applied.

**Modelled or simplified in miniature:**

- **The "delta" handed to z3 is not spike 01's effect vector.** The reconciler's
  delta is `[{:kind :spawn …} …]`; here it is collapsed by hand to a scalar
  "post-effect backend count" — two literal SMT-LIB terms, `"(+ b 1)"` and
  `"0"`, for one host's `b2`. So the *proof machinery* is real, but the **link
  from the reconciler's actual delta to the SMT term is done by the author in the
  spike**, not computed. There is no transacted effect set fed to the prover.
- **The invariant is one host, one counter.** `(>= b2 1)` is the whole invariant.
  The design's "every claimed host has a live backend" quantifies over hosts and
  their claims; the spike proves a single variable pair.
- **Only one drift choice is exercised: `:commit`.** The doc's other branch,
  `:revert` (re-apply desired, discard the hot-fix) is named but not run — the
  spike shows the choice is recorded, with commit as the example. `:drift/svc` is
  written but never read by any query.
- **The refusal carries a human string, not the counter-example.** The doc says
  the refusal is transacted "with the counter-example"; the spike records
  `"drain-to-zero: would leave a claimed host with no backend"` and discards the
  solver's model. (`migration-preserves?` returns only a boolean here; the
  `preserves?` variant is the one that returns `:model`.)
- **No effect is performed.** `admit-delta` prints and returns `:applied` /
  `:refused`; nothing spawns, drains, or re-claims a backend. This is spike 01's
  same boundary (the reconciler's effect application is direct, not through a
  live `vm.manager`) — here the *refusal transaction* is real, the *delta's
  effect* is not.
- **Observed state is a literal string** (`"v1-hotfix"`), not a sample from
  `vm.ports` claims, the process table, or the env registry; and there is no
  gateway or route table in the spike — "spawn-then-route" exists only as the
  ordering encoded in `(+ b 1)`.
- **The invariant and declarations are passed as raw SMT-LIB strings** (the
  legacy edge: `as-cmds` and the term reader (`smtlib/read-term`) parse them at
  the border), not as forms. Consequence: variable names must be valid SMT-LIB simple symbols — an
  apostrophe (`b'`) would have to be `|b'|`-quoted, so keep SMT var names
  apostrophe-free.
- **Nothing goes through the reconciler's event loop.** The prove-before-apply
  call is a direct invocation in the script, not a `proc.server` waking on a
  transaction.

## Run it

```
./blx run research/vps_spike/13_drift_and_proof.bl
```

Expected output ends with:

```
PASS 13_drift_and_proof  (drift is a choice; the delta is proved)
```

Cold start costs ~10–15s (JIT warmup) — that latency is boot, not work. This
spike is invoked individually: `research/vps_spike/run.sh`'s batch loop globs
`0*.bl` (spikes 01–08), so 13 is run on its own with the command above.

## Exercises

1. **Weaken the invariant to `(>= v 0)`.** Change `inv` to
   `(fn [v] (str "(>= " v " 0)"))`. Predict first, then run: the *bad* delta
   `b2 = 0` now satisfies `b2 ≥ 0`, so `b ≥ 0 ∧ b2 = 0 ∧ ¬(b2 ≥ 0)` is
   unsatisfiable → `bad-delta-ok` becomes `true`, drain-to-zero is **applied**,
   `refusals` is `0`, and the run prints **`FAIL`**. Lesson: the invariant, not
   the effect, decides safety — a weaker invariant admits the dangerous delta.

2. **Make the good delta plain "drain one": `"(- b 1)"`.** Predict: the obligation
   is `b ≥ 1 ∧ b2 = b-1 ∧ b2 < 1`; `b = 1, b2 = 0` is a model → `sat` →
   `good-delta-ok` becomes `false`, so *both* deltas are refused (`refusals = 2`)
   and the run prints **`FAIL`**. Lesson: removing a backend is only safe with a
   premise (`b ≥ 2`, or a spawn already recorded); the proof needs that premise
   asserted, and the spike does not assert it.

3. **Make the bad delta a no-op: `"(+ b 0)"`.** Predict:
   `b ≥ 1 ∧ b2 = b ∧ b2 < 1` → `b < 1 ∧ b ≥ 1` → `unsat` → `bad-delta-ok` becomes
   `true`, the no-op is applied, `refusals = 0`, and the run prints **`FAIL`**.
   Shows the prover judges *preservation*, not *usefulness* — a delta that changes
   nothing passes trivially.

4. **Name an SMT variable with an apostrophe.** Rename `b`/`b2` to `b'`/`b2'`
   everywhere (decls, `inv`, the migrate terms). Predict: the raw-string path
   feeds `(>= b' 1)` to the SMT reader verbatim, and `'` is not a simple-symbol
   character in SMT-LIB, so the term is malformed or z3 misparses it — the proof
   does not run as intended. Lesson: the legacy raw-text edge does not quote
   identifiers for you; keep SMT var names apostrophe-free (or pass forms, which
   the encoder renders correctly).
