# What is possible

A tour of what the verification tier can prove, in plain language, with runnable
examples. Every snippet below is a real, checked example — the demos live in
`examples/system/` and the per-feature reference pages in `docs/typing/`.

---

## Six things you can prove, each in a few lines

### 1. State can be any shape — enums and tagged variants

Write a connection's phase as keywords; the checker proves you can only send
while open, over a real algebraic datatype (no integer codes, no drift).

```clojure
(defserver ^{:invariant (or (not sending) (= phase :open))} conn
  (init [] (ok {:phase :idle :sending false}))
  (handle-call [:open]  [_ {:keys [phase]}] :when (= phase :idle)
    (reply :ok {:phase :open   :sending false}))
  (handle-call [:send]  [_ {:keys [phase]}] :when (= phase :open)
    (reply :ok {:phase :open   :sending true}))
  (handle-call [:close] [_ {:keys [phase]}] :when (= phase :open)
    (reply :ok {:phase :closed :sending false})))
;; □(sending ⇒ phase = :open) holds ✓   a :send from :closed is caught ✗
```

A variant can carry data, too — `:paused` or `{:on 7}` — and you read it with
ordinary map operations that both run and verify:

```clojure
(defserver ^{:invariant (or (not (some? (:on mode))) (>= (:on mode) 0))} dial
  (init [] (ok {:mode :paused}))
  (handle-call [:turn-on lvl] [_ {:keys [mode]}] :when (>= lvl 0)
    (reply :ok {:mode {:on lvl}}))
  (handle-call [:pause] [_ {:keys [mode]}]
    (reply :ok {:mode :paused})))
;; the same invariant evaluates as plain code AND is proven by z3
```

→ demos `13_protocol_state.bl`, `19_payload_variant.bl` · doc
`docs/typing/sum-types-are-shapes.bl.md`

### 2. The checker fixes your program, not just grades it

Give it a broken account — a `withdraw` with no balance guard — and it
synthesizes the guard that repairs it, then confirms the fix passes.

```clojure
;; broken: withdraw has no guard, balance can go negative
(defserver ^{:invariant (>= balance 0)} account
  (init [] (ok {:balance 100}))
  (handle-call [:withdraw amt] [_ {:keys [balance]}]
    (reply :ok {:balance (- balance amt)})))

(repair-process port node)
;; → {:holds false :repairs [{:label :withdraw :guard "(<= amt balance)"}]}
;; the WEAKEST sound guard — it rejects the degenerate (<= amt 0) that would
;; forbid the useful case. Splice it in and verify-process now holds.
```

→ demo `24_repair.bl` · doc `docs/typing/the-checker-runs-backwards.bl.md`

### 3. Content, not just count — what a collection holds

Prove a set never holds a duplicate — a fact about the *elements*, not the size.

```clojure
(defserver ^{:invariant true} uniqset
  (init [] (ok {:items []}))
  (handle-call [:add x] [_ {:keys [items]}] :when (not (includes? items x))
    (reply :ok {:items (conj items x)})))

(verify-content port node)   ; ⇒ :holds true   (no duplicates, ever)
;; remove the freshness guard and z3 finds the value that collides
```

→ demo `25_content_invariant.bl`

### 4. Eventually, not just never — liveness

Prove a job always finishes, and catch one that could spin forever.

```clojure
(defserver job
  (init [] (ok {:phase :pending}))
  (handle-call [:start]  [_ {:keys [phase]}] :when (= phase :pending)
    (reply :ok {:phase :running}))
  (handle-call [:finish] [_ {:keys [phase]}] :when (= phase :running)
    (reply :ok {:phase :done})))

(verify-liveness node "phase" #{"done"})   ; ⇒ :holds true (◇done)
;; a :retry that loops running→running fails — a starvation loop is caught
```

→ demo `26_liveness.bl`

### 5. Guarantees combine — questions across processes

Project every process's promises into one place and ask questions no single
check can — like *which message could break the receiver's invariant?*

```clojure
(def conn (knowledge [account ledger] client-sends mk-conn transact))
(invariant-bearing-guarded-sends (datom/db conn) q-fn)
;; → client → account :withdraw
;;      guard:    (>= balance amt)
;;      protects: (>= balance 0)   — violate the guard, break this
```

→ demo `23_composition.bl` · doc `docs/typing/guarantees-compose.bl.md`

### 6. Discover the promise — no annotation needed

Hand it a machine with no invariant written, and it finds one and proves it.

```clojure
(discover-invariant port node)     ; ⇒ discovers (>= balance 0)
(synthesize-capacity port node)    ; ⇒ discovers the tightest queue bound, or :unbounded
```

→ demos `14_discover_invariant.bl`, `22_synthesize_capacity.bl`

---

## The one idea underneath all of it

> **The state of your program already tells the checker everything it needs.**

The *type* of a value picks which solver theory proves things about it. The
*structure* of your dispatch picks which questions the database answers. The
checker is a *relationship*, so it runs forward to verify and backward to fix.
Verification is not a separate analyzer bolted on — it is a property of the
evaluator, and each capability is one more shape the system already understood.

The reference pages in `docs/typing/` each take one of these ideas from zero:
how a field picks its theory, why sum types are shapes, how guarantees compose,
how the checker runs backwards, and how one engine holds both fixpoints.

---

## From zero: what this is and what became possible

*The rest of this page is the plain-language overview, start to finish.*

### What this is, in plain language

Imagine you write a little program that manages something — a **bank account**, a
**network connection**, a **work queue**. It holds some state and changes it when
messages come in: deposit, withdraw, open, close, enqueue.

You'd like to be *sure* it never does something wrong: the balance never goes
negative, you never send on a closed connection, the queue never holds a
duplicate. Not "we tested it a few times" — **sure, for every possible sequence
of messages, forever.**

This project makes that certainty a built-in feature of the language. You write a
one-line promise on your program, and a bundled proof engine checks it —
mathematically, exhaustively — using logic solvers wired directly into the
runtime. No separate tools, no Java, no exporting to another language.

### What became possible

Six new powers, each proven with runnable examples and tests:

**1. Your data can be any shape.** It used to be that the state had to be a plain
whole number. Now a field can be a *choice* — `:idle` or `:open` or `:closed`, or
`{:on 7}` carrying a value — and you write it the natural way, no ceremony. The
checker reads the shapes right out of your code and proves promises about them.

**2. The checker can *fix* your program, not just grade it.** Point it at a broken
bank account — a `withdraw` with no balance check — and it doesn't just say "this
is wrong." It **synthesizes the missing guard** (`only withdraw up to the
balance`), picks the *most permissive* correct one, and confirms the fix passes.
The same machinery that proves a rule sufficient runs backwards to *invent* one.

**3. It reasons about *what's inside* a collection, not just how big it is.** It
can now prove a set never holds a duplicate — a fact about the actual elements —
where before it could only count them.

**4. It proves things *eventually* happen, not just that bad things *never* do.**
"This job always finishes." "This request always gets answered." A program that
could spin forever without finishing is caught. This is the missing half of what
serious verification tools promise.

**5. Separate guarantees now *combine*.** Each program's promises used to be
checked in isolation. Now they all live in one queryable place, so you can ask
questions that span *several* programs at once — "which message one process sends
could break another process's promise?" — which no single check could ever
answer. Every new guarantee you add multiplies with all the others.

**6. The proof engine now reasons in both directions at once.** The database
underneath could always answer "what can this reach?" (grow outward). Now it can
also answer "what's provably safe?" (shrink inward) — natively, with the same
speed tricks. Both halves of the reasoning live in one place, which sets up the
next prize: re-checking a proof *incrementally* when you edit code, instead of
from scratch.

### The single idea underneath all of it

> **The state of your program already tells the checker everything it needs.**

The type of a value picks which solver-theory proves things about it. The
structure of your dispatch picks which questions the database answers. The
checker is a *relationship*, so it runs forward to verify and backward to fix.
Nothing here is a bolted-on analyzer — verification is a property of the language
itself, and each capability is just "one more shape the system already
understood."

### The honest state of it

**Shipped, tested, demonstrated** — 702 tests passing, 27 worked examples, six
plain-language design docs. Everything above runs today.

**Genuinely still ahead** (and written down, not hidden): richer auto-repair
suggestions, a few more solver theories, and the deepest prize — making proofs
re-check *incrementally* as you edit, so verification becomes a live, always-on
property rather than a batch job. The foundation for that landed in this stretch;
the payoff is the next climb.
