# 07 — The supervisor: a tree that heals

*Guidebook chapter 7. Reads after [02 — the verbs](02-the-verbs.bl.md) and
[03 — the fence](03-the-fence.bl.md). New to beam-lisp assumed.*

---

## The problem this solves

Chapter 03 taught you to *fend off* crashes at a boundary: the fence catches,
returns `{:crash reason}`, and the caller decides. But most processes are not
a boundary — they are the long-lived organs of the system, and "the caller
decides" is not a recovery plan for an organ. When a worker dies at 3 a.m.,
nobody calls it. Something has to *notice and regrow it*.

That something is the **supervisor**: a process with exactly one job —
watching children and restarting them by a declared policy. It is the Let It
Crash pattern made structural: you don't prevent the crash, you declare what
grows back.

## A tree, written as data

```clojure
(ns my-app (:require [super :as super]))

(super/defsupervisor shop
  (strategy :one-for-one)       ; a dead child regrows alone
  (intensity 3 5000)            ; 3 restarts in 5s, then the supervisor gives up
  (child :boss worker :boss)    ; id, the defserver, its init arg
  (child :hands (pool worker 3)))

(def s (start-link shop))
```

Three things to read:

1. **`strategy` — who regrows when one dies.** `:one-for-one`: just the dead
   one (siblings don't notice). `:one-for-all`: everyone (the children's
   states are entangled; heal them together). `:rest-for-one`: the dead one
   and everyone started after it (start order is a dependency order).
2. **`intensity` — the crash budget.** A child that dies faster than the
   budget is not flapping, it is *broken* — and a broken child should take the
   supervisor down with it rather than burn the machine in a restart loop.
   "Let it crash" ends here; above the budget, the crash is allowed to matter.
3. **`child` — what to grow.** A name you'll use later (`:boss`), the
   `defserver` to start, and its init arg. The child IS the gen_server — no
   wrapper, no proxy — so `super/child-of` gives you the real pid.

## The verbs

```clojure
(super/children s)      ; → [{:id :boss :pid #PID<…> :type :worker} …]
(super/child-of s :boss) ; → pid — reach a child by NAME, immune to restarts
(super/restart s :boss)  ; force a regrow
(super/terminate s :boss); remove a child from the tree
```

`child-of` is the one you'll use daily: it asks the *tree* for the current
pid, so a restarted child is transparently the "same" child. (For the general
case — finding processes by what they *are* — that's chapter 05's registry.)

## The pool: many identical hands

```clojure
(child :hands (pool worker 3))
```

A pool is `n` identical workers under their own little supervisor, fronted by
a **dispatcher**. Each worker gets its index (0, 1, 2) as its init arg. The
pool protocol:

```clojure
(def hands (super/child-of s :hands))   ; → the dispatcher's pid
(cast hands [:job 7])                    ; forwarded round-robin to a live worker
```

You cast once; the dispatcher picks the next worker. A dead worker's jobs wait
out its restart — at-least-once, no dead-letter office. (One rule: pool ids
must be unique per VM — the pool's sub-supervisor registers under
`<id>-sup`, and a duplicate name refuses to start rather than shadow.)

## Seeing it heal

Run `examples/supervisor.bl`. It kills the boss in cold blood:

```
== let it crash ==
  killed the boss; the tree grew a new one
```

`super/child-of` before and after returns *different pids* — the tree regrew
the organ and nobody who asked the tree noticed. Nobody holding the old pid
was so lucky: chapter 05's registry exists for them.

## The tree is verifiable

A supervisor has no state of its own to make promises about — but its
children do. Chapter 04's invariant check climbs the tree:

```clojure
(system/verify 'my-app/shop)
```

verifies every child's invariant from source and answers `:ok` only when every
child's promise holds. The tree is only as true as its leaves; the verifier
refuses to say otherwise.

## What a supervisor is NOT

- **Not a catch-all.** It restarts; it does not repair state. A child that
  crashes on its own corrupted data will crash again — the restart restores
  the *init* state, and the invariant (chapter 04) is what makes that safe.
- **Not a fence.** Errors crossing a *boundary you own* (user input, a
  network peer) belong to chapter 03. The supervisor is for your own organs.
- **Not optional.** An unsupervised gen_server is a process nobody regrows.
  If it matters, it belongs under a tree.

## Exercises

1. Change `shop`'s strategy to `:one-for-all`, kill the boss, and watch the
   pool's pids change too (check `super/children` before and after).
2. Set `(intensity 1 1000)` and kill the boss twice in one second. What
   happens to the supervisor — and to the script holding its pid?
3. Write a worker that crashes when it receives `[:job 13]`. Pool it with
   `n = 3`, send jobs 1–20, and count how many jobs each worker's *print*
   reports. Where did job 13 go? Where did the jobs after it go?

---

*Next: [08 — the capstone](08-the-capstone.bl.md): all five bundles, one
program.*
