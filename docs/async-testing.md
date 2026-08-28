# Async tests for your beam-lisp app

How to make a beam-lisp app's test suite run on all cores, with warm and
cold runtime state as a one-token choice. This is the practical guide to
PLAN-046; it assumes nothing beyond "my app has beam-lisp namespaces and
ExUnit tests".

## The 60-second version

```console
$ mix beam_lisp.gen.case MyApp.BlCase --warm my.app my.app.more
```

then in each test module:

```elixir
defmodule MyApp.GreetTest do
  use MyApp.BlCase          # async: true, private env fork per test

  test "greeting" do
    {:ok, greet} = BeamLisp.Env.fetch("my.app", "greet")
    assert BeamLisp.RT.invoke(greet, ["world"]) == "hello, world"
  end
end
```

Run `mix test`. The `Finished` line now shows nonzero async time. Done.

## What just happened

beam-lisp keeps all runtime namespace state (vars, aliases, refers,
metadata, links) in one VM-global ETS table. That is why every suite in the
ecosystem used to be `async: false`: two tests defining the same var would
write over each other.

PLAN-046 gives every test its own **environment**: a key prefix on that
same table, bound to the test's process. Reads fall through a chain
(test env → warm base → `:global` prelude); writes land in the test's env
only. A test can redefine `my.app/greet`, call it, assert on it — and the
next test sees the original, because nothing ever wrote anywhere shared.

`--warm my.app my.app.more` builds a **base image** once per VM: those
namespaces are loaded into a base env, and every test forks it — zero-copy,
~40µs, no reloading. That is the warm path.

## Warm vs cold

```elixir
use MyApp.BlCase                          # warm: forks the base image
use BeamLisp.ExUnitCase                   # cold: forks :global (prelude only)
```

A cold test loads exactly what it names:

```elixir
test "loader edge case" do
  BeamLisp.Sandbox.load_ns("my.app")          # through the loader
  BeamLisp.Sandbox.load_file("test/fixtures/odd.bl")
  BeamLisp.Sandbox.eval("(ns scratch) (def x 1)")
end
```

Cold loads are cheap: the AOT cache (FEAT-002) makes compiled namespaces
millisecond-scale, and the compile-speed fix (PLAN-006) does the same for
source evaluation. Choose cold when the test exists to exercise loading,
compiling, or namespace machinery itself; warm for everything else.

Lower level, if you ever need it: `BeamLisp.Env.isolated(fn -> … end)`
forks, binds, and destroys an env around one block.

## The one rule: process boundaries

Env bindings live in the process dictionary and do NOT cross
`spawn`/`Task.async`. beam-lisp's own spawning (`(future …)`, `(promise)`)
propagates automatically. Host Elixir code that spawns a process to run
beam-lisp work must opt in:

```elixir
token = BeamLisp.Env.capture()
spawn(fn ->
  BeamLisp.Env.bind(token)
  # … beam-lisp work, sees the caller's env …
end)
```

A spawned process that skips this lands in `:global` — reads miss vars the
test defined, writes leak into the shared env. If a test's spawn seems to
"not see" a var, this is why.

## What stays global (and what to do about it)

Three registries are deliberately VM-global; two tests redefining the same
entity concurrently WILL clash:

- `BeamLisp.Record` (defrecord/deftype modules — created once, VM-wide)
- `BeamLisp.Native` (native host modules)
- `BeamLisp.LazySeq` (realization cache)

And app-level singletons stay app-level: a named GenServer your bl code
starts (e.g. a connection registry) is one process serving all envs. If it
*applies beam-lisp functions inside its own process*, those run at
`:global` and will not see test env state. Suites that exercise such
singletons stay `async: false` with a comment naming the singleton.

Use `mix beam_lisp.test.doctor` to audit your tree — it marks each file
ADOPTS / READY / FLIPPABLE / STAYS SYNC with the reason.

## bl test suites (`*-test.bl`)

`mix beam_lisp.test --async` runs each FILE in its own fork of a warm base
(the `deftest` library preloaded), concurrently, output ordered as the
serial run's. Totals are identical to serial; wall-clock is bounded by the
slowest file, so split giant files to win more.

Same flag for downstream wrappers: relay's `.local/bltest` honors
`BL_ASYNC=1`.

## Debugging resolution surprises

"Why did this var resolve to THAT?" — the chain walk, spelled out:

```elixir
BeamLisp.Env.explain("my.app", "greet")
# [%{env: this-test, ns: "my.app", name: "greet", found: true},
#  %{env: base-image, …, found: true}, %{env: :global, …, found: false}]
```

## Measured costs (this repo, this machine)

| operation | cost |
|---|---|
| var fetch at `:global` | ~1.2µs (≈+10% vs pre-envs; the candidates walk dominates both) |
| fetch in a fork, own-env hit | ~1.6µs |
| fetch in a fork, falls through to base | ~2.7µs |
| checkout + checkin | ~40–60µs per test |
| relay bl subset, serial → async | 9.7s → 3.2s (3.0×) |
| beam-lisp bl files, serial → async | 8.9s → 7.2s runner-internal (at the critical-path floor: one file is 80% of the suite) |

The pattern: async converts suite wall-clock from the SUM of files to the
MAX of files. Uniform files win big; a suite dominated by one file wins
only when that file is split.
