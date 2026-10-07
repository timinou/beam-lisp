# Read process outcomes

Capture `proc` diagnostics at the boundary that runs work. Fence return values
keep their existing shape. Tick diagnostics offer a bounded failure receipt.

```beam-lisp
(ns proc.diagnostics.walkthrough
  (:require [diagnostics :as diag] [proc.fence :as fence] [proc.tick :as tick]))
(def events (atom []))
(diag/with-options {:sink #(swap! events conj %)}
  (fence/fence 500 (+ 20 22)))
```

```bl-result events
{:ok 42}
```

```beam-lisp
(diag/with-options {:sink #(swap! events conj %)}
  (tick/tick-failed! :demo (ex-info "private transport details" {:kind :transport})))
(tick/tick-last-failure :demo)
```

```bl-result cell1
{:diagnostics/error-kind :transport}
```

```beam-lisp
(mapv :diagnostics/event @events)
```

```bl-result cell2
[:proc.fence/completed :proc.tick/failed]
```

For queue work, `:proc.queue/claimed` starts an attempt.
`:proc.queue/settled` reports both the worker outcome and whether its owner token
settled the stored job. `:proc.queue/claim-expired` means the tracked lease ended.
The separate `examples/diagnostics/03-queue.bl` exercises a failed worker,
structured `:job/last-failure`, an expired claim, and owner-guarded settlement with a controlled clock.

The legacy `tick-last-error` and stored `:job/last-error` contain original error text.
Read `:job/last-failure` for diagnostics; exporting an entire job exports private
payloads and legacy errors as well. Retry policy and at-least-once execution
remain queue contracts. These events provide observations of those contracts.


Fence replies use a process alias. Returning or timing out deactivates it, so a
child with `:kill? false` can finish without adding a late reply to its caller's
mailbox. Deadlines must be nonnegative integers; `:kill?` must be a boolean.

Queues persist projected diagnostic linkage at enqueue. Each claim starts a new
execution scope, shared by its worker, settlement and lease-expiry observations.
The previous server scope is restored after each event. Owner tokens continue to
control settlement; a lost claim cannot publish another worker's result.

Pipeline stage failures emit `:proc.pipeline/failed` and raise only a bounded
failure receipt. The exception excludes the input event and original exception
text. `:fail` stops a failed worker; `:requeue` retains its existing retry behavior.
Choose a queue with a finite retry limit for work that needs poison-item handling.

`examples/diagnostics/04-delivery.bl` runs a real OTP privacy filter and bounded
writer with a capture sink. `examples/diagnostics/05-pipeline.bl` runs a stage
that fails on its third item, observes the safe failure and stops its topology.
