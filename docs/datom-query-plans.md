# datom query plans

A datalog query answers correctly whether or not it is fast. What decides
the cost is the planner: which index serves each clause, and in what order
the clauses run. This document is about reading that plan, and about the
one shape that turns a small query into a quadratic one.

## What the planner does

A pattern `[?e :person/name "Ada"]` has three addressable positions. At
the moment it runs, each position is bound (a literal, or a variable an
earlier clause bound) or free. The bound positions pick an index:

| bound              | index | reads                              |
|--------------------|-------|------------------------------------|
| entity             | EAVT  | one entity's facts                 |
| attribute + value  | AVET  | who has this value — a prefix scan |
| value (a ref)      | VAET  | what points at this entity         |
| attribute          | AEVT  | every value of that attribute      |
| nothing            | EAVT  | the whole database                 |

AVET exists only for an attribute that is `:db/index true` or `:db/unique`
(uniqueness implies indexing). Without it, a clause that knows the value
falls back to AEVT — the whole column — and filters. `datom.query.plan`
holds `index-for` (the choice) and `order-clauses` (the order), and
`plan-trace` reports both without running the query.

## A nested clause runs once per row

`:not`, `:not-join`, `:or` and `:or-join` hold sub-clauses. The engine
evaluates those sub-clauses **once per outer row** — that is what
negation and disjunction mean here. So a scan inside one is not one scan:
it is one scan per row the outer query produces.

That is the whole smell. A nested clause that binds an attribute value,
over an attribute with no AVET entry, reads the entire column for every
outer row. Twenty-eight files, one such query, sixty-two seconds. Nothing
in the query text shows it; the `:db/index` flag lives in the schema, and
the plan exists only at run time.

A scan that is not nested is fine. The first clause of a query reads a
column once; that is unavoidable and the planner knows it.

## Reading a report

`datom/explain` returns the plan and the smells; `datom/explain-str`
renders it. Against a database value the schema is exact; against a schema
vector or a schema map it is exact too; against `nil` the explainer assumes
the worst case and marks every smell `:certain false` — a risk, not a
verdict.

```beam-lisp
(ns plan-demo (:require [datom]))

(println
  (datom/explain-str
    '[:find ?caller
      :where
      [?c :call/caller ?caller]
      [?c :call/callee ?callee]
      [:not-join [?callee] [?d :fn/name ?callee]]]
    nil))
```

The output lists each clause with its index, components and cost, then
each smell with the clause and a note, then a verdict:

```
plan:
  [?c :call/caller ?caller]   index=[:aevt [:call/caller]]  cost=4  bound=#{}
  [?c :call/callee ?callee]   index=[:eavt [?c :call/callee]]  cost=1  bound=#{?c ?caller}
  [:not-join [?callee] [?d :fn/name ?callee]]   index=[:eavt [:not-join [?callee]]]  cost=0  bound=#{?c ?callee ?caller}
smells:
  [?d :fn/name ?callee]  →  [:aevt [:fn/name]]
      ...
verdict: 1 per-row rescan
```

## The two remedies

1. **Index the attribute.** `:db/index true`, or `:db/unique`, so AVET
   holds an entry and the clause becomes a prefix scan.
2. **Hoist the sub-query.** Build its answer once outside the outer loop —
   a set, a `memo`, or an `index!` step — and join against that. This is
   the fix to reach for when the attribute cannot be indexed, or when the
   sub-query is expensive for a reason other than one scan.

A file with no readable schema can only flag the *risk* of a per-row
rescan. `datom/explain` against the live connection shows the exact plan,
which is how a flagged query is confirmed or dismissed.

## In the tooling

`bl lint` runs the explainer over every quoted `[:find …]` literal it
finds in source and reports a `datalog/nested-scan` smell when one carries
a per-row rescan. The rule is **advisory**: its fix is a restructure, not
a local rewrite, so it carries a note instead of an `after` text. The
explainer loads lazily, so linting ordinary code never pays for it.

The lint rule has no schema, so it assumes the worst and reports the risk.
Two shapes it therefore flags that are already fast: a clause over a
`:db.type/ref` attribute (VAET serves it), and one over an attribute
declared `:db/index` or `:db/unique` somewhere else (AVET serves it). Both
are prefix reads. Confirm with `datom/explain` against the live connection
before changing a query the rule names — and when the query IS quadratic,
hoist it: the rule's first run over this repository's own library found
two per-row rescans (`system.knowledge/unhandled-sends` and the catalog's
anti-join), both fixed by hoisting.
