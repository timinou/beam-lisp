# Intent outcomes: committed, noop, denied, refused

A live socket has exactly one write seam: `live.socket/perform-intent`. A view
only *names* an intent (`[:intent op payload]`); the socket authorizes it, runs
the performer registered under `op`, and reports what actually happened. This
document is the contract for that report — the outcome a view renders, the
messages a client receives, and the failure modes a performer or a
transaction-function may signal.

The rule behind all of it: **a view must never say "saved" before the socket
knows it was**. The socket is the only party that knows whether an intent
wrote, validated-and-declined, or was refused — so it records the verdict in
locals under `:live/outcome` and the view renders feedback *from* it.

## 1. The performer contract

A performer is the fn registered in a socket's `:intents` map:

```
(fn [shared-conn payload principal] -> tx-data | nil | {:refused why})
```

Given one gesture, it may:

| returns | meaning |
|---|---|
| `tx-data` (non-nil) | commit this to the shared world |
| `nil` | **no-op**: validated and deliberately declined; nothing writes |
| `{:refused why}` | **refusal**: the domain says no, in `why` (a string) |

`perform-intent` runs this function *after* authorization and never on a client
payload it was not authorized for. The performer is trusted server code; the
payload is only data.

A writer-run transaction function may additionally abort from **inside** the
store writer (see §3).

## 2. `perform-intent`'s exact result contract

`perform-intent` returns one of four maps. This is the contract project
consumers (and `handle-event`) code against:

| result | when | writes? | terminal? |
|---|---|---|---|
| `{:ok state :committed true}` | performer returned a tx and `datom/transact!` returned a report | yes | n/a |
| `{:ok state :committed false}` | performer returned `nil`, or a `:db/fn` aborted with `{:status :noop}` | no | yes (noop) |
| `{:denied why}` | authorization denied, or no performer registered for `op` | no | no |
| `{:denied why :terminal true}` | performer returned `{:refused why}`, or a `:db/fn` aborted with `{:status :refused :why s}` | no | yes |

`committed` is derived from the **actual outcome**, never from the input: a
`tx-data` vector that is non-nil but whose `:db/fn` aborts throws out of
`datom/transact!`, so it can never be reported as committed. Nil semantics are
unchanged — a nil tx is a no-op and no transaction is attempted.

**Exceptions.** Only well-formed outcome markers (§3) are converted. Any other
exception — an ordinary bug, a `:db/guard` refusal, a malformed marker — is
re-raised unchanged, exactly as before this seam existed. The socket does not
swallow bugs.

## 3. The writer abort marker

A `[:db/fn f …]` runs inside the connection's serialized writer, before any
datom or transaction metadata is realized. Throwing an `ex-info` there aborts
the whole transaction atomically — nothing commits, no sibling op writes, no tx
id is allocated. The marker rides in the exception's data:

```clojure
(throw (ex-info "refus d'écriture"
                {:intent/outcome {:status :refused :why "version périmée"}}))

(throw (ex-info "déjà appliqué"
                {:intent/outcome {:status :noop}}))
```

A marker is **well-formed** iff `ex-data` carries `:intent/outcome` as a map
whose `:status` is

- `:refused` **and** `:why` is a string, or
- `:noop`.

Everything else is not a marker and propagates. Markers are **server-created**:
a trusted performer or a registered `:db/fn`. A raw client payload is never
read as a marker, so a client cannot forge an outcome by shaping its intent
data.

`perform-intent` catches around **both** the performer call and the
transaction, so a trusted performer may refuse either by returning
`{:refused why}` (the ordinary shape) or by throwing the marker (when the
decision is only known inside the writer, e.g. after a read).

## 4. `:live/outcome` — what the view reads

After every intent the socket writes, under `get-in state [:locals :live/outcome]`:

```clojure
{:op op :status :committed | :noop | :denied :seq n :why "…"}
```

- `:seq` is monotone per socket, so a view can key a toast on it and two
  identical outcomes in a row still read as two events.
- `:why` is present for `:denied`.
- The outcome is cleared by the **next gesture** from this viewer.

**A refusal is reported with status `:denied`.** No distinct `:refused` status
was invented: `:denied` is already produced end-to-end (locals status, the
`[:denied why]` wire message, every existing view that renders feedback), and
the atomic-abort marker's `:refused` is the *internal* marker vocabulary, not a
new client-visible state. Reusing `:denied` means every existing screen shows a
refusal correctly with zero changes; the `:why` string carries the distinction
where it belongs (the message), not in a status enum the client would have to
learn.

## 5. The wire, and durable replay

Three messages leave the socket to its sink. There is **no new opcode**:

| frame | when |
|---|---|
| `[:denied why]` | an intent was denied or refused (auth, unregistered op, performer `{:refused}`, writer marker `:refused`) |
| `[:ack key]` | a gesture carrying `:ev/id` reached a **terminal** outcome: committed, noop, or refusal |
| `[:patch ops]` | this viewer's projection re-rendered (denials and noops re-render here; a commit re-renders every viewer through the log) |

### Terminality

The offline outbox replays a queued gesture until it is ACKed. A gesture that
can never land must be ACKed or it replays forever. The classification:

- **noop** — terminal: the performer declined, or a `:db/fn` no-oped; a retry
  will decline again. ACKed.
- **refusal** (`{:refused}` / writer `:refused`) — terminal: the domain
  refused; a retry will refuse again. ACKed.
- **auth denial** — *not* terminal: a re-authorized replay (refreshed token,
  changed policy) may succeed, so it is **never** ACKed. This is why a denial
  and a refusal share the `:denied` status but not the ACK.
- **committed** — terminal, and ACKed as before.

The ACK is opt-in on `:ev/id`; a gesture without one sends no `[:ack]`, so
every existing app is unaffected.

### The fold

`[:intent …]` may be the first term of a vector of events (`[[:intent …]
[:assign :flash "saved"] [:navigate "/away"]]`). The fold stops after any
intent that did **not** write — a denial, a refusal, or a noop — because
whatever follows was conditional on the write. Put the intent first when the
rest should run only on a commit.

## 6. Worked shapes

A performer that refuses in-band:

```clojure
(s/deflive order-socket
  :view order
  :intents {:confirm (fn [conn payload principal]
                       (if (locked? conn payload)
                         {:refused "commande verrouillée"}
                         (build-confirm-tx payload)))})
```

A tx that refuses atomically after a read (the read and the decision are one
writer-run step, so no validation-to-write race):

```clojure
(defn confirm-fn [db order-id]
  (let [state (datom.db/attr-value db order-id :order/state)]
    (if (= :locked state)
      (throw (ex-info "version périmée"
                      {:intent/outcome {:status :refused
                                        :why "commande verrouillée"}}))
      [[:db/add order-id :order/state :confirmed]])))

(defn confirm-tx [_ payload _]
  [[:db/fn confirm-fn (:order/id payload)]])
```

A no-op — idempotent already-applied gesture, nothing to write, client should
stop replaying it:

```clojure
(defn apply-once-fn [db ev-id]
  (if (already-applied? db ev-id)
    (throw (ex-info "déjà appliqué"
                    {:intent/outcome {:status :noop}}))
    [[:db/add -1 :ev/id ev-id]]))
```

## 7. Non-goals / rejected alternatives

- **No new transaction engine, lock, or scheduler.** The atomicity comes from
  `:db/fn` running inside the existing serialized store writer; the abort is a
  throw *before* any datom or tx metadata is written. `datom/with-writer`
  already serializes concurrent callers; nothing here changes that.
- **No distinct `:refused` status or wire opcode.** It is not supported
  end-to-end today, and inventing one would fork the client-visible vocabulary
  for no gain. Refusal is a denial with a reason.
- **Auth is not weakened.** Authorization still runs before the performer, and
  auth denials are neither terminal nor ACKed. The marker path never accepts a
  client payload as an outcome.
- **Unrelated exceptions are not swallowed.** Only the two well-formed marker
  shapes convert; everything else re-raises.
