# js-actors — a beam-lisp actor runtime compiled to JavaScript

A first vertical slice of the design in
`!tasks/plans/PLAN-141-design-bl-written-actor-runtime-bootstra.org`: the
existing reader and compiler turn beam-lisp source into canonical bl-ANF, a
beam-lisp-written backend turns that ANF into JavaScript, and the actor
runtime — process registry, runnable queue, mailbox, **selective receive with a
scan cursor and a monotonic deadline**, timeout wakeups and the scheduler — is
written in beam-lisp and compiled by that same backend.

Nothing in this directory is an ANF interpreter and nothing re-parses
beam-lisp: `host.mjs` never sees an ANF node, and the only BL-to-JS translation
is `compiler.bl`'s emitter.

## Commands

Build the bundle (runs on the existing BEAM toolchain, from the worktree root):

```
./bin/bl run research/js-actors/compiler.bl
```

Expected tail of that output:

```
js-actors: compiled 77 definitions from 2 sources -> research/js-actors/out/bundle.mjs
js-actors: 505 host references audited (385 remote, 120 global) against the allowlist
NEGATIVE OK   `:try` is refused (no exception frames across a park)
NEGATIVE OK   an unknown remote module is refused
NEGATIVE OK   an unresolved global is refused
NEGATIVE OK   a hand-built unresolved global ref is refused
NEGATIVE OK   an unresolved global nested in a value is refused
NEGATIVE OK   an unknown erlang bif is refused
NEGATIVE OK   the earlier missed shape (vector subject, vector binder pattern) is refused
0
```

Run it (Node ≥ 20; no BEAM, no Erlang, no Mix):

```
node research/js-actors/out/bundle.mjs
```

Expected tail:

```
...
PASS dynamic-recv-callback
js-actors: ALL PASS
```

The build also works from inside this directory, against the same launcher
(the worktree root is two levels up):

```
cd research/js-actors && ../../bin/bl run compiler.bl
```

The launcher needs a built image; from a worktree that has none, point it at
one with `BEAM_LISP_EBIN=/path/to/beam-lisp/build`.

## Files

| file | language | owns |
|---|---|---|
| `compiler.bl` | beam-lisp | the build driver, the bl-ANF → JavaScript emitter, the checked ABI allowlist, the fail-closed reference audit, and the build-time negative tests |
| `runtime.bl` | beam-lisp | the **actor runtime**: the BL prelude over host leaves, process registry, runnable queue, mailbox, `rt-receive` (scan cursor, deadlines, park/wakeup), send, spawn, scheduler |
| `test.bl` | beam-lisp | the application: 66 acceptance checks plus the peers they need |
| `host.mjs` | JavaScript | value representation, leaf operations, the control-step machine (trampoline), the global registry, `performance.now`/`setTimeout` |
| `out/bundle.mjs` | generated | `host.mjs` + the compiled runtime and application (`H.def` / `H.defAlias` / `await H.boot(rt)`) |

## Architecture: what is BL and what is JavaScript

```
test.bl, runtime.bl          beam-lisp source
      │  BeamLisp.Ns.Reader/read_all        (the EXISTING reader)
      │  BeamLisp.Ns.Compiler/compile       (the EXISTING compiler → canonical bl-ANF)
      ▼
bl-ANF nodes
      │  emit-js  (compiler.bl, in BL)      (the ONLY ANF consumer)
      ▼
out/bundle.mjs  ──imports──▶  host.mjs
      │                          │
      │   compiled BL generators│  value leaves · step machine · clock/timer
      ▼                          ▼
   Node / browser
```

Ownership is the point of the slice, so it is worth stating negatively:

* **JavaScript never decides anything about actors.** `host.mjs` contains no
  mailbox, no runnable queue, no clause matching, no pattern compiler, no
  timeout policy, no process registry. It runs a compiled generator and
  delivers values, and it owns exactly one retained mutable root (`rt.state`),
  which is a *BL map* the BL scheduler threads.
* **The BL side never re-implements the language's front end.** It consumes
  bl-ANF only, and the ANF it consumes is the compiler's own output.

### The control ABI

Every compiled BL function is a JavaScript generator. A BL call compiles to a
*step* the machine interprets:

| step | meaning |
|---|---|
| `{__step:true, k:'call', f, args}` | push a frame and run `f` |
| `{__step:true, k:'tail', f, args}` | replace the current frame (tail call) |
| `park` (from `host/park`) | suspend this process, keep its frame stack |
| `host-wait` (from `host/wait-until`) | ask the host to wait `ms` (only the scheduler does this) |

Steps are host objects, never BL values, and the machine checks the brand
(`__step`), so a user map or tuple that merely *looks* like a step stays data —
which is what the design demands at the ABI boundary.

The frame stack is an array of suspended generators. It is a value the BL
scheduler stores in its process registry, and its pending resume value rides on
it (`frames.__sent`), because a fairness slice can end exactly between "a callee
finished" and "its caller resumes".

**Tail calls do not grow the JavaScript stack**: a tail step replaces the top
frame instead of pushing one, so `(loop …)` — which the compiler lowers to
self-application — runs in constant stack. `loop-50000` is a test.

### Fairness

The scheduler runs a process through `host/run-turn(frames, 200)`. When the
turn budget is exhausted the machine returns `yield`, the scheduler requeues
the pid and picks the next runnable one. `peer-progress-under-cpu` sends a ping
to a process that is spinning in a 60 000-iteration loop and requires the ping
to arrive first.

### The receive protocol

`receive` in BL source is compiled in two halves:

1. **The probe (compiler-owned, in the emitted JS).** One labelled block per
   clause, in source order; a pattern or guard failure `break`s to the next
   clause; success returns a BL vector `[:match body-fn]` where `body-fn` is a
   closure that carries the pattern bindings and runs the clause body. The probe
   never runs a clause body.
2. **Selection (runtime-owned, in BL).** `rt-receive(scan, after-fn, timeout-ms)`
   walks the mailbox vector with a cursor, offering each message to the whole
   probe (message-major, clause-minor), **removes the selected message before
   the body runs**, and otherwise registers a wait and calls `host/park`.

Consequences that the tests pin down:

* skipped messages stay in the mailbox, in order (`skip-retained-1/2`);
* message-major order beats clause-major (`message-major`);
* the deadline is computed **once**, before the first scan, so continuing
  arrivals cannot extend a timed wait;
* `after 0` still scans the queue first, then takes one scheduling boundary
  (`host/wait-until 0`) and rescans before timing out (`after0-scans-queue`,
  `after0-times-out`) — a deliberate, documented choice: it makes the
  "already queued across a boundary" case observable rather than instantaneous;
* a matching message already queued wins over the timeout.

## Support matrix

**bl-ANF operations** (`priv/boot/anf.bl` vocabulary)

| op | status |
|---|---|
| `:lit` `:var` `:global` `:remote` `:arith` | supported |
| `:apply` `:let` `:if` `:do` | supported |
| `:fn` (single-arity, multi-arity `$blfn`, variadic) | supported |
| `:tuple` `:map` `:cons` `:enil` `:struct` | supported |
| `:case` (`:pvar :plit :pnil :ptuple :pcons :palias :pmap :pstruct`) | implemented by the emitter, but not exercised by this suite: this beam-lisp's `case` is a macro over `eqv`, so it expands before reaching ANF |
| `:recv` | supported, via the two-phase protocol above |
| `:try` | **refused at compile time** |

`:lit` values: numbers, strings, keywords (including `nil`/`true`/`false`) and
nothing else — a literal tuple or list is a compile error rather than a
silently-wrong JS value.

**Host ABI reached by BL**

| form | meaning |
|---|---|
| `host/…` | a closed leaf table in `host.mjs` (`cons`, `map-get`, `is-vec`, `eq`, `arith`, `now`, `park`, `run-turn`, …) |
| `erlang/…` | guard/reasoning bifs (`is_integer`, `==`, `<`, `tuple_size`, …) |
| `Elixir.BeamLisp.RT/…`, `Elixir.BeamLisp.Ns.Core/…`, `Elixir.BeamLisp.Transient/…` | the compiler's own remote calls for core names, each mapped onto a BL prelude function in `runtime.bl` |
| `…/invoke`, `…/apply_to` | lowered by name into dynamic call steps |

Anything else is a **build failure** naming the pair. 505 references are audited
per build (385 remote, 120 global).

**Prelude implemented in BL** (over host leaves only): `rt-eqv`,
`rt-identical?`, `rt-hash-key`, `rt-first`, `rt-rest`, `rt-nth`, `rt-count`,
`rt-cons`, `rt-conj`, `rt-get`, `rt-assoc`, `rt-empty?`, `rt-seq`, `rt-next`,
`rt-to-list`, `rt-print-str`, and `core-list`, `core-not`, `core-nil?`,
`core-some?`, `core-not=`, `core-inc`, `core-dec`, `core-keyword`, `core-name`,
`core-str`, `core-print`, `core-println`, `core-vector`, `core-hash-map`.

**Actor runtime in BL**: `rt-empty-state`, `rt-spawn`, `rt-send`, `rt-self`,
`rt-remove-mailbox-msg`, `rt-receive`, `rt-min-deadline`, `rt-wake-expired`,
`rt-run-pid`, `rt-run-head`, `rt-sched-loop`, `bl-main`.

## Tests

66 checks, all passing, run as an ordinary BL process on the runtime:

| group | what it pins |
|---|---|
| `pure-tests` (38) | arithmetic, comparisons, truthiness (nil/false only), vectors vs lists vs tuples vs maps, `str`/`keyword`/`name` |
| `closure-tests` (8) | closures over locals, higher-order calls, variadic and multi-arity dispatch |
| `case-tests` (4) | literal `case`, including a vector literal |
| `pattern-tests` (4) | binding patterns, nested patterns and clause guards through `receive` |
| `loop-tests` (2) | `loop`/`recur` stack safety (50 000 iterations) |
| `recv-basic` (1) | source `receive` |
| `skip-tests` (3) | skipped messages retained and consumed in order |
| `order-tests` (1) | message-major scanning |
| `after0-tests` (2) | `after 0` scans before it times out; empty mailbox times out |
| `timed-tests` (1) | a timed receive, a delayed peer and a real `setTimeout` wakeup |
| `fairness-tests` (2) | a peer makes progress while another process is CPU-bound, and the CPU-bound process still finishes |
| `dynamic-tests` (1) | a `receive` reached through a callback parameter |

Plus 7 build-time **negative** tests that assert the backend refuses what it
cannot preserve (see the build output above).

## Limitations (honest scope)

* **No exceptions.** `:try` is refused, not approximated. The machine has no
  catch/finalizer frames, so a `try` spanning a park would lose its `finally`.
* **No links, monitors, exit signals, registered names, supervision, ETS or
  distribution.** This is core selective-receive actors only; no OTP
  compatibility is claimed.
* **Numbers are JavaScript doubles.** No bignums, no exact decimals; `int` and
  `float` are not distinguished.
* **`receive` clause bodies are the only pattern-binding surface.**
  `case` in this beam-lisp is a macro over `eqv`, so `(case x [a b] …)` treats
  `[a b]` as a value to compare (and now fails the build if it names an
  unbound global). Binding patterns work in `receive`, where the compiler's
  pattern compiler runs.
* **Concurrency is cooperative and single-threaded.** Many logical actors share
  one JS turn loop. A foreign call that blocks cannot be preempted, and the
  per-process budget only preempts *compiled BL* steps.
* **One worker, one bundle.** Cross-worker actor transport, a BL codec for
  messages and mutable foreign values are all out of scope.
* **The allowlist is static.** `host-names` and `erlang-names` in
  `compiler.bl` must mirror `host.mjs` by hand; a mismatch is a build error
  naming the missing leaf, not a silent fallback.
* **The audit is by reference, not by reachability.** It proves every emitted
  remote/global is in the checked set; it does not prove the BL prelude itself
  is dependency-closed beyond that.
* **A closure is allocated per loop iteration.** The compiler's self-application
  scaffolding lowers correctly (and stack-safely), but not cheaply.
* **The host is browser-*compatible*, not browser-*verified*.** It uses only
  `performance.now` and `setTimeout` and no Node-only API (the sole `process`
  reference is an optional exit code), but no browser run was performed.
* `after 0` takes one scheduling boundary before it can time out (see above).

## Verification log

```
$ ./bin/bl run research/js-actors/compiler.bl
js-actors: compiled 77 definitions from 2 sources -> research/js-actors/out/bundle.mjs
js-actors: 505 host references audited (385 remote, 120 global) against the allowlist
NEGATIVE OK   × 7
0

$ node research/js-actors/out/bundle.mjs
PASS × 66
js-actors: ALL PASS
exit 0
```

No BEAM, Erlang, Mix or Elixir is required for the second command.
