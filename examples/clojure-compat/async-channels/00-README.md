# core.async on the BEAM — a compatibility prototype

Clojure's `core.async` API (`chan`, `>!!`, `<!!`, `go`, `thread`, `close!`,
`alts!!`, `timeout`) running on beam-lisp — with the Clojure code on top left
as-is and the *hard part deleted*.

## The thesis

On the **JVM**, `core.async` is a heroic piece of engineering. Because JVM
threads are expensive and there is no cheap green thread or selective receive,
`go` is a **macro that rewrites your code into a CPS state machine** so a small
pool of real threads can multiplex thousands of "parked" logical threads.
`<!`/`>!` are the park/resume points that state machine drives.

On the **BEAM**, that entire apparatus *is the substrate*:

| core.async concept | JVM implementation | beam-lisp (here) |
|---|---|---|
| a logical thread (`go`) | CPS state-machine transform | `spawn` — a process already is one |
| parking (`<!` / `>!`) | state-machine suspend points | blocking `receive` — the scheduler parks it |
| `<!` vs `<!!` | park-in-go vs block-a-real-thread | **identical** — one kind of process |
| a channel | lock-free queue + handler callbacks | an **actor** (a process holding buffer + waiters) |
| `alts!` | shared commit flag across channels | **selective receive** over pending requests |

So this is not a *port*. It is the same public API sitting directly on the
machinery core.async spends thousands of lines simulating.

## Three tiers, honestly named

An earlier draft of this doc called `channels` "the BEAM-native model." That
was an overclaim, and it is corrected here. There are **three** distinct tiers,
and only one of them is uncompromisingly native:

| tier | file / ns | model | native? |
|---|---|---|---|
| **demand-flow** | `priv/std/flow.bl` / `flow` | **PULL** — consumer signals demand, producer cannot outrun it (GenStage) | ✅ **the native tier** |
| CSP channel engine | `priv/std/clojure/core/async/impl.bl` / `clojure.core.async.impl` | **PUSH** — bounded buffer + rendezvous (Hoare CSP on actors) | ◐ core.async's *private engine*, filed under the compat tree (like `specter.engine`) — not native, not standalone |
| core.async | `priv/std/clojure/core/async.bl` / `clojure.core.async` | Clojure's CSP API | ❌ compat shim over `…async.impl` |

**Why `flow` is the native tier and `channels` is not.** The BEAM's own answer
to backpressure is GenStage, and it is **demand-driven**: a consumer asks for
*n* events, and a producer is *forbidden* to send more. Backpressure is the
STRUCTURE of the protocol, not a buffer filling up. `channels`/core.async are
PUSH: a producer puts into a buffer and feels backpressure only once the buffer
(a guessed size) is full. Push-with-a-buffer is Clojure's CSP idea; pull-with-
demand is the BEAM's. `flow` implements the BEAM's.

See `07-native-flow.bl` (a demand pipeline) and `08-backpressure-proof.bl`
(which *measures* that a fast producer never emits more than a slow consumer
demanded — high-water ceiling = the demand batch, exactly). That structural
guarantee is the thing channels cannot give and the reason `flow` is the tier a
native beam-lisp author reaches for.

The push-CSP channel engine is *not* standalone native furniture. Nothing
native requires it — its only consumer is the core.async shim — so it lives
**under the compat tree** as `clojure.core.async.impl`, exactly as
`specter.engine` lives under the specter tree: a compat library's private
machinery, filed with the library it serves. The genuinely native concurrency
furniture is `flow` (demand streaming), `defserver`/`gen_server`
(request-reply), and the bare `spawn`/`send`/`receive` trio underneath both.

## Inside core.async: the shim + its private engine

core.async itself is split into two files, mirroring how beam-lisp separates
`priv/std/specter/*` (the Clojure optics library) from its own engine module — a
compat library and its private machinery, filed together:

| file | ns | what it is | size |
|---|---|---|---|
| `priv/std/clojure/core/async.bl` | `clojure.core.async` | the **compat shim** — renames only, zero engine | ~15 aliases |
| `priv/std/clojure/core/async/impl.bl` | `clojure.core.async.impl` | the **push-CSP engine** — the channel actor | ~9 verbs |

(Paths follow the loader's ns→path rule: dots become directory separators, so
`clojure.core.async.impl` lives at `clojure/core/async/impl.bl`. Both sit under
the `clojure/` compat tree — neither is native stdlib furniture.)

The shim reimplements nothing; it requires the engine and renames:

```
core.async (shim)     →  clojure.core.async.impl (engine)
  >!! / >! / <!! / <!  →  put! / take!   (4 arrow names → 2 verbs: parking≡blocking)
  alts!!               →  select
  go / thread          →  spawn + result-chan   (the CPS transform, deleted)
  chan / close! / timeout →  same names, re-pointed
```

**Which tier should I use?**
- **Native beam-lisp streaming** → `flow` (demand-driven, the native tier).
  Examples `07`/`08`.
- **Unmodified Clojure source** → `(require '[clojure.core.async …])`. The shim
  exists so it loads as-is; the push-CSP engine underneath is a compat detail,
  not something native code should reach for (the BEAM already covers its jobs
  via `flow`, selective `receive`, and `gen_server`).

The engine (`priv/std/clojure/core/async/impl.bl`) is ~200 lines, most of it the
channel actor's buffering rules. The shim (`priv/std/clojure/core/async.bl`) is ~15
lines of aliasing over it.

## Why this file order

Each example escalates and is runnable on its own:

1. **`01-hello-channel.bl`** — a channel, a producer process, a consumer.
   Put rendezvous with take; close makes take return `nil`.
2. **`02-go-blocks.bl`** — `go`/`thread` return a channel carrying the body's
   result. Ten go-blocks run as ten processes at once.
3. **`03-pipeline.bl`** — stages connected by channels; close propagates
   source → sink. Backpressured dataflow.
4. **`04-alts.bl`** — `alts!!` races a work channel against a `timeout`. First
   ready wins.
5. **`05-fan-in-out.bl`** — a worker pool: fan-out jobs to N self-balancing
   workers, fan-in their results. A full concurrency pattern in ~20 lines.

Examples 01–05 exercise the **core.async compat shim** (push-CSP). The last two
exercise the **native `flow` tier** (demand-driven pull) — the model a native
beam-lisp author actually reaches for:

6. **`07-native-flow.bl`** — a demand pipeline: source → map → filter → fold,
   where the consumer sets the pace and each stage demands upstream in turn.
7. **`08-backpressure-proof.bl`** — *measures* the native guarantee: a fast
   producer against a slow consumer, asserting the producer's high-water
   emission never exceeds the demand batch. Structural backpressure, no buffer.

## Run them

```sh
mix beam_lisp.run examples/clojure-compat/async-channels/01-hello-channel.bl
# … 02 … 03 … 04 … 05   (core.async shim)
# … 07 … 08              (native flow tier)
```

## Honest boundaries of the prototype

This proves the *architecture*, not a production `core.async`. Known gaps,
recorded rather than hidden:

- **`alts!!` is not linearizable across two ready _data_ channels.** A losing
  branch can consume-and-drop a value in the race window before its `:cancel`
  lands. core.async prevents this with a commit flag locked across all
  channels; that is out of scope here. The common, race-free shape — a data
  channel vs a `timeout` (which only ever *closes*, consuming nothing) — is
  what `04-alts.bl` uses and is safe.
- **No transducers on channels** (`(chan 8 (map f))`). The buffering actor
  would apply the xform on put; not built yet.
- **No `put!`/`take!` callback (non-blocking) forms**, no `pub`/`sub`,
  `mult`/`tap`, `pipeline`. All are expressible on this actor; none are built.
- **`>!`/`<!` are aliases of `>!!`/`<!!`.** Correct on this VM (parking ≡
  blocking), but it means the "must be used inside `go`" discipline the JVM
  enforces simply does not apply — which is the whole point.

The value here is the measured claim: **the substrate core.async simulates is
native on the BEAM, so its API drops onto `spawn` + `receive` with the hard
part removed.**
