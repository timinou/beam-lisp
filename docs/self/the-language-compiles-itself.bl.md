# The language compiles itself

*A runnable tour. Every code cell below is real beam-lisp; the document loads as
the program it reads as.*

beam-lisp reads and compiles beam-lisp. The reader is `priv/boot/reader.bl`, the
compiler is `priv/boot/compiler.bl`, and the backend that turns the compiler's
output into BEAM bytecode is `priv/self/core.bl` — all of it the language, none
of it an Elixir compiler. This tour shows the pieces working, from the outside
in.

## It just runs

The everyday surface is ordinary. You evaluate a form and get a value.

```clojure
(ns tour)

(defn sum-to [n]
  (reduce + 0 (range (+ n 1))))

(sum-to 100)   ; => 5050
```

Nothing here hints that a self-hosted compiler is underneath — which is the
point. Self-hosting is invisible when it works.

## The reader is a function you can call

Reading is just turning text into data. The reader is a normal namespace, so
you can hand it a string and see the shapes it produces.

```clojure
(require '[reader :as r])

;; a form reads as nested data — a list node whose items are symbols, a
;; vector, and nested lists. Symbols and keywords keep their spelling as data.
(r/read-all "(defn inc [x] (+ x 1))")
;; => a (:list …) whose head is (:symbol "defn"), then (:symbol "inc"),
;;    a (:vector (:symbol "x")), and the body list (+ x 1)

;; numbers and strings read as themselves; a keyword reads as keyword data
(r/read-all "42 :key \"hi\" 1e3")
;; => (42 (:keyword "key") "hi" 1000.0)
```

Those shapes are the compiler's input. Data in, data out — no magic tokens.

## The compiler is a function you can call

The compiler takes one reader form plus a compile environment and returns the
syntax tree for the code that produces the value. Call it directly:

```clojure
(require '[compiler :as c])

(let [env (c/new-env "tour")
      form (r/read-one "(+ 1 2)")]
  ;; compile returns an AST; evaluate it and you get the value back
  (c/eval-form form env))
;; => 3
```

`eval-form` compiles the form into a throwaway module and runs it — real
bytecode, so `loop`/`recur` keep tail-call optimisation instead of growing the
stack.

## From forms to Core Erlang

The compiler lowers to a small neutral IR (**bl-ANF**), and `self/core.bl` turns
that into **Core Erlang** — the BEAM's simplest real input. The whole path is
beam-lisp until the Erlang stdlib turns Core Erlang into a `.beam`:

```
text ──reader.bl──▶ forms ──compiler.bl──▶ bl-ANF ──self/core.bl──▶ Core Erlang ──▶ .beam
```

A namespace's functions become a Core Erlang module, compiled and loaded in the
same VM. That the output is byte-reproducible — the same source always yields
the same bytes — is what lets it be checked in as a boot seed.

## The seed breaks the circle

You cannot compile the compiler without a compiler. Every self-hosting language
ships a compiled artifact to start from; ours is `priv/bootstrap/seed/` — the
whole boot toolchain as Core-Erlang `.beam` files, committed to git.

At boot the language interns the seed from those bytes (no compile), and from
there it rebuilds everything. Edit `compiler.bl` and its hash changes, so the
committed seed no longer matches — that is fine: the seed is a working compiler
of the *previous* generation, and it compiles your edit into the next one. To
bless a new floor:

```
mix compile.beam_lisp
mix run priv/bootstrap/gen_manifest.exs
```

Git history holds every past seed, so there is always a floor to fall back to.

## The compiler is a program you can query

Because the compiler is beam-lisp source, the language's own tools read it like
any other program. "What calls this function?" is a database query, not a grep:

```clojure
(require '[codebase :as cb])

;; index the compiler's own source into a datom store; the result is a fact
;; database you query with datalog. "Who calls `compile-body`?" is a join over
;; the call-graph facts, not a text search.
(cb/index-source (slurp "priv/boot/compiler.bl"))
;; => a datom db of the compiler: every def, call, and arity as facts
```

The optimiser's questions are queries too: *functions called once* are inline
candidates; *functions never called* are dead code. The compiler is the first
large program the language turns on itself.

## What is still Erlang, on purpose

- The final step, Core Erlang → `.beam`, is the Erlang stdlib's own compiler.
  Reusing it is the whole idea: beam-lisp writes the missing middle, not a new
  machine-code emitter.
- The OTP host — application, supervisor, `mix` tasks — is the process that
  *runs* the language, like Clojure's JVM launcher.
- The runtime substrate (`first`, `get`, the persistent `Vector`) stays as
  fast native code the compiler leans on.

Everything about the *language* — how a form reads, how a special form lowers,
how a namespace becomes a module — is beam-lisp.

## In one line

You edit `.bl` to change the language; the seed boots it; the language compiles
itself to Core Erlang and reasons about its own source — Erlang stays only as
the code generator and the host.
