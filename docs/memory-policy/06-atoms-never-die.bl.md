# Atoms never die

Every other value on the BEAM is collected when nothing refers to it. An atom
is not. The atom table holds every atom ever created, forever, and when it
fills (1 048 576 entries by default) the VM does not raise — it **aborts**,
uncatchably, with a crash dump. There is no per-process bound that helps,
because the table is global.

So the one memory question with no runtime answer is: *can an untrusted input
make this program create atoms?* The two ways it can are both function calls
with a name — `String/to_atom`, `keyword` — applied to a value that came from
outside. beam-lisp's call graph knows where every call is, and its trust
boundary (`docs/trust-boundary.md`) knows where outside begins.

## The facts that exist

`codebase` holds `:call/caller`, `:call/callee`, `:call/line` for every call
site and a `reaches` rule for transitive reachability. The entry points where
untrusted data arrives are already named: `web` handlers, `executor` sandbox
entry, `datom` transact from a remote, `wry` messages from the webview. The
runtime belt is `BeamLisp.AtomGuard`, which samples the table and refuses to
intern past a high-water mark — an alarm, not a quota, by its own description.

## The policy

```clojure
(ns memory.atoms
  (:require [codebase] [datom]))

;; the interning ops — the ONLY ways bl source creates an atom from a value
(def interning-ops #{"String/to_atom" "keyword" "symbol" "erlang/binary_to_atom"
                     "erlang/list_to_atom"})

;; the untrusted entries — where a value crosses the trust boundary inward
(def entry-points #{"web/handle" "executor/run" "wry/on-message" "datom/transact-remote!"})

(def reachable-interning
  "An interning op reachable from an untrusted entry along the call graph.
   `reaches` is codebase's shipped transitive-closure rule."
  '[:find ?entry ?fn ?line
    :where [(contains? memory.atoms/entry-points ?entry)]
           (reaches ?entry ?fn)
           [?c :call/caller ?fn] [?c :call/callee ?op] [?c :call/line ?line]
           [(contains? memory.atoms/interning-ops ?op)]])

(defn report [db]
  (datom/q reachable-interning db))
```

Reachability is the sound over-approximation: a `keyword` call in a function
reachable from a web handler is flagged even if, on every path, its argument is
a literal. Two refinements shrink the false positives without losing soundness:

- **Literal arguments are safe.** `typed` knows when a call's argument is a
  literal string; those calls are excluded. `(keyword "status")` is fine
  anywhere.
- **`existing` variants are safe.** `String/to_existing_atom` and
  `erlang/binary_to_existing_atom` raise instead of interning, so they are
  not in `interning-ops`. The fix the report suggests is usually to switch to
  one of them.

## What the author sees

A lint, at compile time:

```
memory.atoms: web/handle-json → parse-key → (keyword k) at parse.bl:41
              interns an atom from request input. Use to-existing-atom, or
              keep the key as a string.
```

At run time, `AtomGuard` stays as the belt: a program the lint could not see
(generated source, a NIF, an Elixir dependency) still hits the high-water
alarm before the VM dies.

## Speed · quality · provability

**Speed.** None. Atoms are not a performance question; they are a survival
question.

**Quality.** The one resource the VM cannot reclaim is now guarded at both
ends: statically, by name and line, at the site that interns; dynamically, by
the sampled alarm. Neither substitutes for the other, and the lint is the one
that fires before deploy.

**Provability.** Trivially sound over the call graph `codebase` already
indexes. Entry points are a declared set, so a new boundary — a new transport
in `executor`, a new `web` verb — is one line in `entry-points`. Nothing in
any `.bl` file becomes harder to prove; every file gains the check.

## Where it lives

- `codebase` — `:call/*` facts and the `reaches` rule.
- `docs/trust-boundary.md` — where the entry points are defined.
- `BeamLisp.AtomGuard` — the runtime belt.
- `memory.atoms` (to build) — the interning set, the entry set, the query.
