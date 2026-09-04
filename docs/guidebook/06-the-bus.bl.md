# 06 — The bus: one stream, many speeds

*A guidebook chapter for readers new to beam-lisp. Reads after the registry chapter.*

---

## Push and pull

A push producer decides when the next event moves. If consumers are slower, events collect in memory or disappear. A queue can postpone the problem, but its size is still a guess.

A pull consumer decides when the next event moves. It sends demand — “I can accept four more” — and the producer sends no more than four. That rule is **backpressure**. A slow consumer asks less often, so work slows before memory grows without bound.

`flow` uses four messages:

```clojure
[:subscribe consumer-pid]
[:demand 4 consumer-pid]
[:events [a b c d]]
[:done]
```

Demand carries the consumer pid because a bus serves many consumers from one mailbox. Ordinary flow producers also accept the older untagged `[:demand 4]` form.

## Fan-out changes the question

A pipeline has one downstream pace. A bus has one pace per subscriber. The ledger may process every payment immediately while an email service pauses. One must not silently change the other’s demand.

```clojure
(ns payments
  (:require [bus :as bus]
            [flow :as flow]))

(bus/defbus payments (demand 16))

(def b (start payments {}))

(flow/subscribe b :ledger ledger/record!
                {:demand 16 :on-lag :block})
(flow/subscribe b :mail email/send!
                {:demand 4 :on-lag :drop-oldest :max-lag 128})

(bus/publish b {:type :paid :amount 42})
(stop b)
```

Each subscription is a small consumer process. It subscribes, requests a batch, handles that batch, then requests another. A function is called once per event. A pid receives `[:events events]` and finally `[:done]`, which lets a flow stage or another process continue the protocol.

`stop` is End-of-Stream, not a silent disappearance. The bus sends `[:done]` to every live subscriber before it terminates.

## Lag is a policy decision

Every subscriber has a private queue. `:max-lag` bounds it; the default is 1024 events. When a subscriber reaches that bound, choose the meaning that fits the data:

| policy | meaning | use it when |
|---|---|---|
| `:block` | wait until that subscriber asks for more | every event matters and slowing the publisher is correct |
| `:drop-oldest` | discard old queued events, keep the newest | current state matters more than history: gauges, cursor positions, dashboards |
| `:detach` | unsubscribe the lagging consumer and publish `{:type :lagged :subscriber id}` | partial delivery is unsafe and another process should reconnect or alert |

`:block` is the default. `bus/publish` is a call rather than fire-and-forget: when a blocking subscriber is full, the call waits. That is how backpressure reaches the publishing process instead of merely moving growth into the bus mailbox. Do not use `cast` to publish when this guarantee matters.

A dead subscriber cannot hold the bus forever. The bus monitors every subscription. Its `:DOWN` message removes the subscriber and releases any publisher waiting on that subscriber’s demand.

## Broadcasting an existing flow

`flow/broadcast` turns any producer into a bus:

```clojure
(def source (flow/from-seq (range 1 101)))
(def b (flow/broadcast source {:demand 8 :max-lag 32}))

(flow/subscribe b :sum add-to-total {:demand 8 :on-lag :block})
(flow/subscribe b :screen redraw {:demand 1 :on-lag :drop-oldest})
```

The bridge speaks the same subscribe, demand, events, and done protocol. The source remains pull-driven. When the source sends `[:done]`, the bridge stops the bus, and the bus forwards completion to all subscribers.

## A worked choice

Suppose a temperature sensor publishes ten readings each second:

- An audit writer uses `:block`. Missing one reading breaks the record, so the sensor-facing publisher must slow down.
- A display uses `:drop-oldest`. Showing an old temperature after a pause is worse than skipping it.
- A billing calculator uses `:detach`. A gap makes its result invalid, so it disconnects and reacts to the `:lagged` event instead of pretending its history is complete.

The policies do not make one subscriber globally “slow.” They state what lag means at each boundary.

Run the repository example:

```sh
mix beam_lisp.run --path priv examples/bus.bl
```

It publishes twenty values to a fast blocking subscriber and a deliberately slow drop-oldest subscriber. The assertions prove that the fast subscriber sees all twenty, the slow subscriber drops older values, and both finish through End-of-Stream.

## Exercises

1. Change the slow subscriber to `:block`. Measure how long publishing twenty events takes.
2. Change it to `:detach` and print the `:lagged` event received by the remaining subscriber.
3. Kill a subscriber while a publisher is blocked. Confirm that monitoring removes it and publishing continues.
4. Build a `flow/from-seq` source, broadcast it, and attach consumers with demand sizes 1 and 10. Compare their batches without changing the source.

---

*Next: [07 — the supervisor](07-the-supervisor.bl.md): linking processes into a service that heals after failure.*
