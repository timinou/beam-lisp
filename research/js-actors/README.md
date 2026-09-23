# BL-written JavaScript actor prototype

An executable research slice: the existing Beam Lisp frontend produces canonical
BL-ANF; a **Beam Lisp-written emitter** produces JavaScript; the **Beam Lisp-written
actor runtime** is compiled by that same emitter. Generated JavaScript runs without
BEAM. This is not a production backend or an OTP compatibility implementation.

## Run

From the worktree root, with the normal Beam Lisp development image available:

```sh
BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl
node research/js-actors/out/bundle.mjs
node research/js-actors/verify.mjs
```

Use your installed Z3 path if different from `/usr/bin/z3`; the CLI's full
application startup expects a bundled or explicitly configured solver on this
worktree.

The following minimal language boot was used for the verified clean source
rebuild. It avoids the launcher's full application/native-builder startup;
`build/` must already contain the development image and its required native
bootstrap artifacts.

```sh
elixir -pa build -e 'BeamLisp.AOT.boot(); IO.inspect(BeamLisp.Compiler.eval_string(File.read!("research/js-actors/compiler.bl")))'
node research/js-actors/verify.mjs
```

On this workstation the build was given `ELIXIR_ERL_OPTIONS='+S 4:4 +SDcpu 2:2
+SDio 8 +sbwt none +sbwtdcpu none +sbwtdio none'` to avoid its default single
dirty-I/O scheduler. That is a host tuning choice, not a language requirement.

The compiler builds `runtime.bl` with `test.bl` into `out/bundle.mjs`, and the
same runtime with `demo.bl` into `out/demo.mjs`. Both generated bundles import
`../host.mjs`; deploy them with that relative layout. No BEAM process is
involved when Node or the browser executes either bundle.

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

### See an actor receive browser events

Open <http://127.0.0.1:8765/demo.html> using the same HTTP server. The page
shows a status badge, a visible browser/BL event log, a text field and **Send to
BL actor** / **Stop actor** buttons. It first sends one input before runtime
creation. After BL reports ready, it sends one while another BL actor has a
pending timer. After BL reports timer completion, it sends one while the input
actor waits without a deadline. These stages are triggered by BL output, not
assumed machine startup timings. You will see separate `[browser]` and `[bl]`
rows, and can send more text at any time. The Worker stays alive between clicks;
Stop sends a BL message that ends the actor. `window.actorDemo` exposes
`state`, `events` and `output` for browser-tool verification.

The actor and timer are in **`demo.bl`**. `demo-worker.mjs` only validates and
transports strings through the host adapter; it does not pick a pid, inspect a
mailbox or generate a reply. The BL scheduler picks its registered input sink,
forwards FIFO events into its mailbox and applies ordinary source `receive`.
`host.mjs` can retain events before startup and wake a sleeping scheduler,
including one with a deadline. Input is bounded to 1,024 queued frames,
string payloads of at most 4,096 characters and validated topic names.

The Node verifier exercises all three delivery stages, direct host wake, early
Stop, pre-registration timed sleep and normal/crashing sink cleanup;
`browser.html` continues to exercise the original 104-check batch suite.

### Safe `Number` proof rule (research, not yet emitted)

`number_rule.bl` implements an opt-in BL rule for **integer** expressions:
`:yes` with proof evidence, `:no` with a counterexample, or `:unknown` with a
runtime-guard/exact-fallback obligation. It preserves the source tag that says
`1.0` is a float even though JS `Number.isInteger(1.0)` is true. It uses
`system.smt`/`system.model`/`system.decide` and Z3 for symbolic obligations,
Veritas for bounded exhaustive checks, `typed` for literal categories and
`codebase/index-source` for source call-site provenance. Unknown sibling calls
in a process state never inherit a `:yes` from unrelated safe arithmetic.
N-ary reductions and branching/guarded process states return `:unknown` until
intermediate results and every control-flow path are modeled; checking only the
final value or first state wrapper would have produced false certificates.

```sh
BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl test research/js-actors/number_rule_test.bl -p research/js-actors
# 29 tests / 80 assertions passed in this worktree
```

**Critical assumption:** caller-provided input ranges must be *true*. This
research rule neither infers nor enforces those bounds, and `compiler.bl` does
not consume its verdict. Existing safe-integer runtime guards therefore stay.
[FEAT-055](../../!tasks/features/FEAT-055-gate-anf-number-lowering-with-trusted-ra.org)
is the trusted-bound/compiler-integration gate;
[FUP-124](../../!tasks/follow-ups/FUP-124-research-full-exact-numeric-semantics-fo.org)
spikes exact bignums/decimals. A `:yes` here is conditional, **not** full BL
numeric compatibility or permission to remove guards.

The comprehensive [remaining feature list](../js-actors-future/FEATURES.md)
links all FEATs and their dependency order.

## Files and ownership

| File | Responsibility |
|---|---|
| `compiler.bl` | Existing reader/compiler integration, ANF→JS emission, shared pattern lowering, target-reference audit and compiler rejection tests |
| `runtime.bl` | Portable prelude, process registry, FIFO runnable queue, mailbox scan/removal, timeout policy, input sink and scheduling |
| `host.mjs` | Value representations and leaves, generator-frame machine, generic critical sections, retained state root, clock/task adapter |
| `test.bl` | Application-level BL acceptance tests running on the compiled runtime |
| `demo.bl` | Browser actor, timer peer and visible replies, all in BL |
| `number_rule.bl`, `number_rule_test.bl` | Opt-in conditional integer proof rule and 29 focused tests |
| `demo-worker.mjs`, `demo.html` | Minimal transport adapter and observable browser UI |
| `out/demo.mjs` | Generated BL browser app; rebuild rather than edit |
| `verify.mjs`, `verify-inbox-edges.mjs` | Node-only verifiers: adverse budgets, host boundaries, failure propagation, pre-sink timed sleep and sink-retirement races |
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

### Persistent browser input

The host queue accepts typed browser strings before or after `newRuntime`, and
`waitForInput` sleeps on either a timer or the next event. It never assigns a
process or scans a mailbox. BL `rt-register-input!` sets the recipient in BL
scheduler state; `rt-pump-input` drains the FIFO into that actor with `rt-send`.
When every actor is parked, a registered sink makes an indefinite wait valid.
An external event wakes the scheduler, which then runs the actor normally.
Without a registered input sink, pre-registration events remain queued: a timed
receive sleeps to its deadline instead of spinning on undrainable input, and
the original no-sink deadlock diagnostic stays in place. Actor completion or
failure clears its matching registration; a stale sink cannot swallow events
or mask another actor's deadlock. This is one runtime per Worker, not
distributed actor transport.

### Suspended exception scopes

Canonical `:try` emits a real `try/catch/finally` **inside the generated
function's JS generator**. The machine carries either a returned value or a
thrown envelope across generator frames and budget yields; it resumes a caller
with `generator.throw` on failure. Protected bodies, catch handlers and
finalizers cannot tail-replace their own generator frame: that would erase the
dynamic scope. Their callees may still run tail loops without growing frames.

This keeps pending normal/exceptional completion alive while a receive parks in
the body, handler **or finalizer**. Cleanup runs once, its normal value is ignored,
and a cleanup error replaces the pending result/error. Catch handlers do not
catch errors from themselves. The emitter reuses the frontend's existing
normalized exception dispatch and typed catch tests; it does not invent a second
source-level exception parser.

The target exception policy is in **BL** (`runtime.bl`). A thin host envelope
carries kind, reason and a raw-trace-shaped tuple. `ExInfo` map/data/message and
ErlangError normalization are implemented for this slice, but the frame list is
empty, not a fabricated BEAM stacktrace. Unsupported BEAM exception classes,
exact host error prose and OTP exit signaling are not claimed.

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

- **104 BL acceptance checks passed in Node.**
- The same **104 checks passed with 17-step and 41-step actor budgets**, in addition
  to the default 200-step budget.
- Injected actor failure caused a nonzero process exit; failed checks raise instead
  of printing a misleading success exit.
- **104 checks passed in an actual browser module Worker**, with timer callbacks
  observed while the suite ran.
- Ten negative compiler cases plus five positive `:try` lowering cases passed;
  the closed ABI and unsafe integer rejection remain checked.
- Five selected exception results were evaluated independently on native BEAM:
  normal cleanup, caught message/data, cleanup error precedence, typed catch,
  and typed catch fallthrough. These examples agreed with their JS assertions.

Coverage includes primitive arithmetic/truthiness, distinct keyword/string keys,
compound structural keys without delimiter collisions, closures, multi-arity and
variadic calls, pattern guards and guard errors, map patterns, repeated wildcards,
nonfinal `do` effects, receive-body effects, selective/message-major receive,
retained skipped messages, zero/timed receives, higher-order suspension, CPU-peer
fairness, deadlines under runnable peers, concurrent sends, caught throws,
typed catches, higher-order errors, nested cleanup order, error precedence,
parked bodies/handlers/finalizers, protected
tail loops and bounded frames.

`verify.mjs` also checks safe-integer overflow and atomic-park invariants directly.
These are prototype regressions, not a comprehensive differential conformance suite
against native BEAM. Exact timeout/message race equivalence is not established.

## Supported surface and limits

Emission exists for `:lit :var :global :remote :arith :apply :let :if :do :fn
:tuple :map :cons :enil :struct :case :recv :try`. This is a **subset implementation of
their semantics**, not full language support. Source `case` currently expands as a
literal comparison macro, so most pattern tests intentionally use `receive`.

- **Exception subset.** `:try`, caught `throw`, ExInfo data/message and typed
  catch dispatch survive suspension, but raw BEAM stacktrace frames are not
  available and arbitrary BEAM/Elixir exception types are not reconstructed.
  `:erlang/exit` does not propagate links or monitor messages.
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
- **Single-Worker inbox, not a general browser effect runtime.** A registered BL
  input actor can remain blocked indefinitely and receive future browser strings.
  If no sink is registered and all actors block without a deadline, the batch
  still reports blocked execution as an error. There is no persisted event log,
  general fetch/WebSocket adapter or cross-Worker actor transport.
- **One runtime per bundle.** No cross-worker transport, transferable BL codec,
  closure serialization or mutable foreign-value ownership protocol.
- **Trusted code, not a sandbox.** Host intrinsics are available to the prototype.
  Arbitrary blocking leaves, large synchronous collection operations or long
  critical sections can delay peers; reductions do not bound wall-clock latency.
- **Target ABI is closed but manually maintained.** Unknown references fail the
  build. Generated module initialization checks the allowlists against actual host
  exports, preventing missing leaves from being silently deferred to use time.

Next architectural step: a managed/direct kernel contract, persistent host-event
inbox, then broader differential semantic tests (including timeout/raise races).
Do not grow the JavaScript adapter into an actor implementation: receive and
scheduler policy belong in BL.
