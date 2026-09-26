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

`verify.mjs` is the broadest Node verifier. Focused gates use the same
regenerated bundles, except the standalone host table leaf and numeric research
spike:

```sh
node research/js-actors/verify-lifecycle.mjs   # links, monitors, exits, one death
node research/js-actors/verify-trace.mjs       # logical BL source frames
node research/js-actors/verify-numeric.mjs     # ANF integer emission gate
node research/js-actors/verify-names.mjs       # names, correlated calls, defserver
node research/js-actors/verify-tables.mjs      # BL-owned table subset and ETS diff
node research/js-actors/verify-table-leaves.mjs # opaque host storage and scaling
node research/js-actors/verify-supervision.mjs # restart policy, ledger, OTP diff
node research/js-actors-future/numeric-spike.mjs # 34-case exact-number research
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

The compiler builds `runtime.bl` with `test.bl` into `out/bundle.mjs`, with
`demo.bl` into `out/demo.mjs`, with `super-demo.bl` into
`out/super-demo.mjs`, and with `trace-demo.bl` into `out/trace-demo.mjs`.
All four import `../host.mjs`; deploy them with that
relative layout. Numeric decision reports are generated beside each bundle
under `out/numeric-gate.*.json`. No BEAM process is involved when Node or the
browser executes any bundle.

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
`browser.html` exercises the full 457-check batch suite in a real module Worker
(the original 104 checks remain part of it).

### See BL supervision and recovery in the browser

Open <http://127.0.0.1:8765/super-demo.html> after the same build and HTTP
server. `super-demo.bl` declares one tree with `proc.super/defsupervisor`, starts
it as a BL actor and prints its own `sup-children` ledger. The page sends one
automatic **Crash child** event after BL reports ready. Its log shows the
actor's `[:down ...]` monitor notification exactly once; the ledger shows the
old pid, the new pid and the incremented restart count; **Send message**
is routed in BL through the stable `:demo-worker` name to the fresh child and
prints its `[:pong :worker text]` reply. Browser-tool verification sent a
message after the first restart and observed that named reply. **Crash child
again** and **Stop tree** exercise a manual second restart and graceful
shutdown. The thin `super-demo-worker.mjs` transports validated strings and
forwards BL output; it knows no pid, strategy, child or restart rule. Browser-tool verification
observed pids `[:pid 1 2]` → `[:pid 1 3]` → `[:pid 1 4]`, one live message
between crashes, then Stop with no Worker error. `window.supervisorDemo`
exposes `state`, `events`, `output`, `send` and `worker` for repeatable checks.
Runtime incarnation numbers depend on startup and are **not** a public ABI.

A supervised child is **refused** as a browser input sink with
`:supervised-input-sink-unsupported` before it receives events. A child that
consumes an event then crashes needs an acknowledgement protocol before
restart can promise delivery-once or explicit rejection; this prototype does
not invent that promise. The long-lived application actor owns the demo sink.

### See a logical BL source trace in the browser

Open <http://127.0.0.1:8765/trace-demo.html>. `trace-demo.bl` deliberately
raises in a BL actor; its module Worker forwards the BL runtime's diagnostic
and then ends with the *expected* failure. The browser tool observed
`research/js-actors/trace-demo.bl:5:3 in trace-demo-leaf/0` and marked the
source frame proved. This page does not parse `Error.stack`, synthesize frames
in JavaScript, or pretend the actor continued after its fatal error.

### One quoted-data Loom-like view and one server-owned Live intent

This is the first **explicit** frontend/backend placement fixture, not automatic
fencing. From this worktree, rebuild both bundles and run the focused gates:

```sh
BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl
node research/js-actors/verify-quoted-view.mjs
node research/js-actors/verify-quoted-frontend.mjs
node research/js-actors/verify-quoted-backend.mjs
node research/js-actors/verify-quoted-browser.mjs
node research/js-actors/quoted-server.mjs --port 8765
```

Open <http://127.0.0.1:8765/quoted-view.html>. A persistent module Worker
runs the BL-authored closed data-form evaluator and shows an accessible card:
heading, `unread: 7`, button and text. **Mark all read** sends the data request
`{op:"increment",version:"7"}` to the same-origin loopback Node transport.
The separate BL backend actor holds version and a fixed server-local `:viewer`
principal/grant; it checks the intent against the *same* pure
`qv-intent-apply` contract and returns its typed outcome. Only success causes
the Worker to re-evaluate the view, now showing `unread: 8`. A stale version,
unknown operation or malformed request is refused without changing the view.
The Stop button retires the frontend actor. `window.quotedDemo` exposes
`state`, `view`, `version`, `events`, `errors`, `request(op,version)` and `stop`
for browser-tool inspection.

`quoted-view-core.bl` is built into both bundles—no duplicate evaluator or
intent policy. It accepts only vector **data** headed by `:card`, `:heading`,
`:button`, `:text` or `:field`, with closed attributes, fields and an
`[:intent :increment]` action. Unknown forms/attributes, excessive depth,
node count or text return typed refusals. A composite `(quote …)` literal is
not supported by this target; the vector form is self-evaluating data, not a
general Lisp interpreter. The frontend emits one fixed, described frame;
`quoted-view-frame.mjs` decodes only that exact shape, and the page assigns
values to `textContent`, never to HTML. Browser inputs and HTTP bodies are
bounded; the page's CSP disallows inline scripts. The backend bundle is not
served as a static asset.

**Trust boundary:** this loopback, single-user fixture does not provide login,
sessions, TLS, CSRF tokens, durable state, multi-tab convergence, a general
lossless BL wire codec or automatic `loom`/`live` partitioning. The Node HTTP
process validates *transport shape* and serializes requests; the BL backend
owns the allow/deny and version transition. The fixed `:viewer` principal is
server-local but is **not authenticated** to a human user. Do not expose this
service publicly. The browser runtime still executes trusted BL only; a
closed grammar is not an untrusted-code sandbox. A second page loading after
a first page increments the version starts at the demo's fixed `7` and receives
a stale refusal rather than an automatic resync. The research
[frontend-fence assessment](../js-actors-future/05-frontend-fence.md) names the
proof/codec/call-graph work required before auto-fencing can be honest.

### Edit BL data and run it entirely in the JS Worker

The [frontend fence lab](http://127.0.0.1:8765/quoted-playground.html) lets you
edit the actual view form and click **Run in JS Worker** (Ctrl/⌘+Enter). Start it
with the same `quoted-server.mjs --port 8765` command above; after assets load,
you can stop the server and keep editing/running the view. Source and rendered
view never go to `/api/intent`. The page shows the placement verdict, a preview,
and the inferred *narrow* bridge contract. Its button becomes live only when
the compiled BL backend advertises a compatible contract. A click sends exactly
`{op:"increment",version:"7"}` to `/api/intent`; only BL authorization and a
server-confirmed successor cause the Worker to render `unread: 8`. A stale,
malformed, offline or inconsistent response leaves the last confirmed view
unchanged. The first `7` is a local fixture: opening another tab after a commit
requires reloading/resync, not an optimistic increment.

```sh
node research/js-actors/verify-quoted-form.mjs
node research/js-actors/verify-quoted-playground.mjs
node research/js-actors/verify-quoted-intent-codec.mjs
node research/js-actors/verify-quoted-playground-page.mjs
node research/js-actors/verify-portable-helper.mjs
```

**Automatic within one closed grammar, not automatic BL partitioning:**
`quoted-form.mjs` reads bounded BL **data** vectors, keyword-keyed maps,
keywords, strings and nonnegative safe integers. It refuses calls, lists,
symbols/captures, quotes, effects, duplicate keys, unknown operators and
unsupported numeric forms before conversion to host BL values. Only the exact
`card → heading(level 2) → field(:unread) → button([:intent :increment]) → text`
shape is frontend-eligible; free strings can change but the topology, field,
intent and resource limits cannot. A deterministic manifest names the client
view, `:unread` input and server-owned `:increment`/version contract. The
Worker's typed input mechanism bounds finite data, then the **compiled BL**
`quoted-view-core.bl` evaluator makes the final grammar decision and emits the
existing strict frame. Neither the reader nor the Worker uses `eval` or a JS
compiler. The sample environment starts at local `"7"`; only successful BL backend
responses may advance it. The preview itself grants no commit authority.
`qv-wire-contract` in `quoted-view-core.bl` is the single declaration for
schema, intent, dynamic field and wire bounds. The compiled BL backend announces
it at boot; the Node host validates that descriptor, exposes read-only
`/api/contract`, and uses `quoted-intent-codec.mjs` for transport shape. The
browser uses the **same codec** to match the view manifest, encode a canonical
request and refuse inconsistent responses. The backend independently keeps the
server-local principal/grant/version policy; a codec cannot authorize an intent.
Focused checks include 4,097 finite wire round-trips and refusal fixtures, not
a universal proof of every BL value or authenticated users.

| What runs where | Current verdict | Why |
|---|---|---|
| Fixed bounded quoted data view | Browser Worker | Closed grammar, known dynamic field, compiled BL evaluator and bounded frame decoder |
| `[:intent :increment]` declaration | Browser as data, then server request on click | A matching BL-advertised codec permits transport; backend decides and commits |
| Authentication, authorization, version check, state commit | Backend responsibility | BL demo checks grants/version and commits; human authentication is **not implemented** |
| BL calls, closures, captures, effects, arbitrary Loom/Live modules | Refuse placement | No complete transitive call/effect/provenance/codec proof or target ABI witness |

This is a **closed-form gate**, not a security sandbox. The bridge is now
contract-checked but still explicit, not a generated endpoint or a universal
codec proof. The earlier `quoted-view.html` remains a separate fixed-view demo.
The source-backed [frontend-fence assessment](../js-actors-future/05-frontend-fence.md)
details what must be established before general bridges.

**First automatic function verdict (separate from the interactive view):**
`compiler.bl/portable-helper-verdict` admits the source-built `view-label/0 →
label/0` string chain in `portable-helper.bl`. It requires a complete qualified
`codebase/dependency-cone`, all-clause `system.analyze` footprints/termination/
string sort, and successful lowering plus the emitter's real checked ABI. Its
additional syntactic fence permits *only* a nullary printable-ASCII literal or
nullary direct local call, source ≤4 KiB and literal ≤64 bytes: no parameters,
closures, captured data, dynamic dispatch, effects, numeric inference or wire
values. The effectful unrelated `main` lies outside the selected cone; unknown
functions, second-clause effects, closures and non-ASCII literals are refused.
`verify-portable-helper.mjs` checks the emitted JS result. This verdict proves
one narrow portable helper, **not** automatic Loom/Live partitioning; the bundle
still has an explicit entry and the helper is not wired to the playground. The
[split showcase](#one-bl-file--client-server-and-contract-the-split-showcase)
below generalizes the same three oracles to parameters, whole view closures and
a generated contract.
Alias-qualified graph reachability and later-clause effect union now provide
necessary evidence but are not by themselves sufficient to move a view.

### One BL file → client, server and contract (the split showcase)

[`showcase.bl`](showcase.bl) is an ordinary BL program — a shared launch
checklist — plus one `split/defapp` declaration. The build derives **where every
function runs** and emits three artifacts:

| Artifact | Holds |
|---|---|
| `out/showcase-client.mjs` | runtime + [`split-client.bl`](split-client.bl) + only the functions the view, the local reducer and the shared checks reach |
| `out/showcase-server.mjs` | runtime + [`split-server.bl`](split-server.bl) + the authority's closure: init, checks, guards, apply, private data |
| `out/showcase.contract.json` | snapshot type, each intent's parameter types, SHA-256 digest of the canonical body |
| `out/showcase.split.json` | per-function placement and the evidence behind it |

```sh
BEAM_LISP_Z3=/usr/bin/z3 ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8' \
  JS_ACTORS_SPLIT_ONLY=1 ./bin/bl run research/js-actors/compiler.bl   # split only, ~3 min
node research/js-actors/verify-split.mjs                                # 23 end-to-end checks
node research/js-actors/verify-order-parity.mjs                         # sort/compare/combinators = BEAM, 30 answers
node research/js-actors/split-server.mjs --port 8791                    # then open http://127.0.0.1:8791/
```

**The declaration.** Roots only — nothing says "client" or "server" per function:

```clojure
(split/defapp launch-board
  {:wire    {:task  [:record {:id [:int 1 9999] :title [:text 1 48] :done :bool}]
             :board [:record {:tasks [:list 12 :task]}]}
   :server  {:init initial-board :snapshot :board :private [blocked-words]}
   :client  {:init initial-local :view board-view :on on-event}
   :intents {:add-task {:params {:title [:text 1 48]}
                        :check add-problem :guard flagged-title? :apply add-task} …}})
```

**Placement is derived and fail-closed.** Client roots are `:client` `:init`/
`:view`/`:on` and every intent `:check`; server roots are `:server :init` and
every `:check`/`:guard`/`:apply`. A function is in a half iff that half's roots
reach it through the emitter's own ANF references (calls *and* function values).
A client-half function must be **portable**, which needs three independent
oracles to agree, per function, plus the app's own word:

* **graph** — `codebase/dependency-cone`: indexed, no unresolved host/interop edge;
* **effects** — `system.analyze`: footprint `{}`, **latent** footprint `{}` (what
  every function value it creates or names would do when called) and
  terminates, over every clause;
* **abi** — this emitter's ANF: no `host/…` leaf, no process/output verb, no
  `receive`, nothing outside the checked ABI — inside every lambda too;
* **values** — the closure flow below: every call cycle provably finite;
* **not `:private`**, and every local callee portable.

**Client code is higher order.** Function values may be created, stored in
data, composed and called: `arrange` (showcase.bl) calls a key function and a
comparator it looks up in `(orderings)`; the refine chips are predicates built
with `complement`, `partial`, `comp` and a function-returning function
(`ends-with`), and `all-of` folds the chosen ones into ONE predicate —
`(reduce (fn [p q] (fn [x] (and (p x) (q x)))) (constantly true) preds)` —
that `filterv` calls. Recursion over data is allowed too (a tree walk is a
recursive function). What the build must prove is that **every call chain is
finite**, and it does so with a whole-app **closure-flow analysis**
(`compiler.bl`, "function values: closure flow"):

* **which function can each call reach?** A 0-CFA over the app's ANF. Abstract
  values are named functions, lambdas (per site), closures a combinator
  returned (per call site, with what they captured) and runtime functions used
  as values; a function value stored in data joins one heap set, and anything
  read out of data may be any member. The shell calls every root with data.
* **the runtime is modeled, not trusted blindly.** For every `runtime.bl`
  function the build *derives* which argument positions it calls now, which a
  returned closure calls later, whether it calls a function found in data,
  and which argument positions it may return — least fixpoints over the
  compiled runtime, failing closed when unconverged. Host leaves that call
  what they are handed (`make-frames`, `run-turn`) count as calling anything.
* **the call graph must have no unproven cycle.** Every call site adds edges
  from the calling node (a function, a lambda, a combinator closure) to every
  value it may call. A cycle is admitted only by one of two proofs:
  * **capture order** — every call inside the cycle calls a value the calling
    closure *captured* (a free local, or a part read from one). A captured
    value existed before the closure that holds it, so each such call reaches
    a strictly older value, and data is immutable and acyclic: no infinite
    chain. This admits `all-of`, whose closures call closures of their own
    kind (`(both (both p q) r)`).
  * **structural descent** — some parameter of every function in the cycle
    (its measure) never grows on a call inside the cycle and strictly shrinks
    around every cycle: the call passes a field of it (`(:kids t)`), an
    element (via `mapv`/`filterv`/`reduce`/`sort-by`/… — which runtime
    function hands its function *elements* of which argument is a checked
    table), or the rest of it under a non-empty guard (`(seq xs)`). A lookup
    that may miss (`(:next t)` is nil at the end) counts only on a path where
    it was tested truthy. Data is finite, so the measure cannot shrink forever.

  Anything else is refused as `recursive`, naming the cycle:
  `(fn [x] (x x))` applied to itself, a Y combinator, the same knot tied
  through `comp`/`partial`/`juxt`/`apply`/maps/vectors/rest lists, mutual
  recursion through named values, `(defn walk-down [xs] (mapv (fn [x]
  (walk-down [x])) xs))` (rebuilding its input), unguarded `(rest xs)`.

Effects are still checked separately (footprint **and** latent footprint:
what every function value a function creates or names would do when called),
and loops by the analyzer's own proof, which requires each measure bounded
**on the recur's own path** by a **loop-invariant** bound, and a `rest`/`next`
step only under a non-empty guard (`(loop [s [1]] (recur (rest s)))` and a
bound recomputed from a growing collection are refused). The manifest marks
each function *calls values*, *a value*, and — when it takes part in an
admitted recursion — which proof admitted it.

`sort`, `sort-by` and `compare` on this target give **BEAM's answers**:
`rt-sort` is a port of OTP `lists:sort/2` (the same comparator calls in the
same order, so strict and non-order comparators agree too), `rt-compare` is BL's
total order with strings by code point. The combinators (`comp`, `partial`,
`juxt`, `complement`, `constantly`, `identity`, `apply`) and the prelude they
travel with (`every?`, `remove`, `keep`, `mapcat`, `group-by`, `frequencies`,
`get-in`/`assoc-in`/`update-in`, `take`, `range`, …) are BL in `runtime.bl`,
written clause for clause after core. `order-parity.bl` runs on both targets;
the build writes BEAM's 30 answers and `verify-order-parity.mjs` requires the
JS run to match them (a naive stable sort and a UTF-16 string order each fail
it). Lists and vectors are ONE sequential family, as on BEAM since the
runtime moved to `priv/boot/rt.bl` (`BeamLisp.Ns.Rt`): `(= [1 2] '(1 2))` and
`(compare '(1) [1])` = 0, while a map still keys `[1 2]` and `'(1 2)` apart
(`(get {[1 2] :v} '(1 2))` is nil) — `H.eq` normalizes, `hashKey` does not.
Empty `sort`/`take` are `()`. Maps and sets have no order here: comparing one
raises. **Known
divergence:** an EMPTY lazy result (`(keep f [])`, `(range 0)`, `(remove f
[])`) is on BEAM a lazy seq that is `=` to nil yet prints `()` and is truthy;
here it is the empty list `()` (truthy, not `=` nil). Non-empty results agree.

Anything else **refuses the build**, naming the path. Each is a real fixture in
`compiler.bl/split-tests` (the actual app, one edit away from a leak):

```
split: board-view cannot run in the browser: board-view (showcase.bl:279)
  → flagged-title? (showcase.bl:96) → blocked-words (showcase.bl:82)
  — private declared :private in :server
split: … board-view → plural — host-call host/write at line 233
split: … board-view → plural — effect send at line 233
split: … board-view → plural — recursive on a call cycle plural → plural (no argument shrinks on every call around it)
split: … board-view → plural → ping — recursive on a call cycle ping → pong → ping (…)
split: … board-view → plural → walk-down — recursive on a call cycle walk-down → fn@334 → walk-down (…)
split: … board-view → plural — recursive on a call cycle fn@233 → fn@233 (…)      # ((fn [x] (x x)) (fn [x] (x x)))
split: … board-view → plural — recursive on a call cycle …                          # the same knot through comp
```

and four higher-order fixtures that must be **admitted**: a lambda that calls
the function it receives, a named function that calls values passed around as
a value, `juxt`/`comp`/`partial`/`complement`/`apply` built and called, and a
recursive tree walk `(defn depth [t] (inc (reduce … 0 (mapv depth (:kids t)))))`.

plus malformed wire types, unknown or wrong-arity roots, and names that would
shadow the runtime. Because each half is emitted as its **own** bundle from its
own closure, server-only code and literals are absent from the client bundle by
construction (`verify-split.mjs` greps for them). The browser gets 30 of the 38
app functions.

**The server stays the authority.** A proposal is
`{request, revision, digest, op, args}`. `split-codec.mjs` decodes it *by
contract* (exact record keys, bounded text, safe-integer ranges) and grants
nothing. The compiled BL `split-server.bl` then checks, in order: the build
digest (`client-outdated`), the declared op and wire args, the revision
(`stale-revision`, with the current board), the **shared** `:check` again on
its own snapshot, the server-only `:guard`, and that the next state still
projects onto the snapshot type (`handler-broke-contract`). Only then does the
revision advance. The snapshot is a **projection**: `:next-id` and `:audit`
exist in server state but have no field in the wire type, so they never leave.

**The client is honest about what it knows.** `split-client.bl` runs the
shared `:check` before sending (a duplicate title is refused *in the browser*,
no request leaves), shows sent intents as pending ghost rows, adopts only a
newer board that satisfies the snapshot type, and on `stale-revision` re-runs
the **same** check against the newer board and re-proposes once — a rebase
decided by app code, not by the transport. A refused or unanswered submit gives
the draft back unless the user has typed since; an unanswered intent is never
assumed committed. Typing and filtering are local-only: no network at all.

**The page** (`showcase.html`, `showcase-page.mjs`) renders the BL view tree
through a keyed reconciler (focus and caret survive per-keystroke renders;
text only via `textContent`, attributes through an allowlist), links the Worker
to `POST /api/intent` and the SSE stream, and shows the placement lanes with
per-function evidence, the generated contract, and a timeline of where each
step ran. Open a second tab: its commits arrive as server snapshots. Sort
buttons re-order rows locally (rows glide to their new place); refine chips
narrow the list through one composed predicate, locally.

Verified in a real browser (two tabs, one authority): local filter with no
revision change; in-browser duplicate refusal with the draft kept; server-only
credential guard labelled as the server's; a forced two-tab race rebased and
committed in both tabs; server killed → intent dropped, board unchanged, draft
returned. Every sort order right with no revision change; a snapshot from
another tab arrives already in the chosen order; an event name the view did
not offer is refused by the Worker.

**Limits, stated.** No authentication (single-user loopback). One app per
file; only `defn`s besides the declaration. The closure flow is a 0-CFA: one
heap set for all data, so a program that stores a function in data and reads a
DIFFERENT one back may be refused for a cycle it cannot actually take
(conservative, never unsound). Recursion is admitted by capture order or by
structural descent over one parameter; lexicographic or size-sum measures are
not tried. `lower-case`/`upper-case` are not offered (JS and BEAM case maps
differ, e.g. final sigma). Ordering of maps and sets is refused. The wire grammar is closed:
`text`, `int`, `bool`, `list`, `record` and named references. This is a
build-time partition of one app, not general Loom/Live placement, and a Worker
is not a sandbox.

### Safe `Number` proof and emission gate (distinct contracts)

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
# 34 tests / 94 assertions passed in the focused proof suite
```

**Critical boundary:** caller-provided input ranges in `number_rule.bl` are
assumptions; the rule neither infers nor enforces them, and `compiler.bl` does
not consume its conditional verdict. Instead the emitter discharges a deliberately
narrow independent fact from literal-only binary ANF arithmetic and let-bound
literal folds. It emits raw JS `Number` only for a proven safe integer interval,
with a witness in `out/numeric-gate.*.json`; variables, joins, loops, floats,
foreign values, unknown calls, zero-crossing remainder divisors and conflicting
annotations stay on checked `H.arith`. That is the implemented portion of
[FEAT-055](../../!tasks/features/FEAT-055-gate-anf-number-lowering-with-trusted-ra.org),
not a trusted variable-range inference system or full numeric compatibility.
[FUP-124](../../!tasks/follow-ups/FUP-124-research-full-exact-numeric-semantics-fo.org)
has a [34-case tagged BigInt/decimal research spike](../js-actors-future/04-exact-numeric-spike.md);
[FEAT-056](../../!tasks/features/FEAT-056-implement-exact-tagged-numeric-runtime-f.org)
tracks the unimplemented exact numeric tower. Checked guards remain for every
unproven operation.

The comprehensive [remaining feature list](../js-actors-future/FEATURES.md)
links all FEATs and their dependency order.

## Files and ownership

| File | Responsibility |
|---|---|
| `compiler.bl` | Positioned reader→canonical ANF→JS emission; `proc/defserver` via `proc.server/clause-plan`, `proc.super/defsupervisor` via `proc.super/supervisor-plan`; fail-closed ABI and witnessed literal-range arithmetic |
| `runtime.bl` | BL prelude, scheduling/receive, atomic process death, links/monitors, names and correlated calls, owned table metadata/permissions/heirs, supervisor actor/restart ledger, browser sink policy |
| `host.mjs` | Value/storage leaves (including opaque mutable table storage), bounded generator machine and logical-frame carrier, generic critical sections, retained root, clock/task adapter; no actor or table-owner policy |
| `test.bl` | Application-level BL acceptance tests running on the compiled runtime |
| `demo.bl` | Browser actor, timer peer and visible replies, all in BL |
| `number_rule.bl`, `number_rule_test.bl` | Opt-in conditional integer proof rule, 34 tests / 94 assertions; not the emitter's trusted range producer |
| `demo-worker.mjs`, `demo.html` | Minimal transport adapter and persistent browser actor UI |
| `super-demo.bl`, `super-demo-worker.mjs`, `super-demo.html` | BL supervisor declaration/app, thin browser transport and visible child-crash/DOWN/ledger/recovery UI |
| `trace-demo.bl`, `trace-demo-worker.mjs`, `trace-demo.html` | Deliberately failing BL actor and browser-visible logical source location |
| `verify.mjs`, `verify-inbox-edges.mjs` | Node-only verifiers: adverse budgets, host boundaries, failure propagation, pre-sink timed sleep and sink-retirement races |
| `verify-lifecycle.mjs` | Node-only verifier: typed pids/refs, links, monitors, exit signals and the one atomic death cleanup, with a native-BEAM differential |
| `verify-trace.mjs` | Node-only verifier: logical source frames through suspension and their rendered failure locations |
| `verify-numeric.mjs` | Node-only verifier: the ANF numeric gate — witnessed raw-`Number` sites and checked fallbacks |
| `verify-names.mjs` | Node verifier: local names, correlated calls and lowered servers; 4-rule native-BEAM comparison |
| `verify-tables.mjs`, `verify-table-leaves.mjs` | BL-owned table subset and 25-rule BEAM comparison; host storage ABI, bounds and scaling |
| `verify-supervision.mjs` | BL restart strategies/ledger, 10-rule and two-step OTP comparison, and simulated browser input transcript |
| `browser.html` | Browser module-Worker verifier |
| `out/bundle.mjs`, `out/demo.mjs`, `out/super-demo.mjs`, `out/trace-demo.mjs`, `out/numeric-gate.*.json` | Generated output/evidence; rebuild rather than edit |

```text
runtime.bl + test.bl
      ↓ existing BL reader, macro expansion and compiler
canonical BL-ANF
      ↓ compiler.bl
JavaScript generators + host.mjs
      ↓
BL-owned process machine, executed in Node or a Worker
```

There is no JavaScript ANF interpreter and no parallel source parser. This
slice accepts top-level `defn`, `proc/defserver` and
`proc.super/defsupervisor` declarations; the latter two use the existing
`proc.*` pure plans to lower to ordinary BL forms before ANF, then compile in
one target namespace. General module descriptors, namespace
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
carries kind, reason and a raw-trace-shaped tuple with **logical BL frames**.
Positioned reader spans reach ANF and generated call steps; the machine keeps
bounded innermost-first call-site metadata across parking and tail replacement.
A new raise captures its site; rethrow preserves that trace; a new finalizer
raise replaces it. The BL formatter reports `file:line:col in fn/arity` where
known, and marks unknown positions rather than parsing JS `Error.stack`.
`ExInfo` map/data/message and ErlangError normalization are implemented, but
these are target-defined logical frames, **not BEAM stacktrace parity**.
Unsupported exception classes and exact host error prose are not claimed.

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

## Names, and the call protocol

A **name** is a stable address for one live process. The name table is one BL map
in the same retained root as everything else, so it is retracted inside the SAME
critical section that removes a dying process — never by a monitor and never by a
sweep. There is therefore no window in which `whereis` answers a corpse.

- one name → at most one live pid; a second registration is REFUSED, loudly
  (`[:name-taken <name>]`), and the first registration stands untouched;
- `whereis` answers nil for an absent name — absence is not an error;
- a registration names a process that is live *right now*, so a corpse cannot be
  registered either;
- a name is a keyword or a string. A pid is not a name, so the two address spaces
  cannot collide in one map;
- names are an ADDRESS table, deliberately separate from `proc.reg`'s monitored
  pid ↔ attributes RELATION: that registry answers a query, a name answers
  "which process is this".

`rt-resolve` is the ONE resolver, and every verb that addresses a process takes
either kind of address. The verbs reach source by their UNQUALIFIED names through
the closed ABI (`call`, `cast`, `stop`, `send`, `whereis`, `register`,
`unregister`), the way `str` and `not` do — there is no second, JS-only process
vocabulary.

The protocol is `call`/`cast`/`reply`/`stop` over the EXISTING mailbox, correlated
by a typed ref; it adds no second delivery path.

| form | message | semantics |
|---|---|---|
| `(call to msg [ms])` | `[:call ref self msg]` | waits for `[:reply ref v]`; exits on timeout |
| `(cast to msg)` | `[:cast msg]` | returns `:ok` immediately, never blocks |
| `(reply v next)` | `[:reply ref v]` | a lowered server clause's answer, then `next` state |
| `(stop to [reason])` | `[:stop reason]` | `:ok`; a lowered server runs `terminate` then ends |

- The deadline is fixed on entry; the default is 5000 ms.
- An unanswered call EXITS the caller with `[:timeout to msg ms]`, as BEAM's does.
- A call to a target that names nothing live exits AT ONCE with `[:noproc to]`,
  instead of waiting out a deadline nothing will meet.
- A LATE reply is left in the mailbox and cannot answer a later call: the reply
  carries the ref of the request it answers, and the waiting receive matches its
  OWN ref by a guard, never by the head of the mailbox. A caller that caught its
  timeout can still find the stale reply where it landed.
- A reply to a caller that has since died is a no-op, not an error.

### `proc/defserver` on this target

`defserver` is the one server declaration a bundle writes. This backend does not
re-derive its DSL: `compiler.bl` hands the SAME source clause data to
`proc.server/clause-plan` with an EXPLICIT target vocabulary and renders the plan
it gets back, before ANF. So

```clojure
(proc/defserver counter
  (init [_] (ok {:n 0}))
  (handle-call [:bump by] [_from st] (reply (:n st) (assoc st :n (+ (:n st) by))))
  (handle-cast [:reset] [st] (noreply (assoc st :n 0))))
```

becomes ONE entry defn (`counter`, taking the init argument) and ONE server loop
defn (`counter__server_loop`): a process parked in a selective `receive` whose
arms are the clauses. Both are ordinary BL, so they pass through the same reader →
ANF → JS pipeline as everything else and nothing in the emitter knows what a
server is.

- `init`/`handle-call`/`handle-cast`/`handle-info`/`terminate` are rendered;
- `reply`/`noreply` become real messages to the caller that asked (a `reply`
  outside `handle-call` is a declaration error, not an unresolved global);
- a clause's `:DOWN` pattern is mapped onto this runtime's `:down` tag at that one
  seam;
- an UNKNOWN clause is refused by name, with the vocabulary this loop renders. A
  clause that compiled but never ran would be worse than one that did not compile;
  so `(registry …)`, `(bus …)`, `(tick …)`, `handle-continue` and `invariant` are
  refused here — this target contributes no clause transforms yet;
- a `(call to msg)` leaves no monitor behind: a server that dies while the caller
  waits is seen as a TIMEOUT, not as `:noproc`. That is a documented deviation,
  not an accident.

## Local lifecycle, owned tables and supervision

### One atomic process death

A pid/ref is a typed `[:pid|:ref runtime serial]` BL value. The host allocates
one runtime identity and carries opaque generator frames; BL owns the registry,
mailboxes, links, monitors and exit-signal rules. `rt-terminate!` is the single
critical transaction for normal return, abnormal raise, explicit kill and link
cascade: remove the process/run-queue/deadline/input registration and names,
settle owned tables, drop its outgoing monitors, send each observer at most one
`[:down ref :process pid reason]`, and propagate local link exits through the
same mailbox path as `rt-send`. A running actor reached by its own link cascade
unwinds **after** the signal transaction rather than continuing with a deleted
registry entry. Tests cover self-monitor, self/other normal exits, trap_exit,
`exit(:kill)` versus explicit `exit(pid,:kill)`, and a child dying between
spawn and a separate monitor call. This is local target behavior, not BEAM pid
serialization, demonitor `:flush` or cross-node ordering.

### Owned table subset

`table-new`, `table-whereis`, `table-owner`, `table-lookup`, `table-insert`,
`table-delete`, `table-size`, `table-snapshot`, `table-select`,
`table-update-counter`, `table-give-away` and `table-destroy` are the target's
one BL policy vocabulary. Only `:set` is implemented. The BL root records
owner, optional heir/name, `:private`/`:protected`/`:public` mode and a typed
table id. On owner death, it destroys the storage or atomically transfers it
to a live heir and sends `[:ets-transfer tid former-owner data]`. A host opaque
handle holds rows in a mutable JS Map—an insert does **not** copy the whole BL
map—but the host never chooses ownership, permissions or transfer. Every BL
operation uses one critical section, including update-counter; unsupported
match specs/continuations fail by name. See `verify-tables.mjs` for the exact
subset and its 25-rule BEAM comparison.

**Trust boundary:** the compiled prototype runs trusted BL. Its public table
verbs enforce access modes, but application BL can currently read `host/state`
and call raw host table leaves, so modes are **not a hostile-code security
sandbox**. Isolating untrusted source requires a separate per-source capability
ABI and proof; do not deploy this slice as a multi-tenant ETS service. The
native `priv/std/proc/table.bl` is the heir/lifetime reference, not an
implementation the JS target directly loads.

### One-level supervisor actor

`proc.super/defsupervisor` passes its source declaration through the same pure
`proc.super/supervisor-plan` used by the native adapter. The JS compiler emits a
BL spec constructor, then `sup-start` starts a regular BL actor with a
single receive loop. That actor owns the child set, restart ledger and visible
`snapshot` (`sup-children`), implements one-for-one/rest-for-one/one-for-all,
permanent/transient/temporary, intensity/escalation, child names, explicit
restart/terminate and bounded shutdown. `:brutal_kill` is an immediate kill;
`:infinity` shutdown waits at most 5000 ms on this target. A tree-level
snapshot is one turn, not a half-restarted state. See `verify-supervision.mjs`
for 79 BL checks and 10 selected native-OTP rules; `super-demo.html` provides
the browser proof. Pool children, dynamic children, nested trees, OTP reason
shapes and a complete `which_children` contract are not implemented and are
refused or documented as narrower semantics.

## Verified results

Freshly rebuilt from BL source on 2026-09-23:

- **457 BL acceptance checks pass in Node** at the default 200-step budget and
  again at 17 and 41 steps. `verify.mjs` also injects an unobserved actor crash,
  checks mailbox and host-boundary invariants, and fails the process on a failed
  check. The browser tool observed **457 checks and 711 Worker timer ticks** in
  `browser.html`.
- Compiler self-tests include closed-ABI refusals, rejected unsafe integer
  literals, suspended `try` forms, five `proc/defserver` lowering cases, six
  `proc.super/defsupervisor` lowering cases, and 23 numeric gate checks.
  `verify-numeric.mjs` checks emitted witnesses against `out/numeric-gate.*.json`:
  four raw-`Number` sites are self-proved; other arithmetic keeps `H.arith`.
- `number_rule_test.bl`: **34 tests, 94 assertions**. Its conditional range
  assumptions remain distinct from compiler-owned literal evidence.
- Focused verifiers pass: lifecycle (including self-monitor and running-process
  link-cascade regressions), logical trace (native-tail location, original
  rethrow and finalizer replacement), names/correlated calls, owned table subset,
  host table leaf scaling, and supervision (strategies, policies, intensity,
  shutdown, child names, ledger). The host timer rounds fractional sleeps UP;
  pre-registration inbox edges passed 20 additional serial runs.
- Selected independent native BEAM differentials passed: **11 exit-signal
  reasons, 4 name/call rules, 25 table rules, and 10 supervisor rules plus a
  two-step rest-for-one trace**. These compare specified observations, not
  universal OTP equivalence. The exact-number research spike compares 34
  native observations with a tagged BigInt/decimal candidate; the exact
  runtime is not implemented.
- The browser tool observed `super-demo.html` crash/restart twice with fresh
  pids, a message accepted between restarts, and graceful Stop. The BL ledger
  and restart policy—not page JavaScript—produced the reported state.

Coverage includes selective/message-major receive, timed/indefinite waits,
fairness, guarded patterns, dynamic calls, caught throws, parked finalizers,
logical source frames, typed pids/refs, atomic link/monitor cleanup, name
retraction, ref-correlated replies, table owner/heir transfer, and supervisor
restart sets. Tail-loop and frame bounds remain tested at 50,000 iterations.
These are prototype regressions, not comprehensive BEAM conformance; exact
message/timer race equivalence and browser page-suspension timing are not claimed.

## Supported surface and limits

Emission exists for `:lit :var :global :remote :arith :apply :let :if :do :fn
:tuple :map :cons :enil :struct :case :recv :try`. This is a **subset implementation of
their semantics**, not full language support. Source `case` currently expands as a
literal comparison macro, so most pattern tests intentionally use `receive`.

- **Exception subset.** `:try`, caught `throw`, ExInfo data/message, typed
  catches and target-defined logical BL source frames survive suspension.
  Native BEAM stacktrace formatting and arbitrary BEAM/Elixir exception types
  are not reconstructed. `:erlang/exit` participates in the local BL lifecycle:
  links and monitors receive target-defined signals/reasons, with selected
  BEAM differential cases pinned by `verify-lifecycle.mjs`.
- **Safe integers and an IEEE-754 float subset only.** Unsafe integer literals and
  integer arithmetic overflow are rejected. Full bignums/decimals and preserving
  the BEAM distinction between `1` and `1.0` remain unimplemented.
- **A small prelude.** Collection operations cover the exercised forms, not every
  core arity, collection protocol, sequence type or printer behavior. Literal
  tuple/list values in `:lit` are rejected; their construction nodes are supported.
- **Explicit actor API for this slice:** `rt-spawn`, `rt-self`, `rt-send`,
  `rt-register-name`/`rt-whereis-name`/`rt-unregister-name`, `rt-monitor`/
  `rt-link`/`rt-exit`/`rt-trap-exit!`, `rt-call`/`rt-cast`/`rt-stop`, with ordinary
  source `receive` and the unqualified core verbs above. Pids and refs are typed
  `[:pid runtime serial]`/`[:ref runtime serial]` handles of ONE runtime, not BEAM
  pid values. Native Erlang actor calls are not generally portable aliases.
- **Local supervision and table subsets, not OTP parity.** The BL runtime has
  typed pids/refs, links/monitors, trap_exit, names, correlated calls, a
  one-level BL supervisor actor with restart strategies/intensity/ledger and a
  BL-owned `:set` table subset with owner/heir transfer. `proc/defserver` and
  `proc.super/defsupervisor` share native declaration plans but render only the
  documented target subset. Pools, contributed registry/bus/tick clauses,
  dynamic children, full ETS match specs/cursors, ports, NIFs and distribution
  remain absent or refused at build time.
- **One lifetime rule for abnormal deaths.** An ABNORMAL death with an observer
  (a link or a monitor) belongs to that observer and is reported on stdout; an
  abnormal death with NO observer is recorded as a run error and fails the batch.
  That is the prototype's rule, not OTP's logger.
- **The call protocol has no monitor.** A server that dies while a caller waits is
  observed as a timeout, not as `:noproc`; only a target that is already gone when
  the request is posted exits immediately. Timeout reasons and exit reasons are
  this target's own tagged vectors, not BEAM tuples.
- **A clause the target does not render is refused at build time.** `(registry …)`,
  `(bus …)`, `(tick …)`, `handle-continue` and `invariant` have no arm in the
  lowered loop, so a declaration that uses one does not compile. This target
  contributes no clause transforms yet.
- **A multi-arity clause may not call its OWN name.** The frontend resolves such a
  call to that clause's self-application scaffold, a one-arity value, and the JS
  machine then reports `no arity N` at run time. `runtime.bl` states the helper
  pattern that avoids it; a compiler diagnostic for it does not exist yet.
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

Next work: a lossless tagged exact-numeric implementation (FEAT-056), verified
trusted variable bounds beyond literal folds (FEAT-055), broader differential
race tests, richer `proc` clause transforms and explicit browser I/O/port
capabilities. Cross-Worker transport remains FEAT-054 research. Do not grow
the JavaScript adapter into an actor implementation: receive and scheduler
policy belong in BL.
