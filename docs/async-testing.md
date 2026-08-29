# Async tests for your beam-lisp app

Your tests are beam-lisp. `deftest`, `is`, plain namespaces — and now they
run on all cores, each file in its own sandboxed environment, with warm and
cold runtime state as a one-flag choice. Practical guide to PLAN-046.

## The 60-second version

`test/my/app-test.bl`:

```clojure
(ns my.app-test
  (:require [my.app :as app]))

(deftest greet
  (is (= "hello, world" (app/greet "world"))))

(deftest greet-default
  (is (= "hello, friend" (app/greet))))
```

```console
$ mix beam_lisp.test --async test/my
```

Every FILE gets its own environment — a private fork of the runtime — and
files run concurrently. Totals are identical to serial; wall-clock becomes
the slowest file instead of the sum of files.

## What "its own environment" means

beam-lisp keeps all namespace state (vars, aliases, refers, metadata) in
one VM-global table. That's why suites used to be serialized: two files
defining the same var would overwrite each other mid-run.

An environment is a key prefix on that table, bound to the process running
your test file. Reads fall through a chain — your env → warm base →
`:global` prelude; writes land in YOUR env only:

```clojure
(deftest redefining-is-private
  ; `def` here shadows `my.app/greet` in this file's env ONLY.
  ; Every other file sees the original, concurrently, for free.
  (def greet (fn [_] "stubbed"))
  (is (= "stubbed" (greet "anything"))))
```

After the file finishes, the env is destroyed. Nothing leaks. `deftest` in
the next file starts from the same pristine warm base as everything else.

## Warm vs cold

**Warm** (default, both serial and `--async`): before running, the suite
loads the `deftest` library once into a base image; each file forks it
zero-copy (~40µs) and loads its own `:require`s on top.

**Cold**: don't preload anything. A file that exists to exercise the
LOADER or the compiler shouldn't inherit other files' state — just don't
share a base. Each file's env starts from `:global` + the prelude, and
`(require …)` inside it is the whole world it sees. Cold is cheap now:
the AOT cache (FEAT-002) makes compiled namespaces millisecond-scale, and
the compile-speed fix (PLAN-006) does the same for source evaluation.

Rule of thumb: warm for behavior tests, cold for machinery tests.

## Downstream: relay does this

```console
$ BL_ASYNC=1 .local/bltest          # every *-test.bl concurrently
```

Measured on the pure subset (wire/dialect/request): 9.7s → 3.2s wall,
identical totals (28 tests, 87 assertions).

## The one rule: processes

Env bindings live in the process dictionary and do NOT cross
`spawn`/`Task.async` by themselves. bl's own spawning is covered —
`(future …)` and `(promise)` carry your env into their worker
automatically, so this just works inside a sandboxed file:

```clojure
(deftest futures-see-my-env
  (def helper (fn [x] (* x 2)))
  (is (= 42 @(future (helper 21)))))   ; the future's process sees `helper`
```

If you interop to HOST Elixir that spawns a process to run bl code, that
code must opt in — `BeamLisp.Env.capture/0` in the caller, `bind/1` in the
spawned process. A spawn that skips this lands in `:global`: reads miss
your file's defs, writes leak into the shared env.

## What stays global

Deliberately VM-global; two files redefining the same entity concurrently
WILL clash — pick unique names:

- `deftype` / `defrecord` modules (created once, VM-wide)
- `native` host modules
- the lazy-seq realization cache

And app singletons stay app singletons: a named Agent/GenServer your bl
code starts is ONE process serving all envs. If it *applies bl functions
inside its own process* (e.g. `datom-conn-registry`), those functions run
at `:global` and won't see your env — FUP-009 tracks fixing that pattern.
Until then, suites exercising such singletons stay serial.

## Sandboxing the sandbox: per-env capabilities

An env can also carry RIGHTS, not just state: which host modules its code
may call. Fork with `caps:` to narrow them — a test that should be pure
gets an env that structurally cannot touch the filesystem:

```elixir
env = BeamLisp.Env.fork(:global, caps: [String])   # ONLY String interop
BeamLisp.Env.with_env(env, fn ->
  BeamLisp.eval(~s|(ns t) (File/read "/etc/passwd")|)
  # ** CompileError: module File is not granted in this environment
end)
```

Attenuation is structural — a fork's caps are `parent ∩ spec`, never more
(the same monotonic-weakening invariant as the auth package's Biscuit
tokens, one level down). Static calls are rejected at COMPILE time (denied
code never becomes bytecode); dynamic handles are checked at invocation;
`defnative` is unavailable in any capped env. `:global` holds `:all`, so
nothing existing changes. Hot path: 28–42ns per check.

See `test/beam_lisp/caps_test.exs` — the deny-corpus that keeps every
escape spelling failing closed.

### Tokens drive the fork — and the audit, and the rows

`auth/caps-for` and `auth/sandbox-fork` close the loop: a Biscuit token's
`right($module, $op)` facts authorize, project to caps, and fork in one
call. W6 adds the two consequences of "everything is data":

```clojure
;; the DECISION is a row — allow AND deny, with reason, operation,
;; resource, and tx-time. "What was this token allowed to do, when?"
;; is a datalog query over history:
(auth/sandbox-fork-audited root-pub token ctx :global audit-conn)
;; => {:ok env :report tx-report} | {:error verdict :report tx-report}

;; ONE token, two enforcement points: the (user $p) fact that identifies
;; the bearer also scopes their queries. verified-facts refuses a forgery
;; — no query is ever scoped by fiction:
(auth/owner-scope root-pub token '?doc :doc/owner)
;; => {:ok [[?doc :doc/owner "alice"]]} — ready for auth/guard
```

See `test/bl/auth/audit_test.bl` — the use cases, green.

## Debugging resolution surprises

"Why did this var resolve to THAT?" Ask the chain, from IEx or a failing
test's process:

```elixir
BeamLisp.Env.explain("my.app", "greet")
# [%{env: this-file, found: true}, %{env: warm-base, found: true}, …]
```

## Host-side tests (the escape hatch)

Sometimes the test subject is Elixir orchestrating bl — then ExUnitCase
gives you the same semantics in `*_test.exs`:

```console
$ mix beam_lisp.gen.case MyApp.BlCase --warm my.app my.app.more
```

```elixir
defmodule MyApp.ServerTest do
  use MyApp.BlCase    # async: true, private env fork per test
end
```

`mix beam_lisp.test.doctor` audits an existing `*_test.exs` tree and marks
each file ADOPTS / READY / FLIPPABLE / STAYS SYNC, with reasons. Reach for
this when testing the host; reach for `*-test.bl` when testing the app.

## Measured costs (this repo, this machine)

| operation | cost |
|---|---|
| var fetch at `:global` | ~1.2µs (≈+10% vs pre-envs) |
| fetch in a fork, falls through to base | ~2.7µs |
| env checkout + checkin | ~40–60µs per file/test |
| relay bl subset, serial → async | 9.7s → 3.2s (3.0×) |
| beam-lisp bl files, serial → async | 8.9s → 7.2s runner-internal — at the critical-path floor (prelude_test.bl alone is 80% of the suite; split it to win more) |

The pattern: async converts suite wall-clock from the SUM of files to the
MAX of files. Uniform files win big; a suite dominated by one giant file
wins only when that file is split.
