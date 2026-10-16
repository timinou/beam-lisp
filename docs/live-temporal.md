# Time can change a view

Give a Live app its owned clock and a pure function for the next visible deadline:

```clojure
{:clock my-clock
 :deadline (fn [ctx]
             (next-visible-change (:worlds ctx) (:me ctx) (:now ctx)))
 :worlds guarded-worlds
 :routes routes}
```

The deadline is an absolute integer millisecond instant, or `nil`. Return the
nearest future transition represented by the current guarded view. The context
contains the captured principal, guarded worlds, route, query, locals and current
clock. App capabilities and identity stay outside browser-editable locals.

Each mounted socket owns one timer and its cancellation ticket. A native commit,
navigation or attachment rederives the deadline. A denied world, missing route or
detached transport cancels the timer. Stale ticks cannot project. Past deadlines
are already represented and do not reschedule themselves. Long waits use bounded
timer segments without rendering between segments. Session termination cancels
the timer and releases clock observation.

`connector.clock/virtual` publishes clock-change hints on both advance and
restore. `connector.clock/listen!` observes a clock in the calling process and
returns its opaque identity; `unlisten!` releases that observation. A virtual
clock projects its current value when changed and uses no elapsed-time timer.
Clock bursts coalesce into one pending projection. A system clock uses the owned
absolute deadline timer. Neither path writes application facts or invokes domain
effects. Provider and business authorization still belongs at action admission.
