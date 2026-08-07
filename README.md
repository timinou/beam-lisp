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
(`(< 1 2 3)` chains, as Clojure), **`try`/`catch`/`finally` +
`throw`** (untyped catch-all with normalized errors, typed
`(catch Module.Name e …)`, `ex-info`/`ex-data`/`ex-message`),
**reference types** (`atom`, `deref`, `swap!`, `reset!`,
`compare-and-set!` — Agent-backed; `future` and `promise` with
blocking `deref`, incl. timeout), `@x` sugar — registered in
`core.bl` through a **rebindable reader-macro table**, not wired
into the reader — **`#()` fn literals** (`%`, `%1`, `%&`), `#_`
discard and char literals, **sets** (`#{}` literals, `set`/`disj`,
transient sets) with `sort` and a total-order `compare`, **open
dispatch** (`defmulti`/`defmethod`, `defprotocol`/`extend-type`,
`derive`/`isa?` hierarchies), **lazy sequences**
(`lazy-seq`, infinite `(range)`, realize-once cells), **transients**,
full Elixir/Erlang interop, and a
self-hosted prelude (`priv/core.bl`: `map`, `filter`, `reduce`,
`range`, `zipmap`, `when`, `case`, `future`, … — itself written in
beam-lisp).

Evaluation compiles each form into a real module, so beam-lisp code
runs at native speed with genuine tail-call optimization. On top of
that, **`defn` links**: clauses become named functions in a
per-namespace module (`BeamLisp.Ns.*`), prims link to their
`:erlang` BIFs, and call sites compile to direct remote calls —
this `loop` runs a million iterations of constant-stack recursion
in ~25ms (~70× the pre-linking registry dispatch, see
`examples/bench.bl`):

```clojure
(loop [i 0] (if (< i 1000000) (recur (+ i 1)) i))
```

The persistent vector is a 32-way bit-partitioned trie in Clojure's
`PersistentVector` shape (`cnt`/`shift`/`root`/`tail`): `conj` is
amortized O(1) through the tail buffer, indexed access O(log32 n),
with path-copying persistence — building a 100k vector by `conj`
went from 9.2s to 12ms. Vectors of 32 elements or fewer stay a raw
element tuple, which is exactly what the compiler emits for literals
and matches in `receive` patterns.

Syntax-quote is **hygienic**: a symbol ending in `#` inside a
backquote auto-gensyms to a unique name (`x#` → `x__42__auto`),
stable within one backquote and distinct across separate ones, so
macro temporaries can neither capture nor be captured by user
locals. The prelude's own `and`/`or`/`case` were the proof cases
— `(let [and-tmp 5] (and 1 and-tmp))` used to return `1`. Macros
written by hand get the same guarantee from the `(gensym)` prim.

And beam-lisp **tests itself**: `deftest`, `is`, `testing` and `are`
(a port of clojure.test, written in beam-lisp in `priv/test.bl`)
register tests that `mix beam_lisp.test` discovers under
`test/**/*.bl`, printing a clojure.test-shaped summary and exiting
non-zero on failure. The prelude's own suite lives in
`test/bl/prelude_test.bl`.

```console
$ mix beam_lisp.test
Ran 11 tests containing 50 assertions.
0 failures, 0 errors.
```

**Atom-table safety.** beam-lisp compiles its input as trusted code,
so symbols and keywords become real BEAM atoms — and a full atom
table is a whole-VM abort, not a catchable exception. The reader,
the one place every source text passes, samples the table and
refuses input past a configurable high-water mark (default 90%),
turning a would-be crash dump into a catchable `AtomLimitError`.
Cost on the read path is under 1%. `docs/trust-boundary.md` has the
full model.

Open dispatch is here too: `(defmulti area :shape)` with
`(defmethod area :circle [s] …)` gives Clojure's runtime-extensible
multimethods — add a method for a brand-new shape after the fact and
every earlier call site keeps working. Dispatch values are arbitrary
(keywords, vectors for multi-arg dispatch, types), with `:default`
fallback and `derive`/`isa?` hierarchies. `defprotocol` with
`extend-type`/`extend-protocol` dispatches on the first argument's
type, and types can be extended after the fact.

Sequences are lazy where you ask for them: `%BeamLisp.LazySeq{}`
cells realize at most once, `map`/`filter`/`iterate`/`cycle` compose
lazily over a lazy input, and `(take 5 (map inc (range)))` walks an
infinite sequence and stops at five. Printing an infinite seq
terminates too. The seq model is currently hybrid — realized inputs
take the strict path — for a reason recorded in `!tasks/plans/`.

And `.bl` files can be compiled ahead of time: `mix compile.beam_lisp`
emits each namespace as a real `.beam` module in the build path,
proven by a test that loads and calls them in a fresh VM with no
runtime compilation — the path from Lisp source to a BEAM release.

Deliberate gaps, roughly in priority order:

- **uniform laziness** — the seq model is hybrid: realized inputs take
  the strict path, so bounded `(range n)` is eager (`PLAN-010`)
- **transducers** — the collection arities of the seq fns are done;
  the 1-arity transducer paths need `volatile!`, `reduced` and `cat`
- **jank stdlib convergence** — 89 of 120 attempted `core.jank` slices
  run unmodified. The sample was doubled once the previous one stopped
  being informative at 63 of 64; the gap list it refilled is led by the
  `cpp/jank.runtime.*` shim and reader `^{}` metadata
  (`docs/jank-compat.md`)
- **Specter** — 1 of 31 slices of Clojure's Specter behave today. The
  number is low on purpose: it is a measurement, not a claim, and it
  ranks the remaining work by what each gap unlocks
  (`docs/specter-compat.md`)

## Errors point at your code

A generated module used to claim beam-lisp's own source, so every
error named the compiler's internals instead of the program:

```
** (ArithmeticError) bad argument in arithmetic expression: 3 + nil
    lib/beam_lisp/link.ex:56: BeamLisp.Ns.Errdemo.boom/1
    (elixir) lib/enum.ex:1725: Enum."-map/2-lists^map/1-1-"/2
```

Now the reader threads `{line, col, file}` through the existing form
metadata channel, the compiler stamps `line:` onto the quoted AST it
emits, and `Module.create` is handed the real path:

```
** (ArithmeticError) bad argument in arithmetic expression
    :erlang.+(3, nil)
    /tmp/err.bl:5: BeamLisp.Ns.Errdemo.boom/1
    … 6 frames in beam-lisp internals
```

Compile errors carry the same location, and say which form:

```
** (BeamLisp.CompileError) /tmp/err2.bl:3: binding forms must be even,
   each a pattern and a value
```

AOT-compiled modules carry it too — those `.beam` files persist and
are what a production stack trace hits long after the compiler that
built them has exited.

**Positions ride on lists only.** A symbol or a vector is as often a
*shape token* as a value — a parameter, a binding name, a `def` name,
a destructuring pattern — and there are ~65 places where the compiler
matches those structurally. Carrying positions on them would have
demanded metadata-tolerance at every one, in exchange for per-symbol
columns that nothing reports. A list is where evaluation happens, so
a list is what an error names.

## What a Lisp gets from the BEAM

Clojure has the JVM; jank has LLVM. Neither has preemptive
scheduling, supervision trees or live code replacement. That is the
argument for putting a Lisp *here*.

`defserver` compiles to a genuine `:gen_server` — not a lookalike:

```clojure
(defserver counter
  (init [start] (ok start))
  (handle-call :inc [_from state] (reply (inc state) (inc state)))
  (handle-cast :reset [_state] (noreply 0)))

(def c (server-start-link counter 10))
(server-call c :inc)   ;=> 11
(sys/get_state c)      ;=> 11
```

The generated module declares `@behaviour :gen_server`, so OTP's own
tooling recognises it: `:sys.get_state/1` reads its state, `:observer`
sees it, and a real `Supervisor` adopts it. The tests assert this with
OTP's tools rather than with beam-lisp's client functions, because
that distinction is the entire point. Every OTP return shape is
expressible — replies, timeouts, `:hibernate`, `{:continue, term}`,
`{:stop, …}`.

Supervision trees are data, which is the one place a Lisp can say that
literally:

```clojure
(supervise :one-for-one [(worker :w (fn [] (serve)))])
```

And code can be replaced in a process that never stops running:

```console
$ mix beam_lisp.run examples/hotswap.bl
== a process is running, calling (version) in a loop ==
so far: #{"v1"}
== redefine (version) while it runs ==
now:    #{"v1" "v2-HOTSWAPPED"}
the worker was never restarted: true
```

Honest about the limits: the next call after a redefinition runs the
new code, but a process already *inside* the old function finishes it,
and in-flight state does not migrate. Only the code moves.

Tracing exposes `:dbg` as data — with rails, because `:dbg` can take
down a production node under load. A call cap (default 1000) is
enforced inside the tracer process, and asserted in the suite rather
than trusted.

## Libraries written in beam-lisp

The prelude has always been `priv/core.bl` — beam-lisp source, not
Elixir. Two more libraries now ship the same way, because a language
whose own libraries need a different language has a hole in it:

```clojure
(ns app (:require [optics] [rewrite]))

;; optics: a path that can say "all of them", which update-in cannot
(over (*> (in :users) traversed (in :hits)) inc data)

;; rewrite: mechanical, reviewable codemods — rules are ordinary data
(defrule nil-check (= ?x nil) => (nil? ?x))
(apply-rules [nil-check] form)
```

Composition is outside-in: `(*> outer inner)` reads as a path, the
same direction as `get-in`. The lens laws (get-put, put-get, put-put)
are asserted on every primitive, because a "lens" that fails them is
just a pair of functions with pretensions. `apply-rules` runs to a
fixed point but is **bounded** — two rules that undo each other raise
rather than hang.

Neither needed a single compiler change, which is the useful part: it
means the language is now expressive enough to grow in itself. The
project's own test framework (`priv/test.bl`) and dispatch library
(`priv/multi.bl`) are written this way too.

## Objects, when you want them

`defrecord` compiles to a **real Elixir struct**, so Clojure's
equality rule falls out of `Kernel.==` for free — same type and value
equal, different types never equal, and a record is never equal to a
plain map with the same entries. Elixir interop, `inspect` and
pattern matching all work with no translation layer:

```clojure
(defrecord Point [x y]
  Shape
  (area [this] (* (:x this) (:y this))))

(->Point 3 4)          ;=> #app/Point{:x 3, :y 4}
(:x (->Point 3 4))     ;=> 3 — a record is a map
(area (->Point 3 4))   ;=> 12 — protocols dispatch on it
```

`deftype` is deliberately **not** a struct — it is a tagged tuple.
Clojure's `deftype` has no map semantics, and on this VM a struct
satisfies `is_map`, so making it one would have invited the bug class
that has caused about a third of this project's bugs. As a tuple it
cannot be swallowed by a map clause at all.

## Relationship to jank

Same language family, different host. jank : C++ interop ::
beam-lisp : Elixir interop. jank ships its stdlib as `core.jank` —
Clojure source — so "is beam-lisp really the same language?" does not
have to be an opinion. It can be a test.

`test/fixtures/jank/` holds **120 blocks** of jank's `core.jank`,
vendored byte-for-byte from upstream commit `3028594`, each carrying
a sha256 that the test suite asserts — so making a slice pass by
editing it would fail the build rather than quietly inflate the
claim. **89 of 120 load and behave correctly**, called with upstream's
own docstring examples: the threading macros, `if-let`, `doseq`,
`doto`, `memoize`, `comp`, `juxt`, `partial`, `trampoline`, `keys`,
`vals`, `group-by`, `frequencies`, `cond->`, `as->`, `some->`, `set`,
`distinct`, `sort-by`, `merge-with`, `flatten`, `condp` and more —
jank's own code, unmodified, on the BEAM:

```console
$ mix beam_lisp.run examples/jank_slice.bl   # unmodified jank, running on the BEAM
$ mix beam_lisp.run examples/threading.bl    # upstream ->, ->>, doto
```

`docs/jank-compat.md` is the measurement: every slice with its
verdict, every failure classified, and a build-next list ranked by
how many slices each gap unlocks. The score has moved **7 → 13 → 21
→ 36 → 38 → 62** across eight waves, each aimed by that list — and
the dip is deliberate: once a 21-slice sample passed completely it
had stopped being informative, so the sample tripled to 64 and the
score fell before climbing again.

The two that remain are named exactly. `for` needs a rest argument
that is itself a destructuring pattern; `with-open` is an upstream
TODO stub whose body is commented out, so it throws by construction
and cannot pass anywhere, including in jank.

The most valuable output has been the bugs. Running real upstream
code found eight defects beam-lisp's own suite did not:

- `~@` could not splice a vector, only a list
- `get` on a vector returned the default — a vector is a struct, a
  struct is a map, and the map clause matched first
- `count` on a lazy sequence returned 3 for every length, that being
  its number of struct fields
- `next` returned an unforced tail, so an exhausted lazy sequence was
  truthy and every `(when (next s) …)` recursion failed to terminate
- an exhausted `& rest` bound an empty collection instead of nil,
  which made `assoc-in` and `update-in` **hang** rather than fail
- `(<= 1 2)` linked to `:erlang."<="`, which does not exist — Erlang
  spells it `=<`, and only the two-argument form was affected
- a `lazy-seq` body returning a bare collection crashed the seq walk
- `Inspect` on a lazy sequence crashed the formatter, so a lazy value
  could not be printed at all, including inside a failure message

Two failed silently and one hung. Each was fixed at the root. That
is the argument for measuring against someone else's code: your own
tests encode your own assumptions.

What it does *not* prove: the slices were chosen as reachable
candidates, and the band of `core.jank` built on jank's `cpp/*`
runtime interop is barely touched.

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
$ mix beam_lisp.run examples/errors.bl    # try/catch/finally, throw, ex-info
$ mix beam_lisp.run examples/atoms.bl     # atoms, futures, promises across processes
$ mix beam_lisp.run examples/destructuring.bl  # map destructuring, docstrings
$ mix beam_lisp.run examples/hygiene.bl    # auto-gensym: macros that can't capture
$ mix beam_lisp.run examples/vectors.bl    # persistent trie vectors at scale
$ mix beam_lisp.run examples/testing.bl    # deftest/is/run-tests in beam-lisp
$ mix beam_lisp.run examples/multimethods.bl # open dispatch, extended after the fact
$ mix beam_lisp.run examples/protocols.bl  # defprotocol/extend-type
$ mix beam_lisp.run examples/lazy.bl       # infinite sequences, realized once
$ mix beam_lisp.run examples/fnlit.bl      # #() fn literals
$ mix beam_lisp.run examples/jank_slice.bl # unmodified jank core.jank on the BEAM
$ mix beam_lisp.run examples/threading.bl  # upstream ->, ->>, doto
$ mix beam_lisp.run examples/transients.bl # transient build, and what it costs
$ mix beam_lisp.run examples/sets.bl       # sets: membership, conj/disj, distinctness
$ mix beam_lisp.run examples/server.bl     # a real gen_server, written in beam-lisp
$ mix beam_lisp.run examples/supervision.bl # a crash, and OTP putting it back
$ mix beam_lisp.run examples/hotswap.bl    # code replaced in a running process
$ mix beam_lisp.run examples/optics.bl     # lenses and traversals, written in beam-lisp
$ mix beam_lisp.run examples/rewrite.bl    # a codemod as data
$ mix beam_lisp.run examples/records.bl    # records, types, and inline protocols
$ mix beam_lisp.run examples/bench.bl     # what var linking buys (~70× on hot loops)
```

`processes.bl` is the point of the whole project in one file:
`Task/async` takes a beam-lisp `(fn [] …)` because that fn *is* an
Elixir fun — two million-iteration loops run as real BEAM processes,
concurrently, with `Task/await` joining them.

## Development

```console
$ mix test     # 624 tests: reader, compiler, prelude, vectors, sets, macros, namespaces, dispatch, lazy seqs, transients, AOT, jank fidelity, examples
$ mix beam_lisp.test  # beam-lisp's own suite, written in beam-lisp
$ mix compile.beam_lisp  # .bl sources to real .beam modules
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
lib/beam_lisp/link.ex       defn → per-ns module fns, call-site linking
lib/beam_lisp/loader.ex     namespace file loading
lib/beam_lisp/vector.ex     the persistent vector type
lib/beam_lisp/rt.ex         primitives seeded into core
lib/beam_lisp/dev_server.ex dev-only Tidewave MCP endpoint (:9837)
priv/core.bl                self-hosted prelude, jank-flavored
examples/                   executable documentation
```
