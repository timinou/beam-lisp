# The fence

A function call normally runs in the caller's process. If that call crashes, the caller crashes too. If it never returns, the caller waits forever.

A fence changes that boundary. It runs one computation in a monitored child process and turns the child's fate into data:

```clojure
{:ok value}
{:crash reason}
{:timeout true}
```

This combines two patterns:

- **Bounded Isolation** — a crash is contained in a child process and reported to its caller.
- **Timeout Edge** — waiting is an explicit, finite edge in the process graph.

The timeout map uses `true` because beam-lisp map literals contain key/value pairs. Test it with `(contains? result :timeout)` when only the outcome kind matters.

## Syntax

Load the standard namespace and wrap an expression:

```clojure
(ns my.app
  (:require [fence :refer :all]))

(fence 200 (risky-work))
(fence {:ms 200 :kill? true} (risky-work))
```

A number is shorthand for `{:ms number}`. `:kill?` defaults to `true`, which exits a child that exceeds the deadline. Set it to `false` only when the child is intentionally allowed to continue after the caller stops waiting.

`fence` is a macro: it wraps its body in a zero-argument function. Use `fence-fn` when the computation is already a function:

```clojure
(fence-fn 200 (fn [] (risky-work)))
(fence-fn {:ms 200 :kill? true} thunk)
```

## A complete example

```clojure
(ns examples.fence
  (:require [fence :refer :all]))

(def ok-result
  (fence 200 (+ 20 22)))

(def crash-result
  (fence {:ms 200} (throw :boom)))

(def timeout-result
  (fence 20 (Process/sleep 200)))

(println (pr-str ok-result))       ; {:ok 42}
(println (pr-str crash-result))    ; {:crash reason}
(println (pr-str timeout-result))  ; {:timeout true}
```

Run the repository example:

```sh
mix beam_lisp.run --path priv examples/fence.bl
```

The fence monitors rather than links the child. A linked child's failure would propagate to the caller; a monitor instead delivers a `:DOWN` signal. The implementation correlates replies with the child pid and monitor reference, then removes the monitor with `:flush` on success, crash, and timeout. Unrelated mailbox messages remain untouched, and no late `:DOWN` message leaks into later receives.

## Exercises

1. Fence a function that returns after 10 ms with a 100 ms deadline.
2. Lower the deadline until the same function returns `{:timeout true}`.
3. Compare `:kill? true` and `:kill? false` using a child that sends a message after the fence has timed out.
4. Put three thunks in a collection and evaluate `(map #(fence-fn 50 %) thunks)`. Force the lazy result with `vec` before inspecting it.

## Next reading

Read `examples/processes.bl` for spawning and `examples/supervision.bl` for long-lived process recovery. A fence is for one bounded computation; supervision is for a service that should be restarted and kept alive.
