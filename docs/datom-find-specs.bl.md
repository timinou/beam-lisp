# A query's shape: datom's find specs and `:with`

> A **literate program**. Every `beam-lisp` block runs:
> `bl run docs/datom-find-specs.bl.md`.

Datalog answers a question about what is true, so a query's natural result is a
SET of tuples. But a caller often wants a different *shape* — one value, one
column, one row — and Datomic's **find specs** say which. datom now speaks all
four, plus `:with`, so an unmodified datalog query lands unchanged.

```beam-lisp
(ns guide.find-specs
  (:require [datom.conn] [datom.query.engine]))

(def db
  (let [c (datom.conn/connect
            [{:db/ident :name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
             {:db/ident :dept :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
             {:db/ident :pay  :db/valueType :db.type/long   :db/cardinality :db.cardinality/one}])]
    (datom.conn/transact! c
      [{:db/id -1 :name "Ada"   :dept "eng"   :pay 100}
       {:db/id -2 :name "Grace" :dept "eng"   :pay 100}
       {:db/id -3 :name "Lin"   :dept "sales" :pay 90}])
    (datom.conn/db c)))

(defn- q [query] (datom.query.engine/q query db))
```

## The four shapes

The engine runs the *same* join for all four; only the final projection differs.

```beam-lisp
;; :relation — [?a ?b] — a SET of tuples (the default)
(println "relation: " (sort (q '[:find ?n ?p :where [?e :name ?n] [?e :pay ?p]])))

;; :scalar — [?x .] — one value
(println "scalar:   " (q '[:find ?p . :where [?e :name "Lin"] [?e :pay ?p]]))

;; :collection — [[?x ...]] — a vector of one column
(println "collection:" (sort (q '[:find [?n ...] :where [?e :name ?n]])))

;; :tuple — [[?a ?b]] — one row as a vector
(println "tuple:    " (q '[:find [?n ?p] :where [?e :name ?n] [?e :name "Ada"] [?e :pay ?p]]))
```

The scalar spec is what turns a query into a lookup: `[?p .]` is "give me the
one value," not "give me a set that happens to hold one tuple." A collection
`[[?n ...]]` is the column an application actually wants to `map` over.

## `:with` — keeping duplicates for an aggregate

Because a relation is a SET, identical rows collapse. That is usually right —
but it is wrong for an aggregate over a value that repeats. Two engineers each
earn 100; how much does engineering pay in total?

```beam-lisp
;; the pay VALUES are {100, 90} as a set — [?p] over the two 100s is ONE row
(println "sum of distinct pay values: " (q '[:find (sum ?p) . :where [?e :pay ?p]]))
```

That sums `100 + 90 = 190` — it counted each *distinct salary* once, not each
person. To sum per person, `:with ?e` widens the internal tuple to `[?p ?e]`,
so the two 100s stay two rows:

```beam-lisp
(println "sum of pay per person:      " (q '[:find (sum ?p) . :with ?e :where [?e :pay ?p]]))
```

Now it is `100 + 100 + 90 = 290` — the total payroll. The `:with` variable
never appears in the result; it exists only to stop the set from collapsing the
rows the aggregate must see. (This is the behaviour kontor's payroll query
depends on — and the datom bug it exposed: `:with` used to be parsed and then
silently dropped, so every `:with` aggregate quietly returned the wrong total.)

## Grouping

An aggregate beside a plain variable groups by that variable:

```beam-lisp
;; total pay per department
(println "pay by dept: " (sort (q '[:find ?d (sum ?p) :with ?e
                                     :where [?e :dept ?d] [?e :pay ?p]])))

;; headcount per department
(println "count by dept:" (sort (q '[:find ?d (count ?e)
                                      :where [?e :dept ?d]])))
```

Engineering pays 200 across two people; sales pays 90 across one. Same join,
grouped by `?d`, folded by the aggregate — with `:with ?e` keeping the two
equal engineering salaries distinct.
