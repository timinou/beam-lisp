# Relations as first-class citizens

A **relation** in this system is not "a set of tuples". It is a citizen with
seven dignities a stored attribute has always had, now extended to *computed*
knowledge:

| axis | meaning |
|---|---|
| 1 extension | where tuples come from — `:stored` \| `:derived` \| `:computed` |
| 2 schema-as-data | the relation describes itself as `:relation/*` datoms |
| 3 access modes | bound/free adornments — `:bf` `:bb` `:fb` |
| 4 basis | a pure function of the db value → time-travels, caches soundly |
| 5 maintenance | behaviour under a delta — `:recompute` \| `:incremental` |
| 6 provenance | why each tuple exists |
| 7 cost | an estimate for the planner |

The payoff is **indistinguishability**: `[?a :cites ?b]` (stored) and
`[?a :~similar ?b]` (computed) sit side by side in one `:where`, join the same
way, and recurse through the same native fixpoint. A computed relation is
declared with `defrelation` and a *provider* — and the provider is a swappable
configuration decision, so the query names the **meaning**, never the mechanism.

## The series

Each file is runnable offline (a deterministic fake embedder stands in for a
real model; the query syntax and engine are exactly what a real deployment
uses — only the vector *source* is a toy).

```
mix beam_lisp.run --path priv --path examples examples/relations/01-defrelation.bl
```

| # | file | what it shows |
|---|---|---|
| 01 | `01-defrelation.bl` | declare a computed relation; call & attribute spellings |
| 02 | `02-access-modes.bl` | one relation, three modes: generate · filter · reverse |
| 03 | `03-not-married-to-knn.bl` | swap the provider (knn → threshold → fn → hybrid), query unchanged |
| 04 | `04-semantic-recursion.bl` | **the unlock** — recursion over `:~similar` runs native |
| 05 | `05-cheapest-explanation.bl` | ranking as arithmetic-in-recursion (coherence path) |
| 06 | `06-label-propagation.bl` | semi-supervised labels — the fixpoint *is* the algorithm |
| 07 | `07-graphrag-provenance.bl` | multi-hop retrieval that carries its own justification |
| 08 | `08-temporal-diff.bl` | diff two closures across `as-of` — what became true |
| 09 | `09-catalog-as-data.bl` | the catalog is queryable; relations describe themselves |
| 10 | `10-relation-polymorphism.bl` | `[?a ?rel ?b]` — `?rel` is a **variable**; quantify over relations |
| 11 | `11-far-dream.bl` | all powers in one query: retrieve · reason · rank · time · meta |

## The core API

```clojure
(require '[datom.query.relation :as rel]
         '[datom.query.relations :as rels])   ; provider library

(rel/defrelation :~similar
  {:arity 2 :modes #{:bf :bb :fb} :tags #{:semantic}
   :args []                                    ; fixed at declaration (attr spelling)
   :provider (rels/knn-adjacency :doc/embedding {:k 8 :threshold 0.75})})
```

Then `[?a :~similar ?b]` is an edge — join it, recurse it, reverse it, ask the
catalog about it. Swap `knn-adjacency` for `threshold-adjacency`,
`fn-adjacency`, or `union-adjacency` and every query is unchanged.
