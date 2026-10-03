# 03 — Boundaries: ETS, ports and distribution

> **Current status: local `:set` tables implemented; ports/distribution remain research.**
> BL `runtime.bl` owns table identity, permission modes and owner/heir transfer;
> opaque host storage provides bounded mutable rows. `verify-tables.mjs`
> compares 25 selected BEAM rules, not full ETS compatibility. The ETS
> "prototype today" table below is a historical pre-cutover baseline. Access
> modes govern trusted BL verbs, **not hostile BL source** (raw leaves and
> `host/state` remain callable). Consult [FEATURES.md](FEATURES.md) and the
> [actor README](../js-actors/README.md) for current subset and caveats.
>
> Three topics repeat the research template; §5 records their original wave order.

---

## 1. Scope, and one naming collision

This doc covers the three places where the actor world meets something that is
**not an actor**:

1. **ETS** — shared mutable state that outlives a process.
2. **Ports** — the boundary to the outside world.
3. **Distribution** — the boundary between runtimes/nodes.

> **Naming collision, flagged before it bites.** In Erlang/OTP, a **port** is a
> process-like handle to an external OS process or driver — `erlang:open_port/2`,
> byte messages, linkable. In *this repo*, `priv/std/vm/ports.bl` is something
> else entirely: a **file-backed registry of TCP listener claims** (`:web 4000`,
> `:metrics {:port 0}`) for a tree's warm session. The two share a word and
> nothing else. Any future design must name them apart, or it will repeat the
> mistake `priv/std/proc.bl` exists to prevent ("two answers to one question is
> the state this move exists to end"). §3 covers both, separately.

### State of the worktree at time of writing

At this document's first writing, `dbdead74` passed 104 checks and FEAT-046
provided the browser inbox. The current suite passes 457 checks in Node and a
Worker; local `:set` table owner/heir behavior, names and supervision now exist.
The browser inbox remains a narrow validated string transport, **not** BEAM
`open_port` or a generalized capability. §3.4 still distinguishes it from
missing per-source identity, close, fetch/WebSocket and backpressure; do not
build a second inbox.

---

## 2. ETS — state that outlives a process

### 2.1 BEAM/OTP contract

- An ETS table is **owned by the process that created it** and is **destroyed
  when that owner dies**. This is a design choice, not an accident: a process's
  tables are part of its memory.
- Ownership can be **transferred on death**: `:ets.new` takes `{:heir, Pid, Data}`;
  on owner death the table is not destroyed but transferred, and the heir
  receives `[:"ETS-TRANSFER", Tid, From, Data]`. The heir hands it on with
  `:ets.give_away/3`.
- A **named table** (`:named_table`) is uniquely addressable by atom across the
  VM; an anonymous table is addressed by a `tid` that only holders know.
- **Types:** `set`, `ordered_set`, `bag`, `duplicate_bag`. **Access:**
  `:public` / `:protected` / `:private`.
- **Atomic operations:** `:ets.update_counter/4` is an atomic read-modify-write.
  Reads do not block writers (`:public`), and `read_concurrency` /
  `write_concurrency` tune that.
- A table is **not a value**. `tab2list`, `select`, `foldl` are snapshots or
  traversals, not transactions; there is no consistency across tables.
- `select`/`foldl` hold the table for the duration of the traversal and can
  block other operations.
- Table memory counts against the owner; a large table makes the owner large.

### 2.2 Prototype today

| capability | status | evidence |
|---|---|---|
| any ETS / table primitive | ✗ | no `ets` entry in `host.mjs::ERLANG`; no `erlang/apply` bridge |
| canonical key equality (the hard half) | ✅ | `host.mjs::hashKey` is injective and length-prefixed, so distinct values never share a key |
| maps as values | ✅ | `BMap`, `mapGet`/`mapPut`/`mapRemove`/`mapKeys` |
| process death to trigger a transfer | ✗ | `01` |
| an owner concept | ✗ | nothing ties an object to a pid |

**Measured constraint (important).** `host.mjs::mapPut` and `mapRemove` copy the
**entire underlying JavaScript `Map`** (`new Map(m.m)`) on every write. A BL map
is therefore a *persistent value with O(n) updates*, not a shared mutable table.
Consequently:

> **ETS cannot be "a BL map in the runtime root" if writes must be O(1).**
> Either the table lives as a plain `Map` held by reference in host state
> (mutable, aliased — a new host primitive), or it is a BL map with an explicit
> small-capacity limit, or the runtime grows a copy-on-write structure. This is
> ○ in §2.8 and is the single biggest architectural decision in this topic.

### 2.3 Missing invariants

- **I3.1 — Owner death disposes.** When an owner dies, each table it owns is
  either destroyed or transferred to its heir — never left owned by a dead pid.
- **I3.2 — Transfer is atomic with death (C1).** No observer can see a table
  owned by a pid that has already been removed from `:procs`.
- **I3.3 — Named uniqueness is loud.** A second table with the same name fails
  with a named error; never a silent second table.
- **I3.4 — Atomic counter.** `update-counter` is atomic with respect to other
  table operations (free if all table ops run inside one critical section).
- **I3.5 — A table is not a value.** A read of a table is a snapshot with no
  transaction semantics, and the API does not pretend otherwise.
- **I3.6 — The heir's filing key comes from the transfer.** The heir files what
  it receives by the block it was handed at creation, not by `:ets.info(tid,
  :name)` — which answers `:undefined` for anonymous tables, exactly the kind
  `datom/store-ets` makes (`docs/the-process-pattern-language.md` §3.6;
  `priv/std/proc/table.bl`).

### 2.4 Repo BL side

`priv/std/proc/table.bl` is the repo's whole ETS contract, and it is *verified on
BEAM today* (pattern-language §6 ledger: ✅ Heir, first user `proc/sched`'s
store). Reuse it as the target's spec:

| repo guarantee | why it must survive |
|---|---|
| **one creator** — `:ets.new` appears in `table-keeper`'s init and nowhere else | a "create it if missing" fallback *is* the bug the file exists to prevent |
| **an heir at creation** — no window in which the table exists unheired | a crash between create and heir loses the table |
| **checked acquisition** — `hold` does not return until *this* keeper owns it; a window still open is an error | the heir holding the table is a designed state, but acquisition ends that window |
| **quoted `:"ETS-TRANSFER"`** | unquoted it parses as `:ETS - TRANSFER`, compiles, and never matches |
| **two absence vocabularies** — `:undefined` (ETS) vs `nil` (`Process.whereis`) | comparing the wrong one is silent and always takes the wrong branch |
| **`give_away` may answer `:nothing`** | "I do not hold that" is a state to report, not a table to invent |

Its one stated limit is also the target's: *"The table is still IN MEMORY. The
heir survives a PROCESS crash; nothing here survives the VM."*

⚙ **Repo gap worth filing with this:** the pattern is proven but not
*verifiable* — nothing checks "every held table has a live keeper" as an
invariant, and the failure mode is silence (the table is alive and unprotected).

### 2.5 Design constraints derived from the prototype

- **Ownership needs `01`'s atomic death.** I3.1/I3.2 are the same transaction as
  link/monitor delivery (C1). Implementing ETS first would force a second death
  path — C6 violation.
- **`hashKey` already answers key equality.** ETS key semantics (`set` vs
  `ordered_set` vs `bag`) sit on top of it; `ordered_set` additionally needs a
  total order, which `host.mjs::lt` provides only for numbers and strings, so an
  ordered table with structural keys is ○.
- **Atomicity is currently free, and that is fragile.** The runtime is
  single-threaded and critical sections already defer slice boundaries, so any
  table op inside one critical section is atomic by construction. If the target
  ever gains Workers with `SharedArrayBuffer` (see §4), that stops being true and
  I3.4 becomes a real lock.
- **A table op is a state update.** If tables live in the runtime root, every
  op is a read-modify-write of `rt.state` and must use the existing
  `critical-enter`/`critical-leave` discipline.
- **Memory pressure is invisible today.** Nothing bounds `:procs` or a table;
  the browser analogue of "the owner is huge" is a tab the OS reclaims.

### 2.6 Risk

| risk | consequence |
|---|---|
| table as a BL map in the runtime root | O(n) per write (`mapPut` copies) — a "cache" that is slower than recomputation, and quadratic when written in a loop |
| owner death implemented after the fact | a table owned by a dead pid; reads keep working, so the bug is silent |
| heir filed by table *name* | anonymous tables (the datom store) are unheirable — precisely the tables whose names were never written down |
| acquisition not checked | a table alive but unprotected; symptoms arrive later and elsewhere ("a one-shot that ran twice") |
| `update_counter` implemented as read-then-write across a slice boundary | lost updates under the 17-step budget only |

### 2.7 Gates

| # | check | invariant |
|---|---|---|
| 1 | create a table, kill its owner → table gone | I3.1 |
| 2 | create with an heir, kill the owner → heir receives the transfer; a new owner reclaims the *same* table (rows intact) | I3.1, I3.2 |
| 3 | two creates with one name → named error, first intact | I3.3 |
| 4 | 100 concurrent `update-counter`s → exact total | I3.4 |
| 5 | a table written inside a loop at budget 17 → no lost writes, no O(n²) blowup beyond a stated bound | I3.4, §2.5 |
| 6 | a snapshot read mid-write sees a consistent prefix (or the API says it does not) | I3.5 |
| 7 | G-diff: the `proc/table` owner/heir scenario from `priv/std/proc/table.bl` runs on both targets with the same reclaim result | — |

### 2.8 Unresolved options (○)

1. **Representation.** Plain `Map` held by reference in host state (mutable,
   O(1), aliased — a new host primitive), BL map in the root (pure, O(n)),
   or a copy-on-write structure. This decides whether "one mutable root" stays
   literally true.
2. **Ordered tables.** Is `ordered_set` in scope, and against what total order
   (`hashKey` has none)?
3. **Persistence.** Memory-only (the repo's own limit) versus IndexedDB/OPFS.
   A browser tab reload is the analogue of a VM restart; if that must survive,
   it is a separate, much larger design.
4. **Named-table registry.** Reuse W2a's name table, or a distinct table-name
   namespace (BEAM keeps them separate)?
5. **Concurrency modes.** `:public`/`:protected`/`:private` are meaningful only
   once there is real parallelism; ship one mode until §4 forces otherwise?
6. **Ownership of the heir.** Is the heir one long-lived process (the repo's
   choice: "one long-lived process is a better guarantee than N that could each
   die"), or per-table?

---

## 3. Ports — the boundary to the outside world

### 3.1 BEAM/OTP contract (ports as `open_port`)

- A **port** is the VM's handle to an external OS process or a driver. It is a
  process-like value: it can be **linked and monitored**, and its termination is
  an exit signal (C2 ordering applies to its messages).
- Data crosses as **bytes** in both directions: `Port ! {Pid, {command, Data}}`
  out; `{Port, {data, Data}}` in; `{Port, closed}` / `{Port, exit_status, S}` on
  the way out.
- `open_port({spawn, Cmd}, Opts)` with `binary`, `packet`, `exit_status`, etc.
- **A port must never block the VM.** Data in is delivered as messages to the
  owner; the OS process runs outside.
- A NIF is *not* a port — it runs in the VM, on a scheduler thread, and is a
  different (and more dangerous) boundary.
- Port identity, ownership and the close edge are the three things consumers
  actually depend on.

### 3.2 This repo's "ports" are a different thing

`priv/std/vm/ports.bl` is a **TCP listener claim registry**, not a BEAM port
layer. It is worth reading for this design all the same, because it is the
repo's existing answer to a *cross-VM coordination* problem — see §4.4.

- Claims live as **one file each** under the runtime dir, because "a GenServer
  per daemon cannot answer the one question that matters: the collision this
  catches is BETWEEN daemons, and one VM's table cannot see another's."
- **Pinned vs ephemeral** keys: a pinned port is a promise about a *number* (key
  = name alone); an ephemeral port is a session's own address (key = name@tree).
- **Liveness by OS pid**, `/proc`-based where available; where it is not, "a
  claim is RESPECTED, not swept — refusing a port is recoverable, stealing one
  is not."
- **Shape-checked decode, not `[:safe]`**: `binary_to_term(bin, [:safe])` throws
  on an unknown atom and a thrown read silently empties the registry.
- Atomic write: `term_to_binary` → 0600 tmp → rename.

Read it as a precedent for cross-runtime coordination (files as truth), not as a
port implementation.

### 3.3 The browser transport substrate: the host-event inbox (`FEAT-046`)

In a browser, the "external OS process" is the page — DOM events, timers,
`fetch`, WebSocket messages, `MessagePort` traffic. The current browser substrate is a typed host-event inbox: a page event becomes
a BL actor message. A full port additionally needs a per-source identity, owner,
close edge and typed I/O protocol; the inbox alone is not a port.

This narrow inbox has been verified in Node and the browser (`FEAT-046`); its
boundary contract is:

> Host merely queues typed event values, wakes an outstanding wait (including a
> timed receive), and exposes `input-size`/`take-input`/`wait-input` leaves; it
> must not choose a process, select mailbox clauses, or install a JS actor. BL
> runtime owns `rt-register-input!`, sink identity, draining FIFO host events
> into BL mailbox via `rt-send`, scheduling and selective receive.

The adapter does not choose a process. `host.mjs::enqueueInput` accepts only
allowlisted topics and ≤4096-character strings, caps the FIFO at 1024, and
`waitForInput` wakes a sleeping scheduler on either an input or deadline.
`runtime.bl::rt-register-input!` owns the sink; `rt-pump-input` drains into BL
mailboxes via `rt-send`. BL disables input wake before sink registration and
clears a matching sink when its actor retires, so queued early events neither
spin on an undrainable deadline nor disappear into a dead pid. `demo.bl`
replies using source `receive`; `demo.html` shows its output. This reuses
port-like discipline without claiming a port's lifecycle, identity or
generalized Web API capability.

### 3.4 Prototype today

| capability | status | evidence |
|---|---|---|
| host → BL event queue | ✅ (tested) | `host.mjs::enqueueInput`, early FIFO, timer/input wake; Node and browser proof |
| BL consumes host events | ✅ (tested) | `runtime.bl::rt-register-input!`/`rt-pump-input` route via `rt-send` |
| browser page demo | ✅ (tested) | `demo.bl`, `demo-worker.mjs`, `demo.html`, `window.actorDemo`; manual fourth message and Stop |
| BEAM-style ports (`open_port`) | ✗ | not present, not planned by `FEAT-046` |
| per-port identity / ownership / close edge | ✗ | Stop ends the one BL demo actor; a generalized source-close protocol is not implemented |
| `is_port` | ✗ | `host.mjs::ERLANG.is_port` is `() => false` (as are `is_pid`, `is_reference`) |

### 3.5 Missing invariants

- **I3.7 — Order.** Host events are delivered to the sink in arrival order. An
  event arriving before the sink registers is **retained** and delivered first
  (`FEAT-046` gate: "Event before BL registration is retained and delivered in
  order").
- **I3.8 — No lost wakeup.** An event arriving between "the inbox was empty" and
  "the waiter was installed" is not lost (`waitForInput` rechecks; the BL side
  must recheck its mailbox after registration, exactly as
  `rt-receive-wait` does).
- **I3.9 — Bounded, and the bound is loud.** The queue is bounded; overflow is a
  named error, never a silent drop.
- **I3.10 — Typed crossing only.** Only allowlisted, size-bounded values cross;
  no arbitrary JS objects or functions enter BL data.
- **I3.11 — Close is an edge.** Stopping the source releases the actors and
  completes them; a source that stops is distinguishable from one that is quiet.
- **I3.12 — The host chooses nothing.** No process selection, no mailbox clause
  selection, no actor policy in JS (the README's one design rule).

### 3.6 Design constraints

- **The inbox is a port substrate; do not build a second queue.** `FEAT-046`
  fixes the transport/policy split. The future contract (order, no lost wakeup,
  bound, ownership, close, typing) lets WebSocket, `fetch` and `MessageChannel`
  reuse it instead of growing sibling delivery paths.
- **A registered sink makes "blocked forever" legitimate.** `rt-sched-loop`
  now permits an indefinitely parked registered input actor while preserving
  the deadlock error when no sink exists (`01` ○7). Future signals and ports
  need their own liveness specification, not a blanket exemption.
- **`wait-input` must not busy-poll.** `FEAT-046`'s own gate. The substrate for
  this already exists: the scheduler sleeps only when there is nothing runnable.
- **The port argument is the "one mutable root" boundary.** `host.mjs`'s
  `rt.inbox` is a host-owned array; the *mailbox* is BL-owned. Keep them
  distinct kinds of thing (C1/C2 depend on the mailbox being the single ordered
  channel).

### 3.7 Risk

| risk | consequence |
|---|---|
| a second inbox added for WebSocket/fetch instead of generalising one | C6 violation; two ordering guarantees |
| BL registration not rechecked after parking | lost wakeup: the event sits in the inbox while the actor sleeps to its deadline |
| host-side "deliver to the first waiting process" convenience | policy in JS; the one design rule is gone, and selective receive becomes untestable |
| unbounded queue | a page that never drains grows without limit; the browser kills the tab |
| close not modelled | actors park on a source that will never speak again; indistinguishable from a hang |
| assuming `open_port`-style byte semantics | the browser boundary is *typed, structured* events, not bytes; carrying a byte protocol over it would be a wrapper nobody asked for |

### 3.8 Gates

Reuse `FEAT-046`'s own gates verbatim — they already state order, early-queue
retention, wake-during-timed-sleep, no lost wakeup, no busy polling, aliveness
across two events, visible order, and stop-release — and add:

| # | check | invariant |
|---|---|---|
| 1 | host event arriving before any sink is registered → delivered first, in order | I3.7 |
| 2 | stop event releases a parked actor and completes the wait | I3.11 |
| 3 | 1025 queued events → named overflow error, not a drop | I3.9 |
| 4 | a non-allowlisted topic / a non-string payload → named rejection | I3.10 |
| 5 | host queue empty for the whole run and an actor parked indefinitely → **not** reported as a deadlock once a sink is registered | §3.6 |
| 6 | G-diff: an actor parked in `receive` on a message from a *process* versus from the *sink* observes the same ordering rules | C2 |

### 3.9 Unresolved options (○)

1. **Is the inbox a "port"?** Model it as one reusable source abstraction with
   per-source identity (WebSocket, timer, DOM), or as a single global sink
   (`FEAT-046`'s current shape)?
2. **Sink identity.** One sink per runtime, one per process, or a registered
   selector process? `FEAT-046` says "sink identity" is BL's to own — the shape
   is not fixed.
3. **Byte vs typed boundary.** Both the repo's `vm/ports` (files + terms) and
   the browser (structured events) are typed; only BEAM ports are bytes. Confirm
   the target never needs a byte protocol, or the design must carry one.
4. **Backpressure.** Is a full inbox an error (today), a blocked host callback,
   or does it apply pressure to the *event source* (drop-oldest, like
   `proc/bus`'s lag policies)?
5. **Page reload.** Is the inbox's state (queued events, sink registration)
   expected to survive a reload? Almost certainly not — but say so.

---

## 4. Distribution — the boundary between runtimes

### 4.1 BEAM/OTP contract

- A **node** is a named VM (`name@host`). `node()`, `nodes()`,
  `net_kernel`, cookie-based authentication.
- Once connected, **pids, refs and ports are transparently usable across
  nodes** — a remote pid is a value you can send to.
- **Monitors cross nodes.** A monitor of a remote process whose node becomes
  unreachable delivers `{:DOWN, Ref, :process, Pid, :noconnection}`.
- **Links cross nodes.** A node going down is an exit signal with reason
  `:noconnection` to linked processes.
- **Names:** `{Name, Node}`; `:global` is the cluster-wide registry and lock
  manager; `pg` is the cluster process group.
- **Failure model is byzantine-ish and unreliable:** net splits, `:global`
  divergence, and a node that is unreachable rather than dead. Code can be
  loaded independently per node (`code:load_binary`), so module version skew is
  real.
- Distribution is **opt-in** and costly; many OTP systems are deliberately
  single-node.

### 4.2 Prototype today

| capability | status | evidence |
|---|---|---|
| one runtime per bundle | ✅ | README: "One runtime per bundle" |
| cross-worker transport | ✗ | README |
| transferable BL codec | ✗ | README |
| closure serialization | ✗ | README |
| mutable foreign-value ownership protocol | ✗ | README |
| node identity in a pid | ✗ | pids are integers (`rt-spawn`) |
| remote monitor / link semantics | ✗ | `01` absent |
| `is_pid` / `is_reference` | ✗ | stubbed `false` in `host.mjs::ERLANG` |

The README also notes the harness is "not a long-lived browser service"; a
Worker that is terminated is the closest thing to a node going down, and the
target cannot currently observe it.

### 4.3 Repo BL side

| thing | where | relevance |
|---|---|---|
| registry is **single-node by construction** | `priv/std/proc/reg.bl` header: "Honest scope: single node. `where` is attribute-match, not datalog" | the target's registry (`02`) starts with the same honest scope |
| `:global` used as a **lock/trans**, not a cluster | `priv/std/vm/native.bl` (`erlang/apply :global :trans`), `priv/std/vm/session.bl` (`:global.set_lock`) | `:global` semantics are assumed locally; on BEAM they are already distributed-capable but the repo does not rely on that |
| **cross-daemon coordination by files** | `priv/std/vm/ports.bl` | the repo's actual answer to "one VM's table cannot see another's" — a precedent, and a counter-example to reaching for `:global` |
| **cluster-scoped registry unbuilt** | `docs/the-five-bundles.md` §7 ("Stated unbuilt after step 8: cluster-scoped registry, hot tree upgrade") | the BEAM side has not solved this either |
| distributed *data* store as a separate tier | `priv/lib/datom/store.bl`, `blob-s3.bl` | "distributed" in this repo mostly means **data**, not processes |
| `Registry`/`:global`/`pg` reinterpreted as a query | `docs/the-maximalist-supervisor.md` §3.3 | the design intent if distribution is ever built |

### 4.4 Missing invariants

- **I3.13 — Node identity.** A process is uniquely identifiable across
  runtimes; two runtimes' pids never collide as values.
- **I3.14 — Remote send.** A remote pid is a value usable wherever a pid is
  (C4), and a send to an unreachable one is a defined outcome, not a crash.
- **I3.15 — Node-down is a monitor/link event.** A monitor of a remote process
  delivers a DOWN with a distinguishable reason when its runtime becomes
  unreachable; a link yields the same as an exit signal.
- **I3.16 — Codec is total and loud.** Every value that crosses is serializable;
  a closure or host handle is a named error, never a silent `null` or a shared
  mutable object.
- **I3.17 — Single-node programs pay nothing.** If a node identity is in every
  pid, that is a per-message cost and a change to every existing program — the
  cost must be justified (see ○1).

### 4.5 Design constraints

- **The protocol vocabulary is already fixed (C3).** A remote `:DOWN`/`:EXIT`
  must reuse the local shapes; distribution must not invent a second failure
  vocabulary.
- **The browser already has a transport.** `MessagePort` / `BroadcastChannel` /
  `Worker.postMessage` with **structured clone** — a codec that is total *for
  JS values* and rejects functions. That rejection is exactly I3.16's loud
  failure; it also means BL types (keywords, `BMap`, `Cons`, closures) do not
  cross unchanged. A "transferable BL codec" is therefore the first concrete
  deliverable, not an afterthought.
- **`host.mjs`'s value layer is the codec's input.** `hashKey` is already an
  injective structural encoding, but it is *not* a wire format (it drops type
  distinctions a decoder needs — e.g. `:x` and `"x"` both length-prefix).
- **Failure needs a source of truth.** In a browser, "node down" is not
  observable: a Worker is terminated, a tab closes, and no message arrives. The
  host must supply the signal — which pushes part of `01`'s signal layer into
  the host boundary for the *first* time, and is the one place where the
  "policy in BL" rule needs a host atom (the observation that the peer is gone).
- **The repo's own precedent is files, not `:global`** (§4.3). For a browser
  target the analogue is a shared durable medium (a `SharedWorker`, a service
  worker, `localStorage`/IndexedDB) — worth weighing against peer-to-peer
  `MessagePort` before choosing.

### 4.6 Risk

| risk | consequence |
|---|---|
| pids become `{node, pid}` late | every program, test and trace changes at once; a migration, not a feature |
| structured clone assumed to carry BL values | keywords become strings, `BMap` becomes a plain object, closures silently fail — I3.16 violated invisibly |
| remote failure left to timeouts | a partitioned Worker is indistinguishable from a slow one; supervisors restart things that are alive |
| `:global`-style cluster naming attempted in a browser | divergence with no rejoin story; the repo's file-based precedent exists precisely because a table cannot see another VM |
| distribution attempted before `01`–`03` | a remote `:DOWN` needs a local `:DOWN`, a remote monitor needs a local monitor, and a remote restart needs `02` |

### 4.7 Gates

| # | check | invariant |
|---|---|---|
| 1 | two runtimes; a pid from one used as a value in the other; a send arrives | I3.13, I3.14 |
| 2 | a monitor on a remote process; the remote runtime is terminated → DOWN with the node-down reason, exactly once | I3.15 |
| 3 | a closure in a message → named error at the boundary, not a silent `null` | I3.16 |
| 4 | a keyword survives the round trip as a keyword; a `BMap` as a map | I3.16 |
| 5 | G-diff: the same two-node scenario against BEAM `:peer`/`net_kernel` produces the same event order and the same reason | — |
| 6 | a single-runtime program's trace is byte-identical before and after node identity is added | I3.17 |

### 4.8 Unresolved options (○)

1. **Is distribution in scope at all?** A browser app often wants one runtime
   plus a *server*, not peer Workers. A "client runtime ↔ server node" model is
   simpler than peer distribution and may cover the real use case. Decide before
   designing pids.
2. **Node identity shape.** `{node, serial, creation}` vs an opaque runtime id;
   and whether it is opt-in per build (I3.17).
3. **Transport.** `MessagePort` per peer, `BroadcastChannel`, a `SharedWorker`
   hub, or a server relay. Each has a different failure model.
4. **Codec.** Reuse `hashKey`'s structure as a starting point, or a dedicated
   portable BL term format (and where does it live — `runtime.bl`, so both
   targets can speak it)?
5. **Node-down observation.** The host must supply it; is that a new host atom
   (a "peer gone" signal) or a heartbeat/timeout policy in BL? (The former is
   more honest; the latter is more portable.)
6. **Authentication / trust.** BEAM uses a cookie; browsers use origin and
   `postMessage` target-origin checks. Is any of that in scope, or is the
   boundary trusted (the prototype's current stance: "Trusted code, not a
   sandbox")?
7. **Cluster naming.** Does the JS target ever get a global name table, or does
   `02`'s single-node registry stay final — matching `reg.bl`'s honest scope?

---

## 5. Consolidated wave order

```
W0  vocabulary + trace
 └─ W1  lifecycle (01) ─────────────────┬───────────────────────┐
      ├─ W2a names/registry (02) ───────┤                       │
      ├─ W2b gen_server (02) ────────────┤                       │
      │    └─ W3 supervision (02) ───────┤                       │
      │                                 │                       │
      ├─► W4a ETS  (needs W1 owner death; ○ representation)      │
      ├─► W0 inbox verified; W4b port protocol still needs W1     │
      └─► W4c distribution (needs W1–W3 + node identity) ────────┘
```

| boundary | can start when | cannot be *verified* until |
|---|---|---|
| ETS | ○1 (representation) is decided | W1 owner-death transaction |
| inbox transport | verified in worktree (`FEAT-046`) | narrow BL sink/typed browser strings; independent of W1 |
| per-source ports | design open (`FEAT-053`) | W1 owner death plus capability/close protocol |
| distribution | after ○1–○3 of §4.8 | W1–W3, and a node identity decision |

---

## 6. Cross-boundary unresolved options

| # | option | blocks |
|---|---|---|
| B-1 | table representation: host-owned mutable `Map` vs BL map vs CoW | ETS, and the "one mutable root" claim |
| B-2 | one reusable event-source abstraction vs one global sink | ports, and every future external source |
| B-3 | is distribution in scope for a browser target at all | pid identity, codec, node-down |
| B-4 | node-down: a host atom or a BL policy | distribution honesty; also the first crack in "policy stays in BL" |
| B-5 | memory-only tables vs persistence across reload | ETS scope; drags in IndexedDB/OPFS |
| B-6 | does `system/verify` gate the emitted program (C5), tying `01`–`03` back to the BEAM side | all three boundaries' proof strategy |
