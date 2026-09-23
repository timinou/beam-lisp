# 02 — Naming, GenServer conventions and supervision

> **Status: analysis only. Nothing here is implemented.**
> Depends on [`01-process-lifecycle.md`](01-process-lifecycle.md): every
> mechanism in this document is built on monitors/links and exit reasons.
> Legend and gates: [`README.md`](README.md).

---

## 1. Scope

**In:** registered names and `whereis`; the GenServer *conventions* (`call`,
`cast`, correlated reply, timeout, `handle_info` catch-all); the supervisor
process (child specs, restart types, strategies, intensity/escalation,
shutdown ordering); supervisor introspection (children snapshot, restart
ledger, events).

**Out:** the link/monitor primitives themselves (`01`); a cluster-wide registry
or remote children (`03`); ETS-backed state (`03`); the browser event inbox
(`03`) — though a supervisor's idle wait depends on it being *not* treated as a
deadlock.

---

## 2. BEAM/OTP contract

### 2.1 Names

- `register(Name, Pid)` makes an atom globally addressable; `whereis(Name)`
  answers `Pid | undefined`; `unregister/1` releases it; `registered/0` lists.
- A name is **released when its owner dies**. A registration of a dead pid is
  refused. Two live registrations of one name is a `badarg` — never a silent
  overwrite.
- `{Name, Node}` extends a name across nodes (`03`).
- The OTP `Registry` pattern (`:unique` / `:duplicate` keys, monitored entries
  that auto-retract) is the modern, richer form; `:global` is the cluster form.
  The repo's `proc/reg.bl` is the Registry pattern: a relation `pid ↔ attrs`,
  kept true by a monitor per registration.

### 2.2 GenServer conventions

- `call(Pid, Msg)` is synchronous: the caller sends a tagged request with its
  own pid and a **fresh ref**, then waits in a selective receive for that ref,
  with a **timeout**. On timeout the caller **exits** (`{timeout, …}`) — it does
  not silently return. The reply is correlated by the ref, not by order.
- `cast(Pid, Msg)` sends and returns `ok`; it must never block.
- `handle_info/2` receives everything that is not a call/cast — this is how
  `{:DOWN, …}` and trapped `{:EXIT, …}` arrive.
- `init/1` returning anything other than `{:ok, State}` fails the child's
  **start**, which fails the tree's start.
- `terminate/2` runs on a controlled shutdown (a `gen_server` traps exits), then
  the process exits with the shutdown reason.
- Ordering: messages between a pair are FIFO; a signal does not overtake an
  earlier message from the same sender (C2).

### 2.3 Supervision

- A **child spec** is a value: `id`, `start` (MFA), `restart`, `shutdown`,
  `type`. `id` is unique within a supervisor.
- **Restart types:** `:permanent` (always), `:transient` (only on an abnormal
  exit), `:temporary` (never). "Abnormal" excludes `:normal`, `:shutdown`,
  `{:shutdown, _}`.
- **Strategies:** `:one_for_one` (only the dead child), `:one_for_all` (every
  sibling), `:rest_for_one` (the dead child and every child started after it).
  *Which* sibling set restarts is the whole of the strategy.
- **Intensity:** more than `max_restarts` in `max_seconds` and the supervisor
  **terminates itself** with a shutdown reason. Its own supervisor sees that and
  restarts the subtree — the escalation ladder. Restart intensity is a
  hierarchical control loop, not a retry counter.
- **Order:** children start left to right; stop in reverse. `one_for_all` and
  `rest_for_one` restart sets must respect that order.
- **Shutdown:** a supervisor sends `exit(child, :shutdown)` and, after the
  child's `shutdown` window (`ms` or `:infinity`), kills it.
- A supervisor must **never block and never crash on a child's death**; it
  observes and restarts. But a supervisor *does* terminate on intensity
  exhaustion — dying is part of its contract.
- Introspection: `which_children/1`, `count_children/1`, `terminate_child/2`,
  `restart_child/2`, `delete_child/2`.
- **OTP does not expose per-child restart counts.** `proc/super.bl` says so
  outright: *"the tree shape is what it exposes, so that is what we hand back."*
  Any restart *ledger* must therefore be maintained by us — that is the whole
  thesis of `research/supervision-contracts/`.

---

## 3. Prototype today (measured)

| capability | status | evidence |
|---|---|---|
| names / `whereis` | ✗ | `rt-send` takes a pid (an integer); no name table, no `registered` |
| pids as addressable-by-value | ✅ | `rt-spawn` returns an integer; `rt-send` looks it up in `:procs` |
| correlated reply (a `ref`) | ✗ | no `make_ref`-equivalent; `rt-hash-key` exists but identity generation does not |
| `call` (sync request) | ✗ | no call protocol in `runtime.bl`; the compiler emits raw `:recv` |
| `cast` (async) | ◐ | `rt-send` is the primitive; no convention around it |
| receive timeout | ✅ | `rt-deadline-of` / `rt-receive` — the *substrate* a `call` timeout needs |
| `defserver` / callback clauses | ✗ | the compiler accepts top-level `defn` only (README); `init`/`handle_call`/… do not exist on this target |
| child specs / restart | ✗ | README: "Actor errors currently fail the batch run" |
| supervisor process | ✗ | none |
| restart intensity / escalation | ✗ | none |
| introspection (`children`, `which_children`) | ✗ | none |
| restart ledger / supervision events | ✗ | none, on either target |

**The precise gap.** The target has the *substrate* a `call` needs (selective
receive + a fixed deadline) but not the *correlation* (a ref). It has the
substrate a supervisor needs (a process that can park waiting for monitors) but
not the signals (01) or the naming (2.1). Naming and correlation are small,
self-contained additions; supervision is the first layer that is a *policy
engine* rather than a primitive.

---

## 4. Missing invariants

- **I2.1 — Name relation.** A name maps to at most one live pid; `whereis`
  answers nil (not an error) for an absent name; the entry **retracts when the
  pid dies** (a monitor, not a timeout).
- **I2.2 — Name uniqueness is loud.** Registering a held name fails with a
  named error, never a silent overwrite. (The repo's own standard: a second pool
  with the same id "refuses to start, loudly" — `proc/super.bl`.)
- **I2.3 — Correlated reply.** Under two concurrent callers, each receives its
  own reply; the correlation is by ref, never by arrival order.
- **I2.4 — Bounded call.** `call` has a timeout; on expiry the caller takes a
  defined path (exit or value — see ○), and does not leave a stale reply in its
  mailbox for the next call to mistake for its own.
- **I2.5 — `cast` never blocks.**
- **I2.6 — Restart type is honoured.** `permanent` restarts on any exit;
  `transient` only on an abnormal one; `temporary` never.
- **I2.7 — Strategy determines the restart set.** `one_for_all` restarts every
  sibling; `rest_for_one` restarts the dead child and those started after it.
- **I2.8 — Intensity escalates.** Exceeding `N/T` terminates the supervisor
  with a distinguishable reason, so its parent can restart the subtree.
- **I2.9 — Start order.** Left-to-right start, reverse stop; a child whose start
  fails fails the tree's start.
- **I2.10 — The supervisor is never blocked and never crashes on a child death**,
  and its own restart ledger is **reportable** (per-supervisor, per-child — the
  `BUG-041` lesson in `research/supervision-contracts/`: a VM-global counter
  attributes one tree's restarts to another's).
- **I2.11 — Shutdown is bounded.** A child gets its `shutdown` window, then is
  killed; a stopped child's name/Monitor entry is retracted.

---

## 5. Repo BL side

### What the BEAM side has (native OTP — the JS target gets none of it for free)

| thing | where | what it gives |
|---|---|---|
| real OTP `Supervisor` | `lib/beam_lisp/supervisor.ex` | strategies, restart types, intensity, `which_children`, `:observer` visibility |
| `worker/2,3` | same | a zero-arity fn child becomes a `Task` process |
| `server/2..4` | same | a `defserver` child is an MFA to `BeamLisp.Server.start_link/2,3`; an optional OTP `name` keeps a singleton addressable across restarts |
| `pool/5` | same | a **named** `one_for_one` sub-supervisor owning one dispatcher + `n` indexed workers |
| `start_link(%{__supervisor__: true})` | same | starts a `defsupervisor` spec map |
| `defsupervisor` (data) | `priv/std/proc/super.bl` | `(strategy …)` `(intensity n t)` `(child id target arg [opts])`; `children`/`child-of`/`terminate`/`restart` |
| registry as a clause | `priv/std/proc/reg.bl` | `(registry (keys …))` contributes a state slice + a `:down` handler; `register`/`unregister`/`whereis`/`where` |
| the `:down` slot | `priv/std/proc/server.bl` | **one** merged `[:DOWN …]` `handle-info` clause; two clauses that each catch every `:DOWN` cannot coexist (first match wins) |

### Repo gaps (⚙) this workstream shares

- **The restart ledger is declared but unreportable.** `super.bl`'s header calls
  its state "the child set **and the restart ledger**", and `children` says OTP
  exposes only the shape. `research/supervision-contracts/` is the change list
  to fix it (`events`, `ledger`, `render`) — **nothing there is implemented**.
- **`system/verify` over a tree: the docs disagree.** `the-process-pattern-language.md`
  §4.3 lists `super/verify`/`system/verify` (tree) as ○; its §6 ledger lists
  Invariant Gate as ✅ per-process **and** per-tree. Which is true must be
  established before a design relies on it.
- **`defsystem`** (boot-time verification of a whole tree) is ○ in both
  `the-maximalist-supervisor.md` §3.4 and the pattern doc.
- **Hot tree upgrade** (`super/apply` via `reload`) is stated unbuilt in
  `the-five-bundles.md` §7.
- **Cluster-scoped registry** is stated unbuilt in the same place (`03`).
- **No declarative `trap_exit`** (`01` §5) — a supervisor's `terminate` path
  depends on it.

### The strongest reusable design statement

`proc/super.bl` opens with the sentence that should govern the JS layer verbatim:

> *The supervisor is the only bundle that is a PROCESS, not a library: it owns
> children, it must never block, it must never crash.*

On the JS target that is literally a BL process in `rt-spawn`'s world, parked in
a receive waiting for `:DOWN`. Which means it depends on `01` §6's open question:
a supervisor waiting for a child's death must not be read as a deadlock by
`rt-sched-loop`.

---

## 6. Design constraints derived from the prototype

- **A child start is a BL closure in the same runtime.** The target has one
  runtime per bundle and no closure serialization (README), so a child spec's
  `start` can simply be a BL fn value held in the supervisor's state. This is
  *simpler* than the BEAM side, where a child must be an MFA or a `Task`.
- **Child specs are values (repo idiom).** `research/supervision-contracts/` §1:
  "A supervision tree is already data, declared, and readable without running
  it." The JS spec should be a BL map in the supervisor's state, not an
  ad-hoc argument list.
- **The restart decision needs a typed reason.** `01` I1.1 supplies it. String
  matching on an error message (the only thing `rt-run-pid` records today) cannot
  substitute.
- **Correlated reply needs a ref.** `rt-empty-state`'s `:next-pid` is the only
  counter; a `:next-ref` beside it is the minimal addition, and `host/eq` must
  compare it (`01` §6).
- **The supervisor must be startable by the same verbs as anything else.** Repo
  `start-link`/`call`/`cast` are generic over any process; a JS supervisor that
  needs its own API breaks C4 and the verb tiers (`docs/the-five-bundles.md` §0).
- **Pools need names before they work.** `proc/super.bl`'s dispatcher finds its
  siblings through the pool's **registered name**, "a name, not a pid, so it
  survives the sub-supervisor's own restarts." So W2a (names) precedes W3 pools.
- **One `:DOWN` path per process.** If the target grows a `defserver`, the
  merged-`:DOWN` rule from `proc/server.bl` must survive: two monitor consumers
  in one process cannot each own a `:DOWN` clause.

---

## 7. Dependencies / wave order

```
W0 vocabulary + trace
 └─ W1 lifecycle (01)
     ├─ W2a names / registry        ← monitors (auto-retract), refs
     ├─ W2b gen_server conventions  ← refs + timeout edges (independent of W1)
     │
     └─ W3 supervision  ← needs W1 (reasons + monitors), W2a (child names),
                          W2b (a startable child that calls back)
```

- **W2a and W2b are parallel** (disjoint: naming vs. call protocol).
- **W3 is a policy engine**; it cannot start until a child can be started,
  watched and named.
- **W4-ports** consumes W2b's `call` for host-event delivery (FEAT-046 delivers browser strings, but full port protocol remains unbuilt — `03` §3.3); **W4-distribution** re-opens W2a's single-node scope.

---

## 8. Risk

| risk | consequence |
|---|---|
| A `permanent` child that returns `:normal` | restarts forever. The BEAM side already documents this trap: a bare-fn child "would exit `:normal`, and a `:permanent` supervisor would restart it forever" (`supervisor.ex::server/4`). The JS target inherits it exactly. |
| Restart ledger kept VM-global | phantom counts attribute one tree's restarts to another; a budget is a safety mechanism, so phantom counts make trees give up early or never (the `BUG-041` lesson, `supervision-contracts/`) |
| Supervisor blocks (e.g. calls a child synchronously) | it cannot observe deaths; the tree stops healing |
| Supervisor "blocked with no deadline" reported as an error | `rt-sched-loop` fails the batch the moment a healthy idle tree has nothing runnable — the browser service (`03`) never starts |
| `call` without a ref | under two concurrent callers, replies cross; the bug reproduces only under load |
| `call` without a timeout | the caller hangs; with the current scheduler a hang is indistinguishable from a deadlock |
| Strategy implemented as a list filter without order | `rest_for_one` restarts the wrong set; the invariant is "started after", which needs the ordered child list |
| Names not retracted on death | `whereis` answers a dead pid; sends vanish silently (`rt-send` only logs) |
| Kill/shutdown in the wrong order | orphaned children that outlive their supervisor |

---

## 9. Test / differential proof gates

G-unit / G-adversarial (budgets 17/41/200), each extending `test.bl` +
`verify.mjs`:

| # | check | invariant |
|---|---|---|
| 1 | register `:s`, `whereis :s` → pid; kill it; `whereis :s` → nil | I2.1 |
| 2 | register `:s` twice → named error, first registration intact | I2.2 |
| 3 | two callers `call` concurrently → each gets its own reply | I2.3 |
| 4 | a `call` that is never answered times out on the caller's path, with no stale reply left | I2.4 |
| 5 | `cast` returns before the target has run a turn | I2.5 |
| 6 | child with `:restart :temporary` dies → no new pid; `:permanent` → new pid | I2.6 |
| 7 | `one_for_all`: kill child 2 → children 1 and 3 have new pids too | I2.7 |
| 8 | `rest_for_one`: kill child 2 → children 2 and 3 restart, 1 does not | I2.7 |
| 9 | 4th crash in a `3/5000` window → supervisor exits with the escalation reason, **before** it gives up | I2.8, I2.10 |
| 10 | child 2 fails to start → tree start fails; child 1 (started earlier) is stopped | I2.9 |
| 11 | a supervisor parked waiting for a `:DOWN` is not reported as blocked-forever | §6, ties to 01 ○7 |
| 12 | after `k` induced crashes the reported ledger says `k`, attributable to the right child and the right tree | I2.10 |

G-diff: run the same tree on BEAM (`defsupervisor` / `supervise`) and on the JS
target and compare an **event trace**, not supervisor internals:

```
{:event :tree-start :sup S :children [1 2 3]}
{:event :child-exit :sup S :id :b :pid P :reason :badarith :restarts 1}
{:event :child-start :sup S :id :b :pid P' }
{:event :intensity-exceeded :sup S :restarts 4 :window 5000}
{:event :tree-exit :sup S :reason :shutdown}
```

Comparator: same sequence of `:child-exit`/`:child-start` ids; `P' ≠ P`;
`:intensity-exceeded` strictly before `:tree-exit`; ledger counts equal. OTP will
not answer "how many restarts did child `:b` have", which is exactly why the
trace must be produced by a sidecar **on both sides** — this is change #1 of
`research/supervision-contracts/`, and the JS target is the second consumer that
makes its shape worth fixing.

---

## 10. Unresolved design options (○)

1. **`defserver` on the JS target (O-3).** Build a BL `defserver` loop (clauses →
  a receive loop, `handle_info` catch-all), or accept raw `receive` and let
  supervision start raw BL fns? Without it, "a startable child" is a `defn`, and
  the GenServer conventions exist only as advice.
2. **Bundle portability (O-4).** Port `proc/reg.bl` and `proc/super.bl`, share a
  subset, or keep the JS layer separate? They depend on `defserver`,
  `erlang/monitor`, and `Supervisor/which_children` — none of which the target
  has. Sharing the *message shapes* (C3) does not require sharing the code.
3. **Ledger shape.** Adopt `research/supervision-contracts/`'s proposed
  `(proc.super/ledger s)` → `{:id {:restarts :window :last-reason :last-at}}`?
   Fixing it once serves both targets.
4. **`call` timeout semantics.** BEAM exits the caller. A value-returning
   timeout (`{:timeout}`) is friendlier for a browser service but diverges from
   the BEAM contract; if it diverges, `G-diff` cannot compare the timeout case
   directly.
5. **Supervisor as a supervised process.** `defsupervisor` children may be
   supervisors (pools are sub-supervisors). Is the JS supervisor just another
   pid in `:procs`, restartable by its parent, with no special case? (Recommend
   yes; the repo's pool depends on it.)
6. **`children`/introspection protocol.** The supervisor is a process; a
   snapshot is a `call`. That needs W2b *and* a decision on whether the answer is
   the repo's `[{:id :pid :type}]` shape or the richer ledger shape.
7. **Where does the `:DOWN` handler live?** One supervisor process handling all
   children (OTP's model, and the only shape where `one_for_all` is expressible)
   versus one watcher per child. The former is the contract; state it explicitly
   so it is not re-decided.
8. **Pool semantics on the JS target.** Round-robin dispatcher over a
   sub-supervisor is the repo's design; is that the target's, or does the target
   ship only `one_for_one` and leave pools to a later design?
9. **`defsystem` / boot-time verify (O-6).** Does the JS target gate a tree with
   `system/verify` on the source before starting (C5), or start and observe?
