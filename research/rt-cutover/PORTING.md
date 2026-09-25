# Porting the runtime surface into beam-lisp

This is the working contract for the PLAN-143 cutover. Read it fully before
writing a line; it carries every convention and every trap the port has already
paid for.

## The job

`lib/beam_lisp/rt.ex` is the Elixir runtime. It is being replaced, name for
name, by a runtime written in beam-lisp living in `research/rt-cutover/rt/`.
When the port is complete the Elixir module is deleted and the namespace `rt`
becomes the module `Elixir.BeamLisp.Ns.Rt`; the link table is re-pointed at it
and nothing else changes.

Until then, **`lib/beam_lisp/rt.ex` is the specification.** Every function you
port must answer exactly what the Elixir function answers, for every value the
runtime can hold. Where it does not, a call site that works today breaks at
runtime — the link table is consulted on invocation, never at compile time, so
nothing catches it until a user's program runs.

## Files

| path | what it is |
|---|---|
| `research/rt-cutover/rt.bl` | the FACADE — one thin `defn` per public name. **Do not edit.** |
| `research/rt-cutover/rt/*.bl` | the implementation, grouped by concern (`seq`, `eq`, `kind`, `key`, `number`, `reduce`, `raw`) |
| `research/rt-cutover/oracle.bl` | the differential gate: every facade name × 24 values, BL vs Elixir |
| `research/rt-cutover/surface.bl` | the contract read from `BeamLisp.RT:module_info(:exports)` |
| `research/rt-cutover/cost.bl` | static work-class census (see the end of this file) |
| `research/rt-cutover/scaling.bl` | measured growth probe |

Each group adds ONE new file `research/rt-cutover/rt/<group>.bl`. **Do not edit
any other `.bl` under `rt/`, and never edit `rt.bl` or `oracle.bl`** — the
integrator wires the facade once every group has landed, so that concurrent
work cannot collide.

## Naming

BL identifiers are kebab-case. The contract names map mechanically:

| Elixir | beam-lisp |
|---|---|
| `apply_variadic` | `apply-variadic` |
| `data_reader!` | `data-reader!` |
| `not_` | `not-` |
| `hash_key` | `hash-key` |
| `sorted_map_of` | `sorted-map-of` |

Namespace: `(ns rt.<group>)`. Require what you use, e.g.
`(:require [rt.raw :as raw] [rt.kind :as k] [rt.seq :as s])`.

## Verification is the deliverable

Write `research/rt-cutover/probe-<group>.bl`: a differential check that runs
every name you port over a corpus of values, through BOTH your implementation
and `BeamLisp.RT`, and prints `agree / fail` counts plus one line per failure.

```clojure
(defn- outcome [f v]
  (try {:ok (f v)} (catch _e {:raised true})))

;; compare with `erlang/==` on the RESULTS; a raise on both sides agrees.
```

Run it with:

```sh
BEAM_LISP_AOT_CACHE_DIR=/tmp/aot-<group> BL_NO_LOCK=1 \
  bin/bl -p research/rt-cutover run research/rt-cutover/probe-<group>.bl
```

**Every distinct cache dir matters.** The shared AOT cache corrupts when two
checkouts compile at once (BUG-083, and it presents as a compiler crash inside
`priv/boot/reader-node.bl`). Using your own `BEAM_LISP_AOT_CACHE_DIR` is what
makes concurrent work safe. If you see a crash whose stack goes through
`priv/boot/`, stop and say so rather than "fixing" it.

A group is done when its probe reports **0 failures**, or when each remaining
disagreement is written down with the reason it is a deliberate departure.

## beam-lisp traps this port has already hit

- **`cond` clauses are FLAT pairs.** `(cond test expr test expr :else expr)`.
  A wrapper around a clause tries to call a boolean: *"cannot call false"*.
- **`erlang/<=` does not exist** — it is `erlang/=<`. Likewise there is no
  `not=`: write `(not (erlang/== a b))`.
- **`(defn name body)` without a parameter vector** is "unsupported binding
  pattern". Always `(defn name [x] …)`.
- **`not` is a core function, not a prim.** Inside a per-element loop it
  resolves a variable twice on every iteration; `(erlang/== false (erlang/is_list x))`
  costs nothing.
- **A namespace `def` VALUE has no link row** (it has no arity), so every
  reference resolves twice through `BeamLisp.Env` — about 0.4 µs. A `defn` call
  in the same file or another namespace is a direct call. Inside a hot loop use
  a literal or a local binding, never a bare `def` name.
- **Module atoms are literals**: `:"Elixir.BeamLisp.Vector"`. Comparing against
  a literal is free; looking one up in a table is not.
- `()` and `'(a b c)` are reader literals. `(raw/cons a b)` builds a cell.
- A 2-tuple is not a cons cell: `is_list({1,[]})` is false.
- `maps:get` is key-first: `(erlang/map_get k m default)`.
- `erlang/apply :lists :reverse xs` **spreads** `xs` as N arguments. For a list
  argument wrap it: `(erlang/apply :lists :reverse (list xs))`.
- Bare `lists/append` or `maps/to_list` inject spurious `RT.invoke` imports —
  prefer `erlang/apply`, or the `erlang/` BIF directly.
- `:erlang.map_keys/1` does not exist.
- `re-find` is not available in boot namespaces.
- `conj` on a LIST prepends; on a VECTOR it appends. `concat` is not
  `concatenate`.
- `File/read!` reads a file.

## House style

- A docstring must say **why**, not restate the name. If a function has a
  surprising precondition or a cost, that goes in the docstring.
- Do not re-implement what the host already does well: `BeamLisp.Vector`,
  `BeamLisp.Set`, `BeamLisp.Sorted`, `BeamLisp.LazySeq` and `BeamLisp.Decimal`
  are the representations. The runtime's job is to be the *semantic authority* —
  one place where the answer is decided — not to be a second implementation of
  the data structures.
- Read the Elixir source for the exact behaviour before writing. `sed -n
  'START,ENDp' lib/beam_lisp/rt.ex` with the line numbers in your assignment.
- If the Elixir code raises a specific error for a bad shape, reproduce the same
  error, with the same kind of message. `call_shape_error` exists for this.

## What the analysis passes will say about your file

`research/rt-cutover/cost.bl` computes a work class for every definition and
flags a loop-invariant call to a non-constant function — the shape that made the
first comparison pass quadratic. Do not add one. If a loop can avoid re-walking
or re-realizing something, it must. Run it after your change if you like:

```sh
BEAM_LISP_AOT_CACHE_DIR=/tmp/aot-<group> BL_NO_LOCK=1 \
  bin/bl -p research/rt-cutover run research/rt-cutover/cost.bl
```
