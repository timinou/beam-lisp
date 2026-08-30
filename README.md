# beam-lisp

> This README was written by a human.

Welcome to Beam Lisp! Beam Lisp is a language built for the generative era.

## Intro

### In short

In Beam Lisp, the language *is* the harness, and the harness *is* the runtime, and the runtime *is* the application.

That is:
- Beam Lisp

### Origin

Beam Lisp is the backend half of an experiment I started running over three years ago: **what if software could be a blank canvas?**. I needed to make a language that:

1. *Can introspect itself 100,000%*: no-one likes when agents confidently tell you work is done but they just messed it up even more. Beam Lisp can understand the implicit contract behind working code, and make sure new versions don't break the contract (or, if they do, that they explain how we're moving from the old to the new contract).
2. *Solves concurrency*: Most programming languages are written with the assumption that you have a list of instructions to run *one by one*. In today's world, where web apps serve thousands and agents build social networks with each other unprompted, that assumption of *linear execution* doesn't hold. Most of our prod apps will be *concurrent*, meaning the list of instructions may change mid-way through the program. I bow down to José Valim's work with Elixir, and the amazing team maintaining BEAM, for building platforms that solve concurrency, and I'm just humbly reusing them.
3. *Is composable with itself*: The language should feel like LEGO blocks that you can compose, but also run separate from each other
4. *Is feature-complete*: Beam Lisp is opinionated. Although you *can* use any Elixir, Gleam, and Erlang package, Beam Lisp contains its own db (`datom`) and authorisation/authentication layer (`auth`), linter (`deodorant`), etc.
5. *Is alive*: in most programming languages, when you run a program, all of it is loaded to memory, is run, then exits. In Beam Lisp, you have a runtime in which you keep adding code. That lets you (and agents) experiment so much more smoothly, and let you understand exactly what's happening both when things are going well and when they are not.

Beam Lisp is all of that.


### Shoutouts

With Beam Lisp, you get:
- **the sturdiness of the BEAM**: Ever wondered how the engineers at Discord, WhatsApp, and at most telecom companies sleep at night? The BEAM is the answer! It's the infrastructure behind several languages (Erlang, Elixir, and Gleam are the most well-known ones).
- **the wisdom of Clojure**: Go type "Rich Hickey" on Youtube and listen to a couple of his talks. You can feel his thoughtfulness in the way he's designed Clojure. Clojure is the purest description of computer logic, done so cleanly that simple building blocks let you design arbitrarily grandiose codebases.
- **the friendliness of Elm**: though you won't see Elm in the syntax, Beam Lisp uses total type inference (and logic solvers) to be more helpful to humans and agents alike.

Use it to build applications that are safe, scalable, and whose complexity stays in check as you grow.

## Composable experiences

### Literate programming

In Beam Lisp (TODO), you can write `.bl.md` files first-party (and also TODO `.bl.org` files if we share that nerdiness). This is like having a text version of a Jupyter notebook, where you can lay out the code by sections so there is a narrative to your work.

Now, most of those won't be written by us, but by generative AI. Enabling it to write code that way makes your code *self-documenting*, which makes building upon it easier, and reduces the risk of drift when docs, examples, and code are in three different paths.

You can see that for yourself by going to (TODO) (TODO 2: instead of the github link to .bl.md, it's the generated docs website))

It also makes it a lot more fun to prototype. (TODO When you do `bl watch <file-or-folder>`, you can save and then (a) places that make sense to modify are given IDs and re-saved fast, and there is a generation or sth, and then it re-saves in those IDs. This is the blessed way to run Obsidian)




## Mindblowers

### The database is the LSP runner
