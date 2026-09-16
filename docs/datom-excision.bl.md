# Excision: the one way to make datom forget

> A **literate program**. Every `beam-lisp` block runs:
> `bl run docs/datom-excision.bl.md`.

datom is built on a promise: nothing is lost. A change appends a retraction and
an assertion; the old value does not go anywhere, it is simply no longer
current. That is what makes `as-of` and `history` possible — the past is still
here to be asked about. An audit depends on it.

But two things in the real world *require* forgetting, and no amount of
append-only history satisfies them:

- **Legal erasure.** A GDPR right-to-be-forgotten request says a person's data
  must *leave the building*. A retraction does not do that — the value is still
  right there in `history`.
- **Data that should never have been kept.** A secret committed by mistake, a
  bulk import that pulled in too much.

For exactly these, datom has **excision** — the one operation that physically
removes datoms, from every index *and* from history. It is the documented hole
in the append-only promise.

```beam-lisp
(ns guide.excision
  (:require [datom.conn] [datom.db] [datom.time] [datom.query.engine]))

(def conn
  (datom.conn/connect
    [{:db/ident :email :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
     {:db/ident :name  :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
     {:db/ident :ssn   :db/valueType :db.type/string :db/cardinality :db.cardinality/one}]))

(datom.conn/transact! conn [{:db/id -1 :email "alice@example.com" :name "Alice" :ssn "111-22-3333"}])
(def alice (:db/id (datom.db/entity (datom.conn/db conn) [:email "alice@example.com"])))
```

## Retraction hides; excision erases

First see what a retraction does — the ordinary way to say "this is no longer
true." Retract Alice, and she is gone from the current view but *still in
history*:

```beam-lisp
(datom.conn/transact! conn [{:db/id -1 :email "temp@example.com" :name "Temp"}])
(def temp (:db/id (datom.db/entity (datom.conn/db conn) [:email "temp@example.com"])))
(datom.conn/transact! conn [[:db/retractEntity temp]])

(println "temp — current:" (datom.query.engine/q '[:find ?n :where [?e :name ?n] [?e :email "temp@example.com"]]
                                                 (datom.conn/db conn)))
(println "temp — history:" (datom.query.engine/q '[:find ?n :where [?e :name ?n] [?e :email "temp@example.com"]]
                                                 (datom.time/history (datom.conn/db conn))))
```

The current view is empty; history still holds "Temp". A retraction is
reversible knowledge — you can always ask what used to be true. That is exactly
what a legal-erasure request forbids.

## Erasing one field

Alice exercises her right to have her SSN forgotten — but keeps her account.
`excise!` with an `[:attr e a]` spec removes just that attribute, from every
index and all history:

```beam-lisp
(datom.conn/excise! conn [[:attr alice :ssn]])

(def a (datom.db/entity (datom.conn/db conn) alice))
(println "ssn after erasure: " (:ssn a))
(println "name still there:  " (:name a))
(println "ssn in history:    " (datom.query.engine/q '[:find ?s :where [?e :ssn ?s]]
                                                      (datom.time/history (datom.conn/db conn))))
```

The SSN is gone from the current entity *and* from history — `history` finds
nothing. The name and account remain untouched.

## Erasing an entire entity

A full right-to-be-forgotten erases the person entirely. `[:entity e]` removes
every datom about Alice:

```beam-lisp
(def report (datom.conn/excise! conn [[:entity alice]]))
(println "datoms excised:" (:excised report))

(println "alice — current:" (datom.db/entity (datom.conn/db conn) [:email "alice@example.com"]))
(println "alice — history:" (datom.query.engine/q '[:find ?n :where [?e :name ?n] [?e :email "alice@example.com"]]
                                                  (datom.time/history (datom.conn/db conn))))
```

Alice is gone from the current database and from history alike — and even the
unique `:email` value is free again, because excision removed her from the AVET
index too, not just the fact rows. Nothing lingers.

## The honest caveat

Excision is the only operation in datom that *loses* data, and it is
irreversible — there is no `as-of` before an excision that brings the datoms
back, because they are not anywhere anymore. That is the point, and it is why it
is the single documented exception to datom's "nothing is lost" promise (see the
`datom` module header). Every other change only ever adds; this one, and only
this one, takes away.
