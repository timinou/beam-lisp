# 05 — The registry: find a process by what it is

*Guidebook chapter 5. Reads after [02 — the verbs](02-the-verbs.bl.md). New to
beam-lisp assumed.*

---

## The problem this solves

Chapter 02 ended with a warning: a pid is an address, and addresses die. If a
supervisor restarts your `counter`, the healed process has a *new* pid, and
every var holding the old one points at a corpse. Any message sent there
disappears into a dead mailbox.

You already know the fix from the web: don't hand out addresses, hand out
*names*, and keep a phonebook from names to addresses. On the BEAM that
phonebook is a **registry** — a process whose entire state is the relation
"which pid is which thing." When the worker dies and is healed, it
re-registers; callers never notice.

## Making one

```clojure
(ns my-app (:require [reg :as reg]))

(reg/defregistry sessions (keys :user-id))

(def r (start sessions nil {:name :sessions}))
```

Three things to read here:

1. **`defregistry`** defines a registry. It is a `defserver` underneath — same
   clauses, same verbs — whose state is a pid ↔ attributes table.
2. **`(keys :user-id)`** declares what you may say about a process. Trying to
   register `{:oops 1}` is declined with `[:error {:unknown-keys (:oops)}]`.
3. **`{:name :sessions}`** gives the *registry itself* an OTP name, so you can
   find the phonebook without a pid either. (The registry is a process; it has
   the same problem; OTP names solve it for exactly this bootstrap case.)

## The four verbs

```clojure
(reg/register   r pid {:user-id 42})   ; → :ok   (and monitors pid)
(reg/whereis    r {:user-id 42})       ; → pid | nil
(reg/where      r {:user-id 42})       ; → [pid …]  (all matches)
(reg/unregister r pid)                 ; → :ok
```

A query is a partial attribute map: an entry matches when every key-value in
the query holds in its attributes. `whereis` is for "the one"; `where` is for
"all of them."

## Names are values

Once a registry runs under an OTP name, you never need its pid — and you never
need the *registered process's* pid either. Every verb from chapter 02 accepts
a name in pid position:

```clojure
(call [:sessions {:user-id 42}] :balance)
```

Read it: "call the process that registry `:sessions` knows as `{:user-id 42}`."
The lookup happens inside `call`, once. If the session process is healed
elsewhere and re-registers, this same call finds the new pid next time.

## Death cleans up after itself

The failure-mode question for any phonebook: what happens to an entry when its
process dies? Here the answer is structural, not janitorial: `register`
*monitors* the pid (chapter 01, Monitor pattern), the VM delivers a `:DOWN`
message to the registry when the process exits, and the registry's
`handle-info` retracts every entry for that pid. You cannot observe a stale
entry — between "process dead" and "entry gone" there is only message travel
time.

Try it in `examples/registry.bl`: register a worker, `kill` it, and
`reg/whereis` answers `nil` a few milliseconds later.

## What a registry is NOT (this slice)

- **Not multi-node.** This registry answers for this VM. A cluster-scoped one
  is a later chapter of a later book.
- **Not a query engine.** `where` is attribute matching, not datalog. When you
  need joins, the datom library (`priv/lib/datom`) is the tool — a registry
  over a datom conn is a one-screen change, deliberately not made in std.
- **Not a cache.** No TTLs, no eviction. An entry lives exactly as long as its
  process.

## Exercises

1. Register two workers under the same `{:team :red}` and different `:id`s;
   use `reg/where` to reach the team and `reg/whereis` to reach one.
2. What happens if you register the *same pid* twice under different attrs?
   Read `register-entry` in `priv/std/reg.bl` and predict, then test.
3. `(stop r)` the registry and then `(call [:sessions {:user-id 42}] :ping)`.
   What error do you get, and why is it *that* error? (Read `resolve` in
   `lib/beam_lisp/server.ex`.)

---

*Next: [06 — the bus](06-the-bus.bl.md): one stream, many readers, nobody
drowns.*
