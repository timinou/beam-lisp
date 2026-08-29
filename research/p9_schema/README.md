# P9 — schema bridge: findings

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p9_schema")
      BeamLisp.run_file("research/p9_schema/run.bl")'
```

## The questions

Are schemas statically available? What's the boundary rule for
runtime-built ones? Can one query's result type be inferred?

## Answers

1. **YES, statically available in the dominant style.** Schemas in this
   ecosystem are literal data: `(datom/install-schema! conn [{:db/ident
   … :db/valueType …} …])` and `(def schema […])` are both readable
   from source. The spike's extractor picked up all three attrs from
   BOTH spellings. (Schemas also live IN the database as datoms — but
   the transaction that installs them is static text.)
2. **Column inference works**: `[:find ?name ?age :where [?e
   :person/name ?name] [?e :person/age ?age]]` over the extracted
   schema → `?name (:string)`, `?age (:int)`. The valueType→tag map:
   string→string, long→int, boolean→bool, keyword→kw, ref→int (entity
   ids are longs), instant/term→any, vector→vec. The enum has NO float
   — longs carry numbers.
3. **Boundary rule (runtime-built attrs)**: an attr absent from the
   statically-known schema types its var `any` AND records a deferred
   constraint keyed by attr (L7: retry when a later ns install-schema!
   resolves it; silent at DAG-end). Demonstrated: `:person/mood` →
   deferred, not warned.
4. **The handoff pays**: inferred columns fed as a binding env into
   typed/walk catch downstream misuse (`(double name)` → string into
   int-declared fn) while `(+ age 1)` stays silent.

## Consequences

- P8's verdict gets its multiplier confirmed: query results are where
  caller-side precision comes from. (Full integration — `(datom/q …)`
  calls yielding row types inside typed/walk — needs collection-element
  types, a v2 lattice item; the env-handoff shape demonstrated here is
  the integration contract.)
- The deferred-constraint mechanism (P15e) now has its first real
  client: unknown-attr query vars.
- extract-schemas watches `install-schema!` and literal `def`s; a
  migration-built schema (examples/datom/09-migrations.bl style) is
  still literal data and will extract — worth a P10-scale confirmation.
