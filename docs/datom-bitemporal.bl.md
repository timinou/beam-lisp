# Two axes of time: when we recorded it, and when it was true

> A **literate program**. Every `beam-lisp` block runs:
> `bl run docs/datom-bitemporal.bl.md`.

A ledger has to answer two different questions about the past:

- *What did we believe on Tuesday?* — **transaction time**, when a fact was
  recorded. datom answers it with `as-of`.
- *What was actually true on Tuesday?* — **valid time**, when a fact is true in
  the world, regardless of when we learned it. datom answers it with
  `valid-at`.

They are independent, and a system that keeps both is *bitemporal*. Accounting
needs it: a correction entered in March for a January transaction is true *of
January* but recorded *in March*, and an auditor must be able to see it either
way. This is the tour of datom's second axis.

```beam-lisp
(ns guide.bitemporal
  (:require [datom.conn] [datom.db] [datom.time] [datom.pull] [datom.query.engine]))
```

## Recording facts with a valid-time window

A transaction can carry a valid-time window — `:db.valid/from` and
`:db.valid/to` on the transaction entity (the `:db/current-tx` sentinel). It
says "the facts in this transaction are true in the world over `[from, to)`."
Here a product's price is 100, true for the first half of the year, then 120:

```beam-lisp
(def conn
  (datom.conn/connect
    [{:db/ident :sku :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
     {:db/ident :price :db/valueType :db.type/long :db/cardinality :db.cardinality/one}]))

;; the SKU exists for all time (an unbounded transaction)
(datom.conn/transact! conn [{:db/id -1 :sku "WIDGET"}])

(def sku-eid (:db/id (datom.db/entity (datom.conn/db conn) [:sku "WIDGET"])))

;; price 100, valid over days 1..180
(datom.conn/transact! conn
  [{:db/id sku-eid :price 100}
   {:db/id :db/current-tx :db.valid/from 1 :db.valid/to 180}])

;; price 120, valid from day 180 onward
(datom.conn/transact! conn
  [{:db/id sku-eid :price 120}
   {:db/id :db/current-tx :db.valid/from 180}])
```

## Reading at a point in valid time

`valid-at` gives a database value that shows only the facts true at that
world-instant. The engine filters inside `db/datoms`, so `q`, `pull` and
`entity` all agree:

```beam-lisp
(defn- price-at [t]
  (datom.query.engine/q '[:find ?p . :where [?e :price ?p]]
                        (datom.time/valid-at (datom.conn/db conn) t)))

(println "price on day 90:  " (price-at 90))   ; first window
(println "price on day 200: " (price-at 200))  ; second window
(println "price on day 180: " (price-at 180))  ; from is inclusive, to exclusive
```

Day 90 sees 100; day 200 sees 120; day 180 belongs to the second window (the
`from` bound is inclusive, `to` exclusive — the same half-open convention that
makes windows tile without overlap).

## The bitemporal property

Here is what makes this more than a second timestamp. In *transaction* time, the
second write superseded the first — the current database holds only 120:

```beam-lisp
(println "current price (no time filter):"
  (datom.query.engine/q '[:find ?p :where [?e :price ?p]] (datom.conn/db conn)))
```

But the price *was* 100 on day 90, and asking valid-at day 90 still says so —
even though that value was later superseded. datom filters by valid time
*before* applying transaction-time supersession, so the old truth survives at
its own moment:

```beam-lisp
(println "price on day 90, still:" (price-at 90))
```

A superseded fact is gone from *now* but present *then*. That is the property an
audit depends on.

## `pull` and `entity` honour it too

Because the filter lives at the single read seam, a shaped read sees the same
world:

```beam-lisp
(println "pulled @day 90: "
  (:price (datom.pull/pull (datom.time/valid-at (datom.conn/db conn) 90) [:price] [:sku "WIDGET"])))
(println "pulled @day 200:"
  (:price (datom.pull/pull (datom.time/valid-at (datom.conn/db conn) 200) [:price] [:sku "WIDGET"])))
```

## A range: `valid-between`

`valid-between` asks for every fact true at *any* point in a range — so a range
spanning both windows sees both prices. Unlike a point read, a range does not
collapse to one current value; every value true somewhere in it belongs:

```beam-lisp
(println "prices true across days 90..200:"
  (sort (datom.query.engine/q '[:find ?p :where [?e :price ?p]]
                              (datom.time/valid-between (datom.conn/db conn) 90 200))))
```

## The two axes compose

`as-of` (transaction time) and `valid-at` (valid time) stack: *"as of what we
knew at transaction T, what was true at valid-time V?"* is
`(valid-at (as-of db T) V)` — the full bitemporal question, and the one a
regulator actually asks. Each axis is one filter at the same seam, so composing
them is just composing two `db` values.
