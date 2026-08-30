# The environment, and how it travels across processes

This document explains one idea in beam-lisp from the ground up, assuming you
know nothing about the language: **what "the environment" is, why every running
piece of code needs one, and what happens to it when your program starts a new
process.** It ends with a change we made — an environment-conveying `spawn` — and
uses it to draw a line between the general rule and the specific case.

No prior context is required. Where a term is beam-lisp–specific it is defined
the first time it appears.

---

## 1. Start from a question: where does a name's meaning live?

Write this in most languages and it "just works":

```clojure
(defn greet [who] (str "hello, " who))
(greet "ada")            ; => "hello, ada"
```

But step back and ask a genuinely hard question: when the machine runs
`(greet "ada")`, **how does it know what `greet` means?** The text `greet` is
five letters. Somewhere there must be a table that says *the name `greet` maps to
this particular function*. Running code is always running *somewhere that knows
what its names mean.*

That "somewhere" is what we call the **environment**. You can think of it as the
world a piece of code is standing in:

- which **namespace** it is running in (a namespace is just a named drawer that
  holds definitions — `greet` lives in one),
- what **variables** are defined and what they point to,
- what the code is **allowed to do** — its *capabilities* (may it read files?
  reach the network?),
- and a couple of housekeeping limits (how much memory a runaway computation may
  use before it is stopped).

Every name your code mentions — every `defn`, every `def`, every call to another
function — is resolved *against the environment the code is running in.* Change
the environment, and the same text can mean different things, or mean nothing at
all.

---

## 2. Why an environment is a *value*, not a global fact

The naïve design is one big global table: all definitions in one place, visible
everywhere. beam-lisp deliberately does **not** stop there. It lets you create a
**fork** of the environment: a child world that starts as a copy of its parent
but whose changes stay local to it.

```
:global                     ← the shared, default world
  └── fork A                ← its own drawer of definitions; edits don't leak up
        └── fork A.1        ← a fork of a fork; even more contained
```

Why bother? Because "run this code in its own world, and throw the world away
afterwards" is the cleanest possible form of isolation:

- A **test** can define, redefine, and mangle namespaces inside its own fork.
  When the fork is destroyed, none of that touched the shared image. The next
  test starts clean — not because the test remembered to clean up, but because
  *there was nothing shared to dirty.*
- A **sandbox** can run untrusted code in a fork whose capabilities are narrowed
  (say, "may use `String`, may not touch `File`"). The code physically cannot do
  what its world does not permit.

So an environment is a first-class thing you can make, narrow, run inside, and
discard. That capability is the backbone of testing and sandboxing in the
language. Hold onto this: **isolation is achieved by running code in a fork and
destroying the fork afterward.**

---

## 3. Where the environment actually lives: the process

Here is the mechanical fact that everything below depends on.

beam-lisp runs on the BEAM (the Erlang virtual machine). The BEAM's unit of
concurrency is the **process** — extremely lightweight, isolated, and
communicating only by sending each other messages. A beam-lisp program is always
running inside some BEAM process.

Each process has a small private scratchpad called its **process dictionary**.
beam-lisp stores "which environment am I in" *there* — a handful of entries in
the current process's dictionary record its namespace, its capabilities, its
place in the fork chain, and its memory limit:

| what it records        | why it matters                                    |
|------------------------|---------------------------------------------------|
| current environment id | which fork's definitions this code resolves against |
| fork chain             | the ancestry, so a lookup can fall back to parents |
| current namespace      | the drawer new definitions land in                 |
| capabilities           | what host modules this code may call               |
| memory limit           | the ceiling a bounded computation may not exceed   |

This choice is efficient and correct — **within one process.** A function
resolving `greet` reads its own process dictionary, finds the environment, and
looks `greet` up there. Fast, local, no coordination.

But it plants a subtlety that is the whole point of this document:

> **The environment lives in the process dictionary, and a process dictionary
> does not travel to a new process.**

When a BEAM process starts another process, the child begins with an **empty**
dictionary. It did not inherit the parent's notes about which world it was in.

---

## 4. The trap: a child process in the wrong world

Now combine the two facts:

1. Isolation works by running code in a **fork** (§2).
2. A newly started process begins with an **empty** environment, which defaults
   to `:global` (§3).

Put them together and you get a trap. Suppose a test runs inside fork `A`, and
its code starts a helper process to do some work:

```clojure
;; running inside fork A
(defn worker [reply-to] (erlang/send reply-to :done))   ; defined in fork A
(def parent (erlang/self))
(erlang/spawn (fn [] (worker parent)))                  ; start a helper process
(receive :done :ok)                                     ; wait for it
```

`erlang/spawn` is the raw, low-level "start a process" primitive. The helper it
starts has an **empty** dictionary, so it is standing in `:global` — **not** in
fork `A`. It tries to call `worker`. But `worker` was defined in fork `A`, and
this child is looking in `:global`, where `worker` does not exist.

The child crashes with `undefined var: worker`. It never sends `:done`. The
parent's `(receive :done …)` waits for a message that will never come — **forever.**

This is not a hypothetical. It is exactly why, before the change described below,
a whole class of example programs — anything that spawned a worker and waited for
it — would **hang** the moment they were run inside an isolated environment
instead of the shared global one. The examples were correct; the isolation was
correct; but the child process was silently left in the wrong world.

---

## 5. The fix, and the principle behind it: conveyance

The principle is borrowed from Clojure, and it has a name: **binding
conveyance.** In Clojure, when you start a `future`, the new thread inherits the
dynamic bindings of the thread that started it — the child works in the same
context as its parent. The intuition is simple and should feel obviously right:

> **A process you start to do your work should run in *your* world, not in some
> unrelated default world.**

beam-lisp already applied this principle to two of its concurrency primitives.
`future` (run this and let me ask for the answer later) and `promise` (a slot a
result will arrive in) both **carry the parent's environment into the child.**
The mechanism is two small operations:

- **capture** — take a snapshot of the current process's environment (all the
  entries from the table in §3): "here is the world I am standing in."
- **bind** — in another process, install that snapshot before running: "stand in
  this world now."

A conveying primitive is just: *capture in the parent, then, as the very first
thing the child does, bind.* After that the child resolves its names in the
parent's world, sees the same definitions, and carries the same capabilities.

The gap was that the **raw** `erlang/spawn` did none of this — by design, it is
the unadorned BEAM primitive. What was missing was a beam-lisp `spawn` that
applies conveyance the same way `future` and `promise` already do.

### What we added

A first-class `spawn` (and its `spawn-link` / `spawn-monitor` siblings, which
mirror the standard "start a process, and also link/monitor it" variants):

```clojure
;; the same program as §4, but conveying:
(defn worker [reply-to] (erlang/send reply-to :done))
(def parent (erlang/self))
(spawn (fn [] (worker parent)))     ; child inherits THIS world
(receive :done :ok)                 ; :done arrives — no hang
```

`spawn` captures the caller's environment and binds it in the child before the
child's body runs. Now the child stands in the same fork as its parent, finds
`worker`, sends `:done`, and the program completes.

The proof is a clean A/B: the *same* worker program, run inside an isolated
fork —

| primitive             | child's world | result                       |
|-----------------------|---------------|------------------------------|
| `erlang/spawn` (raw)  | `:global`     | `undefined var` → **hangs**  |
| `spawn` (conveying)   | parent's fork | resolves → **completes**     |

Nothing about the harness changed. The fix is a **language-semantics** fix: the
language's own `spawn` now behaves the way a reader would already assume it does.

---

## 6. The general and the specific

It is worth being precise about which part of this is a deep principle and which
part is a local consequence, because they are easy to conflate.

### The general principle

**A process should run in the world of whoever started it.** Concurrency should
be *environment-transparent*: starting a process to help you must not silently
change which definitions are in scope or which capabilities you hold. This is not
a beam-lisp quirk — it is the same reason Clojure conveys bindings across a
`future`, and the reason a well-designed system never lets "I ran this on another
thread" quietly change the meaning of the code. Once you accept isolation as a
value you can fork (§2), environment-transparent concurrency is *forced*: without
it, the two features contradict each other — you cannot both isolate work and
freely parallelize it.

The general rule, then, is uniformity: **every** process-creating primitive in
the language — `future`, `promise`, and now `spawn` — conveys the environment. A
reader learns the rule once and it holds everywhere. One need ("run this
elsewhere, in my world"), one implementation.

### The specific case, and its honest edge

The specific case is the raw `erlang/spawn` escape hatch. It exists on purpose
and it deliberately does **not** convey — it is the unmodified BEAM primitive,
for the rare code that genuinely wants a child in the bare `:global` world with
no inherited authority. Two of our own examples rely on exactly that: a security
demonstration of a "confused deputy" *needs* the naïve, non-conveying spawn to
show the vulnerability it is teaching. Conveyance is the default you reach for;
raw `erlang/spawn` is the sharp tool you reach for knowingly.

There is also a genuine boundary where even conveyance cannot save you, and
honesty requires naming it. Conveyance hands the child a **snapshot** of the
parent's world. If the parent's world is an isolated fork that gets **destroyed**
while the child is still running — the child *outlives its own environment* —
then the snapshot points at a world that no longer exists, and the child's later
name lookups fail. This is not a bug in conveyance; it is a true statement about
lifetimes: **a process may not outlive the environment it was given, if that
environment is a temporary fork.** A long-lived worker belongs either at
`:global` (a durable world) or under something that keeps its world alive for as
long as the worker runs. The general rule (convey the world) and this specific
limit (do not outlive the world you were conveyed) are two sides of the same
coin: an environment is a real thing with a real lifetime, not an ambient fact
that is simply always there.

---

## 7. One-paragraph summary

Running code always resolves its names against an **environment** — its
namespace, definitions, and permissions — and that environment is stored in the
current BEAM **process's** private scratchpad. Because a new process starts with
an empty scratchpad, a naïvely spawned child lands in the default `:global`
world, not the fork its parent was running in — so code that isolates itself and
then spawns a helper would find the helper unable to see the parent's
definitions, and hang. The fix is **conveyance**: capture the parent's
environment and bind it in the child first, exactly as `future` and `promise`
already did. We gave the language a first-class conveying `spawn`, so every way
of starting a process now runs it in the starter's world. The raw `erlang/spawn`
remains as a deliberate, non-conveying escape hatch, and the one true limit
stands: a process must not outlive the temporary environment it was handed.
