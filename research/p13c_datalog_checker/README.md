# P13c — datalog-as-checker on datom: findings

Run:
```
elixir -pa _build/test/lib/beam_lisp/ebin $(for d in deps/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p13c_datalog_checker")
      BeamLisp.run_file("research/p13c_datalog_checker/checker.bl")'
```

## What was built

`checker.bl` — a tiny codebase (5 defns, 8 call sites incl. 3 planted
bugs) turned into datom facts by walking reader-shaped forms, then three
checks expressed as QUERIES:

1. **arity mismatch** — `[?d :fn/name ?callee]` +
   `:not-join [?callee ?n]` over `:fn/arity`. Found `(double 5 6)` and
   `(greet)`.
2. **unknown callee** — `:not-join [?callee]` over `:fn/name`, core
   whitelist applied to the result. Found `watzit`.
3. **call-graph reachability** — recursive rules via `:in $ %`
   (`reaches` over `calls`). Full transitive set from `main`.

## Answers to the capability questions

- **Stratified negation: YES** — `:not-join` (join-aware) and plain
  `:not` exist; `:not-join` names the outside-bound vars and
  existentially quantifies the rest, which is exactly the
  "no definition has BOTH" shape checkers need.
- **Recursive rules: YES** — bottom-up fixpoint with the native kernel;
  rule invocation composes with ordinary clauses.
- **fn calls in clauses: YES, flat only.** Predicate clauses like
  `[(> ?x 3)]` work, but `(not (contains? …))` does NOT evaluate
  (nesting unsupported), and a local `defn` is invisible to the engine
  ("unknown predicate" — resolution happens against the engine's env,
  not the caller's). **Design consequence: keep queries structural;
  do value-level filtering in the host language on query results.**
  This is a convention the checker can live with — or a future engine
  improvement (resolve predicates against the query's `:source-ns`).

## The Formulog argument holds

Each check is 5–7 lines of declarative query — no traversal code, no
state. Adding a check is adding a query. The fact extractor
(`extract-facts`) is the only procedural part, and in production it
disappears: the compiler already walks every form, so facts can be
emitted during compile and cached beside the beams (FEAT-002).

Yield #1 (the codebase becomes a database) is feasible TODAY with the
shipping engine — no new machinery required for the structural tier.
