# Bounded query pages and lexical candidates

`datom/q-page` walks an ordered index at an immutable database basis. It admits
ordinary cardinality-one patterns, forward joins, and bound core comparisons
(`=`, `not=`, `<`, `<=`, `>`, `>=`). Project the driving entity to preserve set
semantics without an unbounded cross-page deduplication set. Order by that
entity (AEVT) or a cardinality-one indexed value (AVET).

```clojure
(datom/q-page '[:find ?c ?text ?title
                :where [?c :chunk/text ?text] [?c :chunk/src ?s]
                       [?s :src/title ?title]]
              database {:order-by ['?c :asc] :limit 20
                        :authorization {:principal caller :library library}})
```

The result is `{:status :exact|:incomplete|:refused :rows [...] :after token
:more? boolean}`. Repeat the query, inputs, order, limit, authorization and DB
basis with `:after`. Cursors expire after at most five minutes and live in a
bounded server cache. There is no exact total. Unsupported aggregates, fanout,
computed relations and non-injective projections refuse. Permissions run before
admission. Supply `:budget {:rows 4096 :seeks 4096 :bytes 8388608}` to change
physical work bounds. An incomplete result exposes no partial rows: continuation
retains accepted rows. One attribute history group must fit the budget; otherwise
raise it within allowed limits. Arbitrary Datalog remains available through `q`.

## Lexical candidate index

Opt a cardinality-one string attribute into `:db/fulltext true`. Internal
trigram and word postings share the source transaction's commit, preserve
history, and are invisible to ordinary Datalog. Values are capped at 1 MiB;
split documents into passages. This adds write and storage cost.

```clojure
(require '[datom.text :as text])
(text/candidates database :chunk/text "liberté contractuelle"
                 {:rows 100000 :seeks 4096 :bytes 16777216})
```

An exact result contains `:eids`, physical posting rows and seeks. It is a
**candidate superset**, not a ranked answer. Verify texts with the application's
ranker and permission filters. Semantics target folded phrase/substring matches
and at least half of query tokens matching by exact/forward/reverse containment
(reverse containment requires both words to have at least four bytes, as in
Knowledger). Folding removes combining accents and Arabic harakat/tatweel.
Selectivity counts are hints: unknown or stale counts never skip a probe.

Budgets bound posting reads and retained candidate state. Exhaustion returns
`:incomplete` without an entity set. Queries above 16 KiB refuse; phrases shorter
than three codepoints, words over 32 bytes, or more than 64 tokens decline the
index. An application can stream ordered text pages with bounded top-k retention
for these cases. Unsupported views/substrates refuse; no silent partial answer.

Existing populated columns require an authorized maintenance backfill:

```clojure
(text/reindex-page! database :chunk/text {:limit 128 :bytes 8388608})
;; Repeat with :after from the result until :status is :exact.
```

Backfill uses opaque, store/schema-bound cursors and includes source history.
Only completion publishes readiness. New writes maintain postings during the
backfill. Per-attribute committed write marks invalidate readiness when an older
runtime or disabled index writes source data. Rebuild after an index version
change. Backfill does not reconstruct selectivity hints; correctness is unaffected,
but candidate probes can be less selective. Serialize maintenance with schema changes and excision:
backfill does not own the connection's writer lock across its page read/commit.
Posting metadata is private storage, so only expose maintenance to trusted callers.
