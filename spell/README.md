# spell/ — recreating spell.jank on beam-lisp

A parallel study: take the spell.jank harness (`../spell-junk` — a
self-rewriting agent harness with a clay-rendered GUI, ~5.6k lines of
jank + ~1.4k lines of C++) and recreate its features in beam-lisp, as
first-principles as the platform allows. Two purposes:

1. a **flagship app** for beam-lisp — the proof that the language can
   hold a real, stateful, process-heavy, self-modifying program;
2. a **design sieve** — spell.jank's ~80 primitives, clustered by the
   *force* each one answers, so we can see which forces the BEAM
   already answers, which beam-lisp should answer in its stdlib, and
   which remain genuinely app-level.

Feasibility context and measured runtime facts: org item `PLAN-017`.
Blockers filed: `BUG-002` (nested receive patterns), `BUG-003`
(pr-str on structs). This file is the design; `src/` is the code.

**Status: 3 of 7 clusters implemented and verified running**
(`mix beam_lisp.run spell/src/main.bl`). The other 4 are specified
here with their exact contracts and the one thing that unblocks each.

## Method: cluster by force, not by file

spell.jank's modules are organized by *where code runs* (boot = C++
primitives, ui = constructors, main = loop). That organization is an
artifact of jank's constraints (no threads, single poll loop, defonce
for everything). The first-principles question is instead: **what
single need does each primitive serve, and what is the smallest honest
realization of that need on the BEAM?**

Every primitive of spell.jank falls into exactly one of seven needs.
One of them — the need spell.jank's architecture is *built around* —
dissolves entirely.

## The seven clusters

| # | cluster | the force | spell.jank answered with | the BEAM answers with |
|---|---------|-----------|--------------------------|-----------------------|
| 1 | **BOUNDARY** | untrusted bytes ↔ terms | `read-safe`, `pr-str`, `one_line`, `json-escape`, `jq`, clayd's `edn.hpp` | a data reader (no compile, bounded atoms) + `pr-str` + `:json` |
| 2 | **PROCESS** | run programs that may die | `spell_spawn/reap/poll/recv`, read-ahead buffer, handshake, `quitting?` | `Port` + monitor + `:transient` supervision |
| 3 | **FENCE** | run code you don't trust | `eval-safe`, `call-safe(-timeout)`, siglongjmp | `spawn` + `monitor` + deadline (✓ `spell.fence`) |
| 4 | **STORE** | state outlives code | `defonce` atoms ×11 | named processes / `defserver`, ETS, `:persistent_term` (✓ `spell.store`) |
| 5 | **SELF** | rewrite yourself safely | `persist!`, dep-walk, `known-good` source strings, rollback, rescue keys | compile→binary, `:code.load_binary`, verify, revert to previous binary |
| 6 | **VIEW** | UI is data | `el`, `text`, sizing, palette, `realize`, editing ops | transliterates 1:1; editing becomes grapheme-exact (✓ `spell.ui`) |
| 7 | **AGENT** | the LLM loop | curl + jq + sqlite, cassettes, tool loop, PAINT-BEFORE-BLOCKING | `:httpc`/Port + `:json` + fenced eval; blocking disappears into a process |

| dissolved | **PUMP** | multiplex events on one thread | poll(2) loop, tick folding, "no threads (JIT unsafe)" | *not a thing*: sources are processes; per-sender order is free |

## Cluster 1 — BOUNDARY · untrusted bytes ↔ terms · ⛔ BLOCKED, language substrate

The single most important cluster, and the one spell.jank got most
right: **reading is as dangerous as evaluating.** Every byte from the
renderer, a cassette, a provider, or the model is hostile until parsed
by something that cannot execute and cannot grow unbounded state.

jank's answer was a fenced `read-safe` C++ call. beam-lisp's
equivalent *must* be a **data reader**: same grammar as the reader,
but producing terms without compiling and without interning fresh
atoms — keywords and symbols are tagged binaries, atom-interning
happens at a bounded set of sites. `docs/trust-boundary.md` specifies
this already; the harness is the first consumer that makes it
load-bearing. Measured why it matters: `eval` as a reader costs
6.55ms/op, leaks ~2 atoms/op monotonically, and a 60fps event stream
through it is a scheduled atom-table abort (PLAN-017).

- Contract: `(read-data s) → {:ok value} | {:error reason}`. One value
  per call. Never throws, never interns a fresh atom per token.
- Round-trip: `(read-data (pr-str tree))` ≡ `tree` for every wire shape.
- **Lives in the language**, not the app: `lib/beam_lisp/data_reader.ex`
  beside `reader.ex` (share the tokenizer), seeded as a prim by `rt.ex`.
- JSON: `:json` (OTP 28+) replaces jq + json-escape + hex4 entirely.
- Unblocks: clusters 2 (protocol), 5 (reading ns forms), 7 (cassettes).

## Cluster 2 — PROCESS · external programs · ⛔ thin wrapper missing

The force: run a program whose death must not kill you, talk to it
over stdio, learn when it dies *and whether you asked it to*.

jank paid ~700 lines of C++ for this (fork/exec, process groups,
poll(2), POLLHUP, a 64K read-ahead buffer because stdio buffers ahead
of poll, byte-at-a-time reads). The BEAM ships it: `Port.open
{:spawn_executable, path}` with `[{:line, n}, :binary, :exit_status]`,
plus a monitor. Verified in this session: spawn, line round-trip,
exit status.

Two deletions worth naming:

- **the orphan bug becomes unreachable**: a linked port dies with its
  owner. spell.jank's "the load was the previous run" flake — an
  orphaned clayd from an earlier suite — is a shape the platform
  refuses.
- **`quitting?` / `deliberate-quit?` delete**: "restart on crash but
  not on deliberate quit" is `:transient` restart — declared in the
  child spec, not tracked in an atom and consulted by hand.

What the language still owes (thin, app-agnostic, stdlib-worthy):
a `port` wrapper hiding the two interop warts — nested receive
patterns (`BUG-002`: a port message is `{port, {:data, {:eol, line}}}`,
depth 3, which the compiler currently rejects) and tuple/option-list
construction (PLAN-017 blocker 3). Until then the wrapper's internals
use `erlang/element` chains, which work but read badly.

The **clay protocol client** (`spell.clay`, stub) sits on this
cluster + BOUNDARY: `start!` (spawn + 15s handshake), `frame!`
(realize → tap → `pr-str` → send), `next-event` (read-data), plus the
async command surface (clipboard, screenshot, scroll-state, wheel).
The wire-tap (`frame-log`, `frames-contain?`) is already done — it
moved to STORE and is verified.

## Cluster 3 — FENCE · bounded failure · ✅ VERIFIED

Implemented: `spell/src/spell/fence.bl`, in pure beam-lisp.

Contract: `(fence f args timeout-ms) → {:ok v} | {:error e} | {:timeout ms}`.
The caller is never blocked past the deadline; on timeout the runaway
process is brutally killed.

What the BEAM makes true that jank could not:

- **Honest teardown.** jank's fence siglongjmps out of running C++
  frames and discloses: "treat the image as SUSPECT rather than merely
  'that call failed'". A killed BEAM process releases its whole heap;
  there is no suspect-image caveat.
- **Uniform deadlines.** jank's `safe-on-event` deliberately carried
  *no* deadline — on one thread, a render deadline would abort a
  healthy 6.2s HTTP call mid-flight. Here the HTTP call is a different
  process, so the exception was a scheduling artifact, not a principle.
  Deadlines everywhere, no documented carve-outs.

Two lessons earned writing it (recorded in the file's header):

1. `Task.async` is the wrong fence primitive — it *links*, so a callee
   crashing before the caller enters `yield`'s trap window kills the
   caller (observed). `spawn` + `monitor` is the honest shape.
2. A monitor fires DOWN on *every* exit, `:normal` included. The reply
   path must `demonitor [flush]` or the orphaned DOWN poisons the
   *next* fence's receive (observed: fence N+1 reporting fence N's
   normal exit as its own error).

`fence-value` adds the keep-last-good policy (jank's `last-tree` rule),
factored off the UI so any cluster can use it.

**Stdlib candidacy: high.** Any app needs a fence; the contract is
stable; the implementation is 25 lines of beam-lisp with no app
knowledge. Candidate `priv/fence.bl`.

## Cluster 4 — STORE · state outlives code · ✅ VERIFIED

Implemented: `spell/src/spell/store.bl`.

jank used `defonce` for eleven cells (`app`, `convo`, `known-good`,
`registry`, `last-tree`, …). `defonce` is the wrong primitive to port:
it survives reload but not a crash, and the platform cannot see it. A
**named Agent** survives both — verified: a named Agent kept its value
*and its pid* across a full re-eval of the module that started it.

`state-ensure` is the honest defonce: idempotent creation — the second
call finds the state already there and keeps it (demo: `ensure×2`
preserves). State is addressed by *name*, so code replacement and
state identity are independent by construction.

The wire-tap discipline (`frame-log`, `clipboard-writes` — "tests
assert at the wire, not at internals") is one mechanism here: `tap!`
is a named ring buffer, `tap-contains?` the assertion surface. Already
green in the demo.

Also available, unneeded yet: ETS for shared tables (the Env registry
uses it), `:persistent_term` for hot reads (measured 0.64µs vs 4.5µs
Agent deref — relevant if `view` reads state at 60fps).

## Cluster 5 — SELF · rewrite yourself safely · ⛔ needs a hotswap API

The harness's thesis cluster. The force decomposes into three
operations, and first principles changes *what the artifact of trust
is* at each:

| operation | jank | beam-lisp, first principles |
|-----------|------|------------------------------|
| accept new code | `spit` source, `eval-file` | compile source → `.beam` binary *without loading* |
| install | eval replaces vars | `:code.load_binary` — atomic, two-version code model |
| verify | render probe | same, but through FENCE with a deadline |
| revert | re-`spit` remembered *source* | reload the remembered *binary* |
| dep order | string-scan sources | pure fn over ns *forms* (BOUNDARY makes forms data) |

The load-bearing difference: **jank's known-good snapshot is a source
string that must compile again to be restored** — and its README admits
the hole: revert one module and a sibling changed under it stays
broken (`:revert-error`, "instead of claiming a recovery it did not
perform"). A remembered **binary** cannot fail to compile — it already
did. The failure mode doesn't get handled; it stops existing.

**Rescue keys** (ctrl+r reload / ctrl+z rollback) keep jank's
invariant — "must work when the handler is broken" — with better
structure: jank put them in the pump *by code-order convention*; here
they live in the renderer's owner process, which sees events *before*
the possibly-broken app handler, enforced by supervision rather than
discipline.

What the language owes: a programmatic **hotswap API** —
`compile_string → binary` (the AOT path exists as a mix task; it is
not yet callable from inside the language), plus `:code.load_binary` /
`:code.soft_purge` interop notes. App-level policy (`self.bl` stub):
snapshot, verify-render probe, commit/revert.

## Cluster 6 — VIEW · UI is data · ✅ VERIFIED

Implemented: `spell/src/spell/ui.bl`. The one cluster that is a
*copy* — deliberately: the model was already right. `el`, `text`,
sizing, palette, `realize` (forces thunks, derefs refs, recursively —
demo-verified), `error-tree`.

One strict improvement, free: jank's editing layer counted UTF-8
codepoints (`u8_count/u8_sub`) and disclosed a grapheme off-by-one on
flag emoji and combining marks. Elixir's `String` is grapheme-aware,
so the editing ops here (`gcount/ginsert/gdelete/gslice`) are
grapheme-exact *by construction* — one unit end to end, nothing to be
off-by-one against. Demo: insert/delete/slice across `🚩`.

## Cluster 7 — AGENT · the LLM loop · ⛔ one open question

The force: call providers with credentials; multi-turn tool use where
the tool is eval in your own image; record/replay for tests.

What deletes: curl (→ `:httpc` or a curl Port), jq (→ `:json`),
sqlite3 shell-out (→ sqlite via Port; low-throughput, boundary-safe),
sha256sum (→ `:crypto.hash`, verified), the cassette temp-file dance
(→ EDN cassettes read by BOUNDARY — one format for the whole system),
and **PAINT-BEFORE-BLOCKING** — the hand-drawn "thinking…" frame
existed because one thread couldn't render during a 6.2s API call.
Here the call is a fenced process; the window renders throughout.

The agent's `eval` tool is FENCE applied to `eval` on a scratch
namespace — and the stronger option PLAN-017 verified: a **separate
node** for agent eval, so `(System/halt)` from a model kills a scratch
node, not the harness. That is the sandbox story no single-image
harness can tell.

Open question (from PLAN-017, still unrooted): `:httpc` works under
`elixir -e` but fails under `mix run` (`:http_util` not on the code
path). Root-cause before committing to `:httpc` over a curl Port.

## The GUI connector — decision

The first-principles cut is the one spell.jank already made: **the
wire is the boundary, the renderer is a dumb terminal** for UI trees
and an event source. The renderer's implementation language is
therefore fungible, and the question is which option is least new
code for the most proof:

| option | verdict | evidence |
|--------|---------|----------|
| **A. keep clayd** (C++, clay + vendored static raylib) | ✅ **renderer #1** | jank-independent (verified: one "jank" mention, a comment); builds with vendored `libraylib.a` on this machine; speaks the EDN wire today. Port = copy `src/clayd/`, `vendor/`, `scripts/build-clayd.sh` into this repo. **Zero new code.** |
| **B. terminal renderer** (pure beam-lisp, ANSI) | ✅ **renderer #2** | ~150 lines of .bl, *no C anywhere*. Proves the protocol is renderer-agnostic (the claim the architecture makes), gives headless CI, and its input side is scriptable — a natural test harness for the event protocol. |
| C. Odin renderer | ⏸ deferred | clay has **official Odin bindings** (`nicbarker/clay` → `bindings/odin`) and Odin vendors raylib — the option is real. But odin isn't installed here (not in pacman), it rewrites 1,416 lines of working C++, and the wire means it can be dropped in *whenever*. Do it if clayd becomes a maintenance burden, not before. |
| D. Zig renderer | ⏸ deferred | zig 0.16 IS installed and community clay bindings exist (johan0A/clay-zig-bindings). Same rewrite-cost logic as Odin, weaker bindings maturity. |
| ✗ wxErlang | rejected | A widget toolkit, not a render canvas — you'd rebuild text/layout by hand. Worse: wx runs as an in-VM driver; a renderer crash can take the VM. Violates the trust boundary the subprocess exists to create. |
| ✗ Scenic | rejected | In-VM (same coupling), and it re-implements a scene-graph model the wire deliberately avoids ("UI is data" means *no retained graph on the harness side*). |

The wire protocol itself is unchanged from clayd's (commands in,
events out, one EDN value per line). It is documented verbatim in
`src/spell/clay.bl`. Keeping EDN over switching to `term_to_binary`
(measured 22× cheaper) is deliberate: the pipe stays `cat`-able, and
"the UI is data" stays inspectable — revisit only if the frame budget
demands it.

## Layout

```
spell/
  README.md            ← this study
  src/
    main.bl            (ns main)            composition root; headless demo ✓ runs
    spell/
      ui.bl            (ns spell.ui)        VIEW     ✓ verified
      fence.bl         (ns spell.fence)     FENCE    ✓ verified
      store.bl         (ns spell.store)     STORE    ✓ verified
      clay.bl          (ns spell.clay)      PROCESS+BOUNDARY  contract, stubbed
      self.bl          (ns spell.self)      SELF              contract, stubbed

      app.bl           (ns spell.app)       manifest: the app's namespaces
      seam.bl          (ns spell.seam)      contract term as DATA      ✓
      contract.bl      (ns spell.contract)  defcontract/defview emit   ✓
      machine.bl       (ns spell.machine)   accumulating registry      ✓
      provider.bl      (ns spell.provider)  AGENT: the LLM call        ✓
      seed.bl          (ns spell.seed)      the seed definition        ✓
```

The last six arrived from `priv/` in PLAN-025 W1. `provider.bl` REPLACES the
`providers.bl` stub this document used to list: the stub's wider surface —
cassettes, `eval-tool!`, the multi-turn `agent-ask` loop, credential loading —
is unbuilt work, and it is recorded as such in PLAN-025 rather than as a second
namespace answering the same need.

Run: `mix beam_lisp.run spell/src/main.bl` (loader resolves `spell.ui` →
`spell/src/spell/ui.bl` via the entry file's directory). From Elixir, load the
whole application with `BeamLisp.Spell.init!()`, which requires `spell.app`;
test suites get `spell/src` on the search path automatically.

## What unblocks what

```
BOUNDARY (data reader) ──► clay.bl (events, frames)  ──► full harness loop
                     ──► self.bl (ns forms as data)
                     ──► provider.bl (EDN cassettes)
BUG-002 (nested receive) ─► port wrapper readability (workaround exists: erlang/element)
hotswap API (compile→binary) ──► self.bl
BUG-003 (pr-str structs) ──► error reporting anywhere (workaround: print ex-message)
:httpc-under-mix ──► provider.bl transport choice (ANSWERED: mix.exs declares
                     :inets/:ssl in extra_applications; live_chat.exs runs)
```

Nothing in the blocked clusters is *designed-but-unwritable* — their
contracts are pinned and their dependencies named. The order that
clears the board fastest: data reader → hotswap API → BUG-002.

## Verified today

`mix beam_lisp.run spell/src/main.bl`:

```
VIEW:  3 children realized; thunk forced; ref derefed
VIEW:  "ab🚩cd" — 5 graphemes; insert/delete/slice exact across 🚩
FENCE: {:ok 3} / {:error "boom"} / {:timeout 300} / keep-last-good
STORE: ensure×2 idempotent; swap; tap ring; tap-contains? true/false
```

## Language gaps found by writing the demo (feed stdlib, not this app)

- `pr-str` crashes on non-beam-lisp structs → `BUG-003`
- no `get-in`, no `mapv` (used `nth`+keyword, `(vec (map …))`) — core.bl candidates
- maps not callable in call position — keywords are; fine, but document
- `(loop [] (recur))` works directly but any receive loop should note:
  monitors fire on `:normal` — always flush (now in fence.bl's contract)
- no tuple literal — `erlang/list_to_tuple` over `(list …)` is the idiom
  (blocker 3); a `tuple` prim would delete ~every interop wart in this study
