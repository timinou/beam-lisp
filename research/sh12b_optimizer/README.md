# sh12b — the optimizer is a set of datalog queries (P12b)

Nugget 6: once the compiler is indexed as datom facts (P12), optimization
DECISIONS become datalog QUERIES over the program-as-facts, not ad-hoc analyses.

`optimizer_queries.bl` runs two, over the self-hosted compiler itself:

## Inline candidates — functions called from exactly one site
```
(filter #(= 1 (call-count %)) all-fns)   ; a datalog count per callee
=> 61 functions called exactly once — inline candidates
```

## Dead code — defined, never called
```
(filter #(not (contains? called %)) all-fns)
=> found real dead code in the compiler: ast-dot, module-atom, compile-defn
   (superseded by compile-defn*)
```

The dead-code query **found genuine unused helpers** in priv/compiler.bl — the
language analyzing itself improved itself. (A known limitation surfaced too:
`parse-require-spec` is called via `(map parse-require-spec ...)`, a
higher-order reference the direct-call-site query misses — so the query is a
CANDIDATE finder, confirmed before removal, exactly as a real optimizer's
liveness pass would be.)

## Why this matters

"Our optimizer is a set of datalog queries over the program" is only sayable
because self-hosting + datom + codebase exist together. The optimizer is a
RULESET over facts, inspectable and composable, not a black box. This is the
tier-1 layer the two-tier architecture reserves for AFTER the kernel: it
depends on the full library stack (datom, codebase), which the kernel compiles.

## Reproduce
```
mix beam_lisp.run research/sh12b_optimizer/optimizer_queries.bl
```
