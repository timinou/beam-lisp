# Branches: a what-if book that never touches the ledger

> A **literate program**. Every `beam-lisp` block runs:
> `bl run docs/datom-branches.bl.md`. It uses the `datahike.api` an unmodified
> Clojure library calls; branches are a datahike feature, projected onto datom.

Sometimes you want a *whole database* to play with — seed it once, then let many
independent scenarios each scribble on their own copy without disturbing the
original or each other. A test suite wants it (a fresh book per test, off one
seeded template). A planner wants it (what would next quarter look like under
different assumptions?). datom's **branches** give it, as a named copy-on-write
overlay: a branch sees the base's data, keeps its own writes private, and never
merges back.

```beam-lisp
(ns guide.branches
  (:require [datahike.api :as d]))

(def schema
  [{:db/ident :account :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
   {:db/ident :balance :db/valueType :db.type/long   :db/cardinality :db.cardinality/one}])

(defn- balances [conn]
  (sort (d/q '[:find ?a ?b :where [?e :account ?a] [?e :balance ?b]] (d/db conn))))
```

## Seed the template once

```beam-lisp
(def cfg {:store {:backend :memory :id "ledger-template"}})
(d/create-database cfg)
(def books (d/connect cfg))
(d/transact books schema)
(d/transact books
  [{:db/id -1 :account "cash" :balance 1000}
   {:db/id -2 :account "loan" :balance -500}])

(println "template:" (balances books))
```

## Branch, and scribble freely

Two analysts each take a branch. One models paying the loan down from cash; the
other models a cash withdrawal. Each connects over their own branch, and refers
to accounts by lookup ref — the shim resolves those, so a scenario reads like
ordinary datahike:

```beam-lisp
(d/branch! books :db :payoff)
(d/branch! books :db :withdraw)

(def payoff   (d/connect (assoc cfg :branch :payoff)))
(def withdraw (d/connect (assoc cfg :branch :withdraw)))

;; scenario A: clear the loan, paying from cash
(d/transact payoff
  [{:db/id [:account "loan"] :balance 0}
   {:db/id [:account "cash"] :balance 500}])

;; scenario B: withdraw 300 cash
(d/transact withdraw
  [{:db/id [:account "cash"] :balance 700}])
```

## Each branch is its own world

```beam-lisp
(println "payoff branch:  " (balances payoff))
(println "withdraw branch:" (balances withdraw))
(println "template still: " (balances books))
```

The payoff branch shows the loan cleared and cash at 500; the withdraw branch
shows cash at 700 and the loan untouched; and the template is exactly as it was
seeded — 1000 and −500. Three databases, one seeding, no interference.

## Why this is cheap

A branch is a copy-on-write overlay: reads fall through to the shared base, and
only a branch's *own* writes cost anything. Seeding a hundred-entity template
once and branching it per test is O(1) per test, where re-seeding would be
O(entities). It is the same overlay datom uses for speculative `db-with` — a
branch is just a speculation that got a name and outlived one call.

And a branch never merges back: a what-if is *discarded*, not applied. The
ledger of record only ever changes through a real transaction on the base.
