# BL-written JavaScript actor prototype

An executable research slice: the existing Beam Lisp frontend produces canonical
BL-ANF; a **Beam Lisp-written emitter** produces JavaScript; the **Beam Lisp-written
actor runtime** is compiled by that same emitter. Generated JavaScript runs without
BEAM. This is not a production backend or an OTP compatibility implementation.

## Run

From the worktree root, with the normal Beam Lisp development image available:

```sh
./bin/bl run research/js-actors/compiler.bl
node research/js-actors/out/bundle.mjs
node research/js-actors/verify.mjs
```

The following minimal language boot was used for the verified clean source rebuild.
It avoids the launcher's full application/native-builder startup; `build/` must
already contain the development image and its required native bootstrap artifacts.

```sh
elixir -pa build -e 'BeamLisp.AOT.boot(); IO.inspect(BeamLisp.Compiler.eval_string(File.read!("research/js-actors/compiler.bl")))'
node research/js-actors/verify.mjs
```

On this workstation the build was given `ELIXIR_ERL_OPTIONS='+S 4:4 +SDcpu 2:2
+SDio 8 +sbwt none +sbwtdcpu none +sbwtdio none'` to avoid its default single
 dirty-I/O scheduler. That is a host tuning choice, not a language requirement.

The compiler builds `runtime.bl` and `test.bl` into `out/bundle.mjs`. The bundle
imports its sibling `host.mjs`; deploy both, preserving that relative layout.
No BEAM process is involved when Node or the browser executes the bundle.

### Browser module Worker

After building:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory research/js-actors
```

Open <http://127.0.0.1:8765/browser.html>. The page launches a module Worker,
imports the generated bundle, records the acceptance output and checks that
Worker timer callbacks ran during execution. A timeout, Worker error, assertion
failure or missing success marker fails the page. The structured result is also
available as `window.actorVerification`. No shared memory or isolation headers
are required for this harness.

## Files and ownership

| File | Responsibility |
|---|---|
| `compiler.bl` | Existing reader/compiler integration, ANF→JS emission, shared pattern lowering, target-reference audit and compiler rejection tests |
| `runtime.bl` | Portable prelude, process registry, FIFO runnable queue, mailbox scan/removal, timeout policy, wait registration and scheduling |
| `host.mjs` | Value representations and leaves, generator-frame machine, generic critical sections, retained state root, clock/task adapter |
| `test.bl` | Application-level BL acceptance tests running on the compiled runtime |
| `verify.mjs` | Node-only external verifier: adverse scheduling budgets, host boundaries and injected actor failure |
| `browser.html` | Browser module-Worker verifier |
| `out/bundle.mjs` | Generated output; rebuild rather than edit |

```text
runtime.bl + test.bl
      ↓ existing BL reader, macro expansion and compiler
canonical BL-ANF
      ↓ compiler.bl
JavaScript generators + host.mjs
      ↓
BL-owned process machine, executed in Node or a Worker
```

There is no JavaScript ANF interpreter and no parallel source parser. This slice
accepts top-level `defn` forms, converts each to the existing named-function form,
and compiles it in one target namespace. General module descriptors, namespace
loading, top-level definitions/effects and redefinition remain future work.

## Control and suspension

Every emitted BL function is a generator. Non-tail calls yield a call step and
save a generator frame; tail calls replace that frame. Function bodies establish
tail context; only the final expression of a `do` inherits it. Operands are
materialized in source order, preserving evaluation across suspension.

The machine handles calls, tail calls, parking, host waits and bounded turns.
Normal BL maps/tuples are not machine control records. The scheduler stores
opaque frame stacks in BL process records and hands them to `host/run-turn`.
The maximum frame depth is measured; the acceptance suite requires it to stay
below 1,024 while executing 50,000 loop iterations and the other tests. Finishing
a long loop alone would not prove bounded space.

Calls through closure parameters use the same managed ABI, including callbacks
that receive. The prototype does not yet optimize proven synchronous functions
into direct JS calls.

### Atomic runtime updates

The runtime itself is managed BL, so an ordinary read/modify/write sequence could
otherwise be preempted. BL mutation helpers enter short generic critical sections;
the machine defers budget preemption until they leave. The host contains no
actor-specific update policy. An exceptional turn restores its entry critical
depth.

Wait registration, mailbox recheck and parking are one scheduling transaction.
`host/park-release` atomically releases the outer critical section and returns a
park step; there is no runnable budget boundary between registration and parking.
Ordinary `host/park` rejects use inside a critical section.

## Receive in BL

The frontend still emits `:recv`. The emitter builds a pattern/guard probe and
separate clause-body closures, then calls BL `rt-receive`.

The probe returns `:nomatch` or a selection carrying a body closure with captured
bindings. It does **not** execute the body. Pattern lowering is shared by function,
case and receive nodes. Guards run only supported synchronous leaves, require
exact `true`, and turn domain errors into clause failure.

BL owns the rest:

1. Evaluate the timeout once and establish a fixed deadline.
2. Scan messages in mailbox order, trying clauses in source order per message.
3. Remove only the selected message before executing its body.
4. Preserve skipped messages and the scan cursor.
5. On exhaustion, answer an elapsed timeout or atomically register and park.
6. On wakeup, scan newly queued messages before choosing the timeout outcome.

Each scan pass uses an immutable mailbox snapshot. Arrivals cannot extend that
pass indefinitely. `after 0` scans its initial snapshot and times out without an
unconditional park. A scan may still cross ordinary scheduler budget boundaries.
No per-receive timer callback is retained: BL owns deadlines, checks them each
scheduler cycle, and requests a host sleep only when there are no runnable actors.

The scheduler uses a FIFO queue and checks deadlines even while CPU-bound peers
remain runnable. The host returns to the browser/Node task queue between bounded
root turns. This is cooperative scheduling, not preemption of arbitrary native JS.

## Verified results

Verified against a freshly regenerated bundle:

- **83 BL acceptance checks passed in Node.**
- The same **83 checks passed with 17-step and 41-step actor budgets**, in addition
  to the default 200-step budget.
- Injected actor failure caused a nonzero process exit; failed checks raise instead
  of printing a misleading success exit.
- **83 checks passed in an actual browser module Worker**, with timer callbacks
  observed while the suite ran.
- Eight negative compiler cases passed, with separately asserted diagnostic text
  for unsupported `:try` and unsafe integer literals.

Coverage includes primitive arithmetic/truthiness, distinct keyword/string keys,
compound structural keys without delimiter collisions, closures, multi-arity and
variadic calls, pattern guards and guard errors, map patterns, repeated wildcards,
nonfinal `do` effects, receive-body effects, selective/message-major receive,
retained skipped messages, zero/timed receives, higher-order suspension, CPU-peer
fairness, deadlines under runnable peers, concurrent sends and bounded frames.

`verify.mjs` also checks safe-integer overflow and atomic-park invariants directly.
These are prototype regressions, not a comprehensive differential conformance suite
against native BEAM. Exact timeout/message race equivalence is not established.

## Supported surface and limits

Emission exists for `:lit :var :global :remote :arith :apply :let :if :do :fn
:tuple :map :cons :enil :struct :case :recv`. This is a **subset implementation of
their semantics**, not full language support. Source `case` currently expands as a
literal comparison macro, so most pattern tests intentionally use `receive`.

- **No `:try`.** Rejected at compilation. Catch/finalizer frames spanning suspension
  are not implemented; generator parking must not accidentally execute cleanup.
- **Safe integers and an IEEE-754 float subset only.** Unsafe integer literals and
  integer arithmetic overflow are rejected. Full bignums/decimals and preserving
  the BEAM distinction between `1` and `1.0` remain unimplemented.
- **A small prelude.** Collection operations cover the exercised forms, not every
  core arity, collection protocol, sequence type or printer behavior. Literal
  tuple/list values in `:lit` are rejected; their construction nodes are supported.
- **Explicit actor API for this slice:** `rt-spawn`, `rt-self`, `rt-send`, with
  ordinary source `receive`. Pids are prototype-local handles, not BEAM pid values.
  Native Erlang actor calls are not generally portable aliases.
- **No links, monitors, registered names, exit signals, supervision, ETS, ports,
  NIFs or distribution.** Actor errors currently fail the batch run.
- **Batch host, not a long-lived browser service.** If every remaining actor waits
  indefinitely with no deadline or runnable sender, the harness reports blocked
  execution as an error. External-event delivery and a persistent host inbox are
  not implemented.
- **One runtime per bundle.** No cross-worker transport, transferable BL codec,
  closure serialization or mutable foreign-value ownership protocol.
- **Trusted code, not a sandbox.** Host intrinsics are available to the prototype.
  Arbitrary blocking leaves, large synchronous collection operations or long
  critical sections can delay peers; reductions do not bound wall-clock latency.
- **Target ABI is closed but manually maintained.** Unknown references fail the
  build. Generated module initialization checks the allowlists against actual host
  exports, preventing missing leaves from being silently deferred to use time.

Next architectural step: explicit handler/finalizer frames and a managed/direct
kernel contract, followed by a host-event inbox and differential semantic tests.
Do not grow the JavaScript adapter into an actor implementation: receive and
scheduler policy belong in BL.
