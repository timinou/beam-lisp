# datom grows an accountant's three tools

> A **literate program**. Every `beam-lisp` block runs:
> `bl run docs/datom-for-accounting.bl.md`. The prose is the argument; the code
> is the proof.

kontor is a double-entry accounting kernel. To run it on datom unmodified,
datom had to learn three things a ledger cannot do without — and each was added
as a *datom feature*, not a kontor-specific patch. This is the tour.

```beam-lisp
(ns guide.accounting
  (:require [datom.conn] [datom.db] [datom.query.engine] [datom.index] [decimal :as dec]))
```

## 1. Exact money: `:db.type/decimal`

A balance is not a float. `0.1 + 0.2` is `0.30000000000000004` in binary
floating point, and an accountant who is off by `4e-17` is off. datom's
`:db.type/decimal` stores an exact `BeamLisp.Decimal` — an integer `unscaled`
and a `scale` — so a cent is a cent forever.

```beam-lisp
(def conn
  (datom.conn/connect
    [{:db/ident :account/id      :db/valueType :db.type/string
      :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
     {:db/ident :account/balance :db/valueType :db.type/decimal
      :db/cardinality :db.cardinality/one :db/index true}]))

(datom.conn/transact! conn
  [{:db/id -1 :account/id "cash" :account/balance (dec/of "100.05")}
   {:db/id -2 :account/id "bank" :account/balance (dec/of "100.50")}
   {:db/id -3 :account/id "petty" :account/balance (dec/of "9.99")}])
```

The crucial property is not storage but ORDER. A decimal is indexed among every
other number by its true numeric value, so `100.05M` sorts below `100.50M` —
where a naive string or term encoding would put `100.5` before `100.05` and a
range scan over an amount would bracket the wrong window:

```beam-lisp
(defn- balance-of [id]
  (:account/balance (datom.db/entity (datom.conn/db conn) [:account/id id])))

(println "cash  =" (dec/plain-str (balance-of "cash")))
(println "bank  =" (dec/plain-str (balance-of "bank")))

;; every stored balance, read back and sorted by true value — the AVET order
(def all-balances
  (->> (datom.query.engine/q
         '[:find ?bal :where [?e :account/balance ?bal]]
         (datom.conn/db conn))
       (map first)
       (sort (fn [a b] (<= (dec/compare a b) 0)))
       (map dec/plain-str)))
(println "ascending:" all-balances)
```

`1.0M` and `1.00M` are the *same* number, so they index to the SAME key — an
amount collides by value, never by how it was written:

```beam-lisp
(println "1.0M == 1.00M by value:" (= 0 (dec/compare (dec/of "1.0") (dec/of "1.00"))))
```

## 2. A composite key: `:db/tupleAttrs`

A posting is identified by its transaction AND its sequence within it —
neither alone is unique. datom's `:db.type/tuple` with `:db/tupleAttrs` derives
a composite value from its components and enforces uniqueness on the pair:

```beam-lisp
(def ledger
  (datom.conn/connect
    [{:db/ident :posting/tx  :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
     {:db/ident :posting/seq :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
     {:db/ident :posting/key :db/valueType :db.type/tuple
      :db/tupleAttrs [:posting/tx :posting/seq]
      :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}]))

(datom.conn/transact! ledger [{:db/id -1 :posting/tx 100 :posting/seq 1}])
(println "derived key:" (:posting/key (datom.db/entity (datom.conn/db ledger) [:posting/key [100 1]])))

;; a second posting reusing (100, 1) is refused — the composite key is unique
(println "duplicate (100,1) refused:"
  (try (datom.conn/transact! ledger [{:db/id -2 :posting/tx 100 :posting/seq 1}]) "COMMITTED (wrong!)"
    (catch e "refused")))

;; (100, 2) is a different posting, and commits
(datom.conn/transact! ledger [{:db/id -3 :posting/tx 100 :posting/seq 2}])
(println "distinct postings:"
  (count (datom.query.engine/q '[:find ?k :where [?e :posting/key ?k]] (datom.conn/db ledger))))
```

The key was never asserted — the writer *derived* `[100 1]` from the two
component attributes, and recomputes it whenever a component changes.

## 3. An invariant that holds at the door: `guard!`

Double-entry's law is that every transaction balances: debits equal credits. In
a ledger that law must be enforced at the WRITER, so no unbalanced entry can
ever land — not in the application, which can be bypassed. datom's `guard!`
registers a predicate that runs over the fully-resolved transaction before it
commits; a non-nil result refuses it, atomically.

```beam-lisp
(def books
  (datom.conn/connect
    [{:db/ident :entry/batch  :db/valueType :db.type/long    :db/cardinality :db.cardinality/one}
     {:db/ident :entry/amount :db/valueType :db.type/decimal :db/cardinality :db.cardinality/one}]))

;; the law: the amounts in one transaction must sum to zero
(datom.conn/guard! books :balances
  (fn [report]
    (let [amounts (->> (:tx-datoms report)
                       (filter (fn [d] (= :entry/amount (datom.index/-a d))))
                       (map datom.index/-v))
          total (reduce (fn [acc a] (dec/add acc a)) (dec/of "0") amounts)]
      (if (= 0 (dec/compare total (dec/of "0"))) nil {:unbalanced (dec/plain-str total)}))))
```

A balanced entry (debit +100, credit −100) commits:

```beam-lisp
(datom.conn/transact! books
  [{:db/id -1 :entry/batch 1 :entry/amount (dec/of "100.00")}
   {:db/id -2 :entry/batch 1 :entry/amount (dec/of "-100.00")}])
(println "balanced entry committed:"
  (count (datom.query.engine/q '[:find ?e :where [?e :entry/batch 1]] (datom.conn/db books))))
```

An unbalanced one (debit +100, credit −90) is refused at the writer, and leaves
nothing behind:

```beam-lisp
(println "unbalanced entry:"
  (try (datom.conn/transact! books
         [{:db/id -3 :entry/batch 2 :entry/amount (dec/of "100.00")}
          {:db/id -4 :entry/batch 2 :entry/amount (dec/of "-90.00")}])
       "COMMITTED (wrong!)"
    (catch e "refused")))
(println "batch 2 datoms after refusal:"
  (count (datom.query.engine/q '[:find ?e :where [?e :entry/batch 2]] (datom.conn/db books))))
```

## What this bought

Three features, each general to datom and each the projection target of a
datahike spelling kontor uses: `:db.type/bigdec` → `:db.type/decimal`,
`:db/tupleAttrs` unchanged, `datahike.tx-preds/register-tx-pred!` → `guard!`.
An accounting kernel needs exactly these — exact money, composite identity, and
an invariant the writer enforces — and datom now has them, natively.
