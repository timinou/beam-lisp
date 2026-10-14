# beam-lisp

> This README was written by a human.

Welcome to Beam Lisp! Beam Lisp is a language built for the generative era.

## Intro

### In short

#### If you're into developing software

Beam Lisp provides you the reliability of the BEAM (what WhatsApp and half the world's telecoms use) with the excellent design of Clojure, and the correctness of an SMT solver checking the validity of the program at compile time.

Beam Lisp comes with a rather hefty standard library and is very (very) opinionated. For example, Beam Lisp comes with its own database modelled after the Datomic model and does not support SQL (though you can call Ecto or another Elixir/BEAM SQL library).

Beam Lisp compiles to the BEAM and to Javascript, dispatching code safely (see the `split` module).


#### If you're into AI and convoluted arcane speech

In Beam Lisp, the language *is* the harness, and the harness *is* the runtime, and the runtime *is* the application.

- The harness is a module like regex is a module. You can integrate a harness to any Beam Lisp app with minimal changes
- 'Tool calls' are not really a thing---harness-like applications in Beam Lisp simply run Beam Lisp code
- All Beam Lisp applications live inside a single virtual machine and are loaded into sandboxed environments. That means interoperability isn't 'I load a script into an app', it's 'I communicate between modules.'


### Origin

Beam Lisp is the backend half of an experiment I started running over three years ago: **what if software could be a blank canvas?**. I needed to make a language that:

1. *Can introspect itself 100,000%*: no-one likes when agents confidently tell you work is done but they just messed it up even more. Beam Lisp can understand the implicit contract behind working code, and make sure new versions don't break the contract (or, if they do, that they explain how we're moving from the old to the new contract).
2. *Solves concurrency*: Most programming languages are written with the assumption that you have a list of instructions to run *one by one*. In today's world, where web apps serve thousands and agents build social networks with each other unprompted, that assumption of *linear execution* doesn't hold. Most of our prod apps will be *concurrent*, meaning the list of instructions may change mid-way through the program. I bow down to José Valim's work with Elixir, and the amazing team maintaining BEAM, for building platforms that solve concurrency, and I'm just humbly reusing them.
3. *Is composable with itself*: The language should feel like LEGO blocks that you can compose, but also run separate from each other
4. *Is feature-complete*: Beam Lisp is opinionated. Although you *can* use any Elixir, Gleam, and Erlang package, Beam Lisp contains its own db (`datom`) and authorisation/authentication layer (`auth`), linter (`deodorant`), etc.
5. *Is alive*: in most programming languages, when you run a program, all of it is loaded to memory, is run, then exits. In Beam Lisp, you have a runtime in which you keep adding code. That lets you (and agents) experiment so much more smoothly, and let you understand exactly what's happening both when things are going well and when they are not.

Beam Lisp is all of that.

#### History

Lisp was a mathematical formalism for writing algorithms, especially symbolic AI algorithms. Lisp was written when compilers where *humans*, and the first Lisp files were literal punch cards.

Lisp represents what exists in most languages as abstract syntax trees (AST): the data representation that a compiler then turns into computer instructions. In Lisp, the code and the data representation of the code are one and the same.

This makes one thing particularly easy: loading code into a running program. In lisps, you don't execute a script, you start a virtual machine and load code onto it. This is particularly useful for agents because they can write and test code much closer to the work they're doing. 

In the generative era, this lack of distinction is powerful.
- Ever stuck in a loop where code takes a single turn to write, but hours to test? With Beam Lisp, harnesses can make encapsulated light prototypes and test them without having to sideload the whole system every time.
- When something goes wrong, agents can poke into the running system directly.


### Shoutouts

With Beam Lisp, you get:
- **the sturdiness of the BEAM**: Ever wondered how the engineers at Discord, WhatsApp, and at most telecom companies sleep at night? The BEAM is the answer! It's the infrastructure behind several languages (Erlang, Elixir, and Gleam are the most well-known ones).
- **the wisdom of Clojure**: Go type "Rich Hickey" on Youtube and listen to a couple of his talks. You can feel his thoughtfulness in the way he's designed Clojure. Clojure is the purest description of computer logic, done so cleanly that simple building blocks let you design arbitrarily grandiose codebases.
- **the friendliness of Elm**: though you won't see Elm in the syntax, it's my love language, back in the old days of hand-coding. Its focus on correctness and simplicity drives a lot of my design decisions. For example, Beam Lisp uses total type inference (and logic solvers) to be more helpful to humans and agents alike.

### What it's for

Use this language to build applications that are safe, scalable, and whose complexity stays in check as you grow.

Use it to build generative applications. beyond chats and agents. Make interfaces that extend the range of what's possible.

## Getting started

Download the latest `bl` release from your platform and put it in an executable place. Run `bl doctor` to check that all works well. Then use `bl run ...` for running files (try the examples), or `bl`, or point your agent to this repo and the binary, and let it run wild.

Also you can use `bl repl` if you want to get your hands dirty.

## Composable experiences

### Literate programming

In Beam Lisp, you can write `.bl.md` files first-party (and also TODO `.bl.org` files if we share that nerdiness). This is like having a text version of a Jupyter notebook, where you can lay out the code by sections so there is a narrative to your work.

Now, most of those won't be written by us, but by generative AI. Enabling it to write code that way makes your code *self-documenting*, which makes building upon it easier, and reduces the risk of drift when docs, examples, and code are in three different paths.

You can see that for yourself by going to any file that ends in `.bl.md` or `.bl.org` in this repo.

It also makes it a lot more fun to prototype. (TODO When you do `bl watch <file-or-folder>`, you can save and then (a) places that make sense to modify are given IDs and re-saved fast, and there is a generation or sth, and then it re-saves in those IDs. This is the blessed way to run Obsidian)

Notably, `.bl.md` and `.bl.org` is the blessed way that LLMs generate agentic code: by appending to a literate programming file.




## Mindblowers

### Real Babashka/Clojure stdlib runs on the BEAM

Look up the `clojure.*` namespaces, some of them run modified on the BEAM.

Although Beam Lisp isn't intended to be a 'Clojure on the BEAM' (no hard desire to make a comprehensive JVM compat shim), it can still run much of Babashka's supported subset of Clojure.

### Mathematical formalism for concurrent systems

The `proc` namespace family represents a library of patterns for building concurrent systems that subsume the need for many packages you'd have to resort to in other BEAM languages.
