# beam-lisp

**jank's language, the BEAM's runtime.**

[jank](https://jank-lang.org) is a Clojure dialect native to C++.
beam-lisp is the same idea aimed at the other native target that
matters: the BEAM.

## The clever turn

Porting jank's C++/LLVM compiler to the BEAM would be an enormous
project. It is also unnecessary, because both halves of the problem
are already solved:

1. **jank ships its language as data.** jank's entire standard library
   is `core.jank` — 260 KB of Clojure written in jank itself. The
   language definition is portable; only its backend is tied to C++.
2. **the BEAM ships a native-code compiler with a homoiconic AST.**
   Elixir's quoted expressions *are* a lisp: `(f a b)` ↦
   `{:f, meta, [a, b]}`. Anything you can express as Elixir quoted,
   Elixir's compiler turns into ordinary BEAM bytecode — with
   processes, OTP, per-process GC and hot code reloading included.

So beam-lisp is only the missing middle: a reader that speaks
jank-flavored Clojure, and a small compiler that lowers forms to
Elixir quoted. There is no VM, no FFI, no runtime of our own — just
`mix compile`'s younger sibling.

```
"(map inc [1 2 3])"
  │  BeamLisp.Reader        — text → forms
  │  BeamLisp.Compiler      — forms → Elixir quoted
  │  Code.eval_quoted       — quoted → BEAM bytecode
  ▼
[2, 3, 4]
```

A beam-lisp `fn` is a real Elixir `fn`. A beam-lisp call is
`apply/2`. And interop is not a bridge — it's a calling convention:

| beam-lisp              | compiles to                          |
| ---------------------- | ------------------------------------ |
| `(IO/puts "hi")`       | `apply(IO, :puts, ["hi"])`           |
| `(lists/reverse xs)`   | `apply(:lists, :reverse, [xs])`      |
| `(String/upcase "a")`  | `apply(String, :upcase, ["a"])`      |
| `String/upcase` (value)| `{:"$remote", String, :upcase}`      |
| `(:a m)`               | `Map.get(m, :a)`                     |

Uppercase prefix → Elixir module, lowercase prefix → Erlang module.
Every Elixir and Erlang library ever written is callable, and remote
functions are first-class: `(map String/upcase ["a" "b"])`.

## Usage

```console
$ iex -S mix
```

```elixir
iex> BeamLisp.eval("(defn square [x] (* x x)) (square 12)")
144
iex> BeamLisp.eval("(reduce (fn [acc x] (+ acc x)) 0 [1 2 3 4])")
10
iex> BeamLisp.repl()
user=> (map inc (lists/seq 1 5))
(2 3 4 5 6)
```

## Language status

Supported today: literals, first-class persistent vectors (distinct
from lists, `Enumerable` for `Enum` interop), maps, **namespaces**
(`ns` with `:require`/` :as`/` :refer`, file loading from the load
path, alias resolution through macros too), `def`, `fn`
(incl. multi-clause and variadic `& rest`), `defn` (incl.
multi-arity and docstrings), **`defmacro` with syntax-quote** (` ` ,
`~`, `~@`), `let` and `loop` with full Clojure-style destructuring
(`[a b & rest]`, `{:keys [a b] :as m}` — lenient, like Clojure),
`recur` with compile-time tail-position checking (loops and fns
are both targets), `if`, `do`, `quote`, **`receive` with patterns**
(keywords match themselves, symbols bind, `[p q]` matches tuples
*and* vectors, `{:k p}` matches maps, `(after ms …)`),
keywords-as-functions, variadic arithmetic and comparisons
(`(< 1 2 3)` chains, as Clojure), full Elixir/Erlang interop, and a
self-hosted prelude (`priv/core.bl`: `map`, `filter`, `reduce`,
`range`, `zipmap`, … — itself written in beam-lisp).

Evaluation compiles each form into a real module, so beam-lisp code
runs at native speed with genuine tail-call optimization — this
`loop` runs a million iterations of constant-stack recursion:

```clojure
(loop [i 0] (if (< i 1000000) (recur (+ i 1)) i))
```

Deliberate gaps, roughly in priority order:

- **compile-to-module + var linking** — each evaluated form currently
  becomes a throwaway module (native code, but ~50ms compile cost per
  form and no lifecycle); AOT per-file modules and direct var linking
  replace both that and the per-call var lookups
- **fn-targeted `recur`** — `loop` targets only; a `fn` body is a new
  recur scope
- **HAMT vectors** — the tuple-backed vector is O(1) read / O(n)
  write; fine at idiomatic sizes, swap for a HAMT if profiling
  demands
- **hygiene** — macros are unhygienic (no auto-gensym) for now
- ~~**`receive`, `case`, `cond`**~~ — done: `case`/`cond` are
  prelude macros; `receive` compiles to Elixir's with patterns

## Relationship to jank

Same language family, different host. jank : C++ interop ::
beam-lisp : Elixir interop. As the gaps above close, the plan is to
load increasingly large, unmodified slices of jank's own `core.jank`
as beam-lisp's standard library — jank already wrote it for us.

For the alternative design — embedding jank's C++ runtime in the BEAM
as a NIF — see `!tasks/features/FEAT-001` where the tradeoffs are
recorded. Short version: NIF embedding runs jank's machine code *inside
the BEAM's process*, but jank values would not be BEAM terms, jank
code would not be BEAM bytecode, and a jank segfault would take the
node down. That's embedding, not nativeness; the compiler route above
is what makes beam-lisp *of* the BEAM.

## Examples

Runnable, and guarded by the test suite so they can't rot:

```console
$ mix beam_lisp.run examples/hello.bl      # language tour
$ mix beam_lisp.run examples/interop.bl    # Elixir/Erlang interop
$ mix beam_lisp.run examples/processes.bl  # Task/Agent/spawn: OTP from beam-lisp
$ mix beam_lisp.run examples/macros.bl     # defmacro + syntax-quote
$ mix beam_lisp.run examples/app.bl       # namespaces: require, alias, refer (loads geometry.bl)
$ mix beam_lisp.run examples/control.bl   # cond/case/when/and/or: prelude macros
$ mix beam_lisp.run examples/pingpong.bl  # receive: pattern-matched message passing
```

`processes.bl` is the point of the whole project in one file:
`Task/async` takes a beam-lisp `(fn [] …)` because that fn *is* an
Elixir fun — two million-iteration loops run as real BEAM processes,
concurrently, with `Task/await` joining them.

## Development

```console
$ mix test     # 118 tests: reader, compiler, prelude, vectors, macros, namespaces, receive, examples
```

### The MCP playground (dev only)

Start the app interactively and Tidewave's MCP endpoint comes up on
a deliberately uncommon, loopback-only port:

```console
$ iex -S mix        # or: mix run --no-halt
# http://127.0.0.1:9837/tidewave/mcp
```

Agents (including Spell subagents) can then call `project_eval`,
`get_docs`, `get_logs`, and `get_source_location` against the live
app — e.g. `project_eval` with `BeamLisp.eval("(fact 20 1)")`.
The endpoint never starts for one-shot CLI tasks (`mix beam_lisp.run`,
`mix test`, …), so it can't fight a running playground for the port.

Layout:

```
lib/beam_lisp/reader.ex     text → forms
lib/beam_lisp/compiler.ex   forms → Elixir quoted → native modules
lib/beam_lisp/env.ex        var registry (ETS-backed)
lib/beam_lisp/loader.ex     namespace file loading
lib/beam_lisp/vector.ex     the persistent vector type
lib/beam_lisp/rt.ex         primitives seeded into core
lib/beam_lisp/dev_server.ex dev-only Tidewave MCP endpoint (:9837)
priv/core.bl                self-hosted prelude, jank-flavored
examples/                   executable documentation
```
