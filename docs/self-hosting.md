# Self-hosting beam-lisp

Beam Lisp is a Lisp on the BEAM, Erlang's virtual machine. Its reader, compiler,
build tools and runtime hosts are written in Beam Lisp. You edit `.bl` files to
change the language; the repository needs no authored `.ex` or `.exs` files.

## Follow one form

```text
text → reader forms → bl-ANF → Core Erlang → BEAM bytecode
```

| Step | Source | Job |
|---|---|---|
| Read | `priv/boot/reader.bl` | Turn text into data |
| Compile | `priv/boot/compiler.bl` | Resolve names and produce bl-ANF |
| Lower | `priv/boot/lower.bl` | Turn bl-ANF into Core Erlang |
| Emit | Erlang's `:compile.forms` | Produce `.beam` bytecode |

**bl-ANF is the shared middle.** Type, effect, linearity and SMT tools inspect
this same representation. They can see every function clause and its guards.
An unknown effect or return type stays unknown; it is not permission to optimize.

## Start with a seed

A compiler needs a compiler to build itself. The starting compiler is the
checked-in bytecode in `priv/bootstrap/seed/`.

The seed manifest records module hashes, source identity and generation keys.
Bootstrap verifies those bytes before installing them. The pinned host modules
keep their exact host names, such as `BeamLisp.Reader`, while their implementation
comes from `priv/host/*.bl`.

Erlang/OTP supplies the VM and final code generator. External Elixir libraries
and host API compatibility are available without making Elixir source the
language's implementation. Rust NIFs provide selected native mechanisms, such as
shared lazy memo storage.

## Load only what is used

An aliased require declares where a name comes from:

```clojure
(ns demo (:require [some.library :as lib]))
```

The provider initializes when a call, var access, macro expansion or protocol
extension needs it. Bare requires and `:refer :all` initialize eagerly because
their effects or complete bindings are needed immediately. A direct namespace
entry in a cold packaged VM establishes the runtime before reading its registry.

Captured search roots keep deferred names tied to the project that declared
them. Live rebinding, hot reload and per-environment vars remain visible.

## Rebuild the right units

An ordinary dependency body edit rebuilds that dependency. An interface edit
also rebuilds consumers. Macro provider and helper changes conservatively
invalidate expansion-dependent consumers. Compiler generation changes require
a coherent toolchain image and seed.

From the repository's declared build roots:

```sh
bin/bl build
bin/bl seed
bin/bl seed --check --ebin "$PWD/build"
```

The native build driver owns a complete inventory in full mode. Runtime repair
uses scoped mode so it can refresh needed units without deleting unrelated
artifacts. Publication replaces files with fresh inodes to protect shared cache
hardlinks.

## Ship the same language

`bl self-build` rebuilds the declared tiers and packs bytecode, source, the seed,
the VM and native libraries into a compound executable. A source checkout needs
a stock launcher supplied with `--bin`; a running drop can re-seal its launcher.

A useful release check has three parts: compare packaged floor and native bytes,
run it outside the source tree, and test strict startup. Focused passing tests
are evidence for their features, not a claim that every repository suite passes.

Continue with the [runnable compiler tour](self/the-language-compiles-itself.bl.md),
[namespace loading](namespace-loading.md), and
[lazy values](memory-policy/shared-lazy-values.bl.md).
