# Observability — the inversion

> Conventional observability scrapes shadows of a black box into second and
> third systems. On a bl VPS the system is the dataset: you do not observe the
> machine, you *query* it — and when the query finds something, you are already
> inside the only tool you need to fix it.

## Events are datoms

A service reports by transacting:

```clojure
{:svc "blog" :event :request :lat-ms 42 :at …}
{:svc "blog" :event :restart :reason :heap-ceiling :at …}
```

No serialization into a metrics format, no cardinality budget, no second
database. The event is a fact in the same store that holds desired state,
effect history, and audit — so every question joins across all of them:

```clojure
;; p95 latency for blog, only while generation a1b2c3 was live
[:find ?lat
 :where [?e :event :request] [?e :svc "blog"] [?e :lat-ms ?lat]
        [?e :at ?t] [?g :node/generation "a1b2c3"] [?g :live-from ?t0]
        [(>= ?t ?t0)]]
```

"Did latency change after the deploy?" is one query, not two dashboards and a
hope.

## Dashboards are live queries

`watch.bl` and `broadcast.bl` push transaction reports to subscribers. A
dashboard is a `live/web` page whose datalog query re-runs when relevant
datoms land. There is no refresh interval because there is no polling — the
page is a subscription.

## Alerts are schedules whose history is data

```clojure
(proc.server/defserver alerting
  (sched (every 1 :minutes :p95 check-p95!)))
```

The condition is a query; the firing is a transacted datom
(`{:alert :p95 :fired-at … :value …}`); the notification is an effect. Alert
fatigue — the silent killer of on-call — becomes debuggable: how often did
this alert fire, how often was it actionable, what did the human do each time?
All queries, because all of it is in the same store.

## The terminal difference

When an alert fires on a conventional stack, you switch tools: dashboard →
logs → ssh → debugger. Each switch re-establishes context the last tool
already had.

Here the alert datom names the service; the service is a live env; the env is
reachable from the same REPL you read the alert in:

```clojure
bl> (vm.core/run (vm "blog@main")
      "(do (inspect-mailbox web-pid) (trace slow-fn))")
```

Observation and intervention are the same act at different moments. This is
what the inversion buys that no dashboard can: **the observer is inside the
observed.**

## Export, for the outside world

Compliance and external tooling still want ndjson or Prometheus-shaped data.
That is a `flow.bl` consumer: it *demands* events from the tx-report stream at
its own pace, so a slow exporter can never back-pressure the node — pull
backpressure is the structure of the protocol, not a buffer to size.

The export is a projection, never a truth. If the exporter dies for a day, the
data it missed is re-derivable from datom; nothing is lost because nothing was
only ever in the export.
