# 02 — The verbs: how you talk to a process

*Guidebook chapter 2. Reads after [01 — the primitive](01-the-primitive.bl.md).
New to beam-lisp assumed.*

---

## The problem this solves

In chapter 01 every interaction with a process was "send a message, maybe wait
for an answer." If each *kind* of process came with its own vocabulary —
`server-call` for servers, `bus-call` for buses, `worker-call` for workers —
you would learn five names for one idea. The BEAM itself doesn't work that
way: `gen_server:call` works on **any** gen_server, whatever it does. So
beam-lisp claims the bare verbs at top level.

There are five:

```clojure
(start     counter 10)   ; start a process, get its pid
(start-link counter 10)   ; the same, but linked: if it dies, you die
(call      c :get)        ; Ask: send a message, wait for the reply
(cast      c :reset)      ; Tell: send a message, don't wait
(stop      c)             ; shut it down cleanly
```

Plus three raw ones, named for exactly what they do:

```clojure
(monitor c)   ; → a ref; you get [:DOWN ref :process pid reason] when c dies
(link c)      ; two-way: its crash becomes your crash
(kill c)      ; untrappable exit — the process cannot refuse
```

That's tier 1 of the verb table (`docs/the-five-bundles.md` §0). It is the
*whole* tier: these verbs work on every process you will ever start — a
server, a registry, a bus, a supervisor, a raw spawn — because they only
assume "is a process."

## Ask and Tell

The two message verbs deserve their names learned by heart:

- **`call` is Ask.** Your process sends the message and *blocks* in its
  mailbox until the reply arrives. It feels like a function call because it
  is one — the callee just happens to be another process. `(call c :get)` →
  the current value. An optional timeout: `(call c :heavy 1000)` waits at
  most a second, then raises.
- **`cast` is Tell.** Send and move on. No reply exists, so nothing to wait
  for. `(cast c :reset)` → `:ok` immediately.

The rule of thumb: `call` when you need the answer, `cast` when you don't.
Everything else (correlation tags, timeouts, mailbox skipping) is machinery
the runtime handles so these two stay this small.

## A pid is an address, not a name

`start-link` returns a **pid** — the process's address. Hold it in a `def`,
pass it to `call`. A pid is like a pointer: precise, but meaningless to a
human and *invalid after a restart*. If a supervisor heals your counter, the
new process has a new pid and everyone holding the old one is talking to the
dead. Chapter 05 (the registry) fixes that with names-as-values; until then,
hold pids in vars and pass them down.

## start vs start-link

`(start …)` starts the process; its life is its own. `(start-link …)` starts
it *linked to you*: if it crashes, you crash. That sounds strictly worse until
you meet the supervisor (chapter 07): a supervisor start-links its children
precisely *because* it wants to know — and it traps the exit, so instead of
dying it gets a message, and heals. **Inside a supervision tree, always
`start-link`.** Standalone in a script, either works; the examples use
`start-link` so the habit is the right one.

## stop

`(stop c)` asks the process to terminate cleanly: OTP runs its `terminate`
callback, then it's gone. `(stop c :brutal 1000)` passes a reason and a
timeout. For the untrappable version there is `kill` — reach for it only when
a process is wedged; `stop` is the polite default.

## A complete tour

```clojure
(ns demo)

(defserver counter
  (init [start] (ok start))
  (handle-call :inc [_from state] (reply (inc state) (inc state)))
  (handle-call :get [_from state] (reply state state))
  (handle-cast :reset [_state] (noreply 0)))

(def c (start-link counter 10))   ; start, linked
(call c :get)                     ; → 10   (Ask)
(call c :inc)                     ; → 11
(cast c :reset)                   ; Tell — no reply
(call c :get)                     ; → 0
(stop c)                          ; clean shutdown
```

Run it: `mix beam_lisp.run examples/server.bl` — this *is* that file.

## What changed under you (if you knew the old names)

These verbs used to be prefixed — `server-start-link`, `server-call`,
`server-cast`, `server-stop` — because claiming `call` in the core namespace
felt too bold. The four-tier design (`docs/the-five-bundles.md` §0) reversed
that: on the BEAM these verbs *are* generic, so the prefix was a lie about
scope. The old names are gone, not deprecated. One exception to bareness:
inside a `defserver` body, `stop` is the *return constructor* (`(stop reason
state)` → "terminate with this reason") — it's bound as a local there and
shadows the verb. You never confuse them: one appears as a callback's return
value, the other is called on a pid from outside.

## Exercises

1. Add a `(handle-call :dec …)` clause to the counter and drive it with
   `call`.
2. Replace `(stop c)` with `(kill c)` and observe the difference in the
   printed output of `sys/get_state` — what breaks, and why?
3. Start two counters, `monitor` both, `stop` one, `kill` the other, and
   read the two `:DOWN` messages from your mailbox with `receive`. What
   differs in the `reason` slot?

---

*Next: [03 — the fence](03-the-fence.bl.md): running code you don't trust
inside a process that may die for you.*
