# datahike on datom: one engine, wearing another's API

> A **literate program**. Every `beam-lisp` block runs:
> `bl run docs/datahike-on-datom.bl.md`. The prose is the argument; the code is
> the proof. It uses the `datahike.api` an unmodified Clojure library reaches
> for — and every call lands on beam-lisp's native `datom` engine underneath.

kontor is a double-entry accounting kernel written in Clojure against
[datahike](https://github.com/replikativ/datahike). 63 of its namespaces begin
`(:require [datahike.api :as d])`. We are not porting kontor and we are not
re-implementing datahike. We run kontor *unmodified*, and `datahike.api` is a
**thin projection** onto `datom`, the Datalog store beam-lisp already has.

The rule, stated once so the rest of the file can be read against it:

> Every function in the shim either hands its arguments straight to `datom.*`,
> or rewrites data (a config map into a store, an op keyword, a report key, a
> string tempid). If a shim function ever grew a loop over datoms, it would
> have stopped *projecting* and started *emulating* — a second engine that must
> agree with the first. That is the one thing we refuse.

```beam-lisp
(ns guide.datahike
  (:require [datahike.api :as d]))
```

## A database, the datahike way

datahike separates *creating* a database from *connecting* to it, and names one
by its config's store id. datom hands out a connection directly. The shim keeps
a small config→connection registry so the datahike lifecycle works unchanged:

```beam-lisp
(def cfg {:store {:backend :memory :id "ledger"}})
(d/create-database cfg)
(def conn (d/connect cfg))
```

## Schema is data, transacted

In datahike you install schema by *transacting* attribute-definition maps.
datom takes schema through its own writer path. The shim notices the schema
maps in a transaction (a `:db/ident` with no `:db/id`), installs them, and lets
the rest through — so kontor's `(d/transact conn schema)` just works:

```beam-lisp
(d/transact conn
  [{:db/ident :account/id     :db/valueType :db.type/string
    :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
   {:db/ident :account/name   :db/valueType :db.type/string
    :db/cardinality :db.cardinality/one}
   {:db/ident :account/balance :db/valueType :db.type/long
    :db/cardinality :db.cardinality/one}])
```

## Writing, with string tempids

datahike accepts *string* tempids — `"a1"`, `"a2"`, or anything a program
generates with `(str …)`. datom accepts negative integers. The shim maps every
distinct string in a transaction to a fresh negative id, and hands you back a
datahike-shaped report — note the `:tx-data` key (datom calls it `:tx-datoms`;
the rename is the one place kontor reads by a datahike-specific name):

```beam-lisp
(def report
  (d/transact conn
    [{:db/id "a1" :account/id "cash" :account/name "Cash"    :account/balance 100}
     {:db/id "a2" :account/id "bank" :account/name "Bank"    :account/balance 250}
     {:db/id "a3" :account/id "owe"  :account/name "Payable" :account/balance -80}]))

(println "tx-data datoms:" (count (:tx-data report)))
```

## Reading: query, pull, entity — straight through

A datalog query is *data*, and it is the same data on both engines. datahike
puts the database first among a query's inputs; datom puts it after the query.
That argument order is the whole of what the shim does to `q`:

```beam-lisp
(def db (d/db conn))

;; every account with a positive balance, by name
(println "in credit:"
  (sort (d/q '[:find ?name ?bal
               :where [?e :account/name ?name]
                      [?e :account/balance ?bal]
                      [(> ?bal 0)]]
             db)))
```

`pull` shapes a tree out of the graph. datahike omits `:db/id` unless you ask
for it; datom always carries it. The shim drops the unrequested `:db/id`, so a
pull returns what a datahike caller expects:

```beam-lisp
(println "pull cash:" (d/pull db [:account/name :account/balance] [:account/id "cash"]))
```

`entity` reads a whole entity as a flat map. kontor routinely names an entity by
a **lookup ref** — `[:account/id "bank"]` — rather than a raw id. datom's
`entity` learned to resolve lookup refs natively (its `pull` and `q` already
did), so this reads the same on both engines:

```beam-lisp
(def bank (d/entity db [:account/id "bank"]))
(println "bank name:" (:account/name bank) "balance:" (:account/balance bank))
```

## Speculation without commitment

`db-with` answers "what *would* the database look like if I transacted this?"
without touching the connection. datom builds exactly such a speculative value
(a store overlay); the shim points datahike's db-scoped `db-with` at it:

```beam-lisp
(def hypothetical
  (d/db-with db [{:db/id "x" :account/id "petty" :account/name "Petty Cash"
                  :account/balance 20}]))

(println "accounts now:"        (count (d/q '[:find ?e :where [?e :account/id _]] db)))
(println "accounts if applied:" (count (d/q '[:find ?e :where [?e :account/id _]] hypothetical)))
```

The real connection never saw the petty-cash account: `db` still answers three,
the speculative value four. One engine, two database *values* over it.

## What just happened

Every call above went to `datom`. `d/q` reordered one argument; `d/transact`
split schema from data and renamed a key; `d/pull` dropped an id; `d/entity`
and `d/db-with` were pure pass-throughs onto datom features that already
existed or grew one small, general capability (lookup-ref resolution). There is
no datahike engine here to keep in sync — only its vocabulary, spoken by datom.

That is the shape of the whole compatibility tier: the surface an unmodified
library expects, projected onto the one store that actually holds the facts.
