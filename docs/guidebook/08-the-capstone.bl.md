# 08 — The capstone: all five bundles, one program

*Guidebook chapter 8. Reads after chapters
[03](03-the-fence.bl.md)–[07](07-the-supervisor.bl.md). This is where they
stop being five ideas and become one program.*

---

## The shape

`examples/bundles/00-all-five.bl` is a job shop — deliberately tiny,
deliberately complete:

```clojure
(defserver ^{:invariant (>= done 0)} worker …)   ; 04: a promise on state
(bus/defbus results-bus (demand 32))              ; 06: streams with backpressure
(bus/defbus errors-bus  (demand 8))
(reg/defregistry workers (keys :id))              ; 05: find by what it is
(super/defsupervisor app                          ; 07: a tree that heals
  (strategy :one-for-one)
  (intensity 5 10000)
  (child :workers-reg workers     nil {:name :workers})
  (child :results     results-bus nil {:name :results-bus})
  (child :errors      errors-bus  nil {:name :errors-bus})
  (child :pool        (pool worker 3)))
```

Sixteen jobs go in. Job 7 hangs; job 13 crashes. Neither is handled anywhere —
that's the point of the demo: the *bundles* absorb them.

## What each bundle does in the dark

**The fence (03)** wraps every job: `(fence 50 (process j))`. Fifty
milliseconds, then the answer is one of three maps. Job 13's crash becomes
`{:crash …}`; job 7's hang becomes `{:timeout true}`. The worker never
crashes *because of a job* — only its own bugs may kill it.

**The buses (06)** carry outcomes. Good results to `:results-bus`, bad ones —
with a *reason*, because the fence hands you one — to `:errors-bus`. The
script subscribes to the error bus with `(flow/subscribe … {:demand 1})`: one
event at a time, backpressure all the way back to the worker.

**The registry (05)** knows the workers as `{:id 0}`, `{:id 1}`, `{:id 2}`.
Each worker registers itself in `init`; the registry monitors each pid, so a
dead worker's entry retracts itself. The script asks for stats by *name*:

```clojure
(call [:workers {:id 2}] :stats)   ; → 6  (jobs done)
```

**The supervisor (07)** owns them all. When the script kills worker 1 in cold
blood, the tree regrows it, the new worker's `init` re-registers the name, and
`(reg/whereis :workers {:id 1})` points at the new pid. Every piece you read
about in isolation, doing its one job in one composition.

**The invariant (04)** runs *before any of it boots*:

```clojure
(sys/verify 'examples.bundles.00-all-five/app)   ; → :ok
```

The verifier climbs the tree: the worker's `done ≥ 0` is proven from source
(establish: init starts at 0; preserve: no modeled edge decrements). The buses
and registry carry no invariant, so they are *skipped*, not silently passed —
a tree of zero invariants never answers `:ok`.

## The vocabulary rule, kept

Look at what the program never contains: no `try`, no `catch`, no `if alive?`,
no retry loop, no pid bookkeeping. Each of those would have been a hand-rolled
echo of a pattern the bundle already embodies. The program is short because
the patterns are named — that was the thesis of
`docs/the-process-pattern-language.md`, and this file is its receipt.

## The honest footnotes

- The fence's crashed task prints an error report (job 13) — that line in the
  output *is* the fence working: the crash happened, was contained, became
  data.
- Pool worker ids must be unique per VM (each pool registers `<id>-sup`).
- `sys/verify` proves safety ("never a bad state"), not liveness ("replies
  eventually flow"). The lasso tooling for liveness exists in
  `system/core.bl`; wiring it into `verify` is future work.
- The registry is single-node; `where` is attribute-match, not datalog.

## Where next

The guidebook ends here. The pattern catalog —
`docs/the-process-pattern-language.md` — keeps the ledger of what is native,
what is a bundle, and what is honestly unbuilt. The build plan —
`docs/the-five-bundles.md` — shows the order it was all cut over in, each step
green before the next began.

If you read nothing else: chapter 01's one primitive (a process is a mailbox,
a pattern-matcher, and a loop) and this chapter's picture of five patterns
composed. Everything in between is instantiation.
