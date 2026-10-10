# Scoped diagnostics

`diagnostics` lives in `priv/std/diagnostics.bl`; `diagnostics.otp` lives in
`priv/std/diagnostics/otp.bl`. A qualified event uses a dotted namespace and a
slash before its name: `:example.reader/published`. Past tense names a completed
fact. A span records execution; publication deserves its own event.

Declare bounded fields and choose a sink. Unregistered fields are omitted.
Context accepts opaque handles, supplied by trusted application code. An ID
schema checks shape; it cannot determine whether a caller put a secret in an ID.

```beam-lisp
(ns diagnostics.walkthrough (:require [diagnostics :as diag]))
(def captured (atom []))
(def schemas {:example.reader/read {:fields {:reader/pages :count}}
              :example.reader/published {:fields {:reader/chunks :count}}})
(diag/with-options {:sink #(swap! captured conj %) :events schemas}
  (diag/with-context {:diagnostics/operation-id "op_demo"}
    (diag/with-span :example.reader/read {:reader/pages 2}
      (diag/emit! :example.reader/published {:reader/chunks 4 :document/text "private"})
      42)))
```

```bl-result captured
42
```

The body form reads like ordinary code. The function form accepts a short
anonymous function; `%` and `%1` refer to its first argument.

```beam-lisp
(diag/with-span-fn :example.reader/read {} #(+ 40 2))
```

```bl-result cell1
42
```

```beam-lisp
[(mapv :diagnostics/event @captured)
 (:reader/chunks (second @captured))
 (contains? (second @captured) :document/text)
 (diag/context)]
```

```bl-result cell2
[[:diagnostics.span/started :example.reader/published :diagnostics.span/ended] 4 false {}]
```

Scopes restore context in `finally`. Spans preserve the body's value and raised
exception. Sink failures increment `loss-count` and preserve execution outcomes.
The capture sink runs synchronously and is useful for tests. Production uses the
bounded OTP delivery handler. The checked-in host seed conveys the registered
scope through `spawn` and `future`. OTP callbacks establish an explicit scope at
their processing boundary. Detached workers use `with-linkage-fn` to replace the
previous tenant and span with safe durable linkage and fresh execution IDs.

The capture sink is useful for tests and local exploration.

Run the separate examples with:

```sh
./bin/bl -p priv/std run examples/diagnostics/01-api.bl
./bin/bl -p priv/std run examples/diagnostics/02-proc.bl
./bin/bl -p priv/std run examples/diagnostics/03-queue.bl
./bin/bl -p priv/std run examples/diagnostics/04-delivery.bl
./bin/bl -p priv/std run examples/diagnostics/05-pipeline.bl
```

`proc.fence/completed` distinguishes returned, crashed and timed-out execution.
Its kill flag describes a request. `proc.tick/failed` and `tick-last-failure`
expose a bounded failure category. `proc.queue/settled` describes owner-guarded
settlement separately from the worker's outcome. A claim-expired event describes
a lease; a slow worker may still be running. Queue storage survives process
restarts within a VM. VM restart durability needs a persistent store.

## Runtime delivery

`configure!` installs defaults for the current Beam Lisp environment. Local
`with-options` scopes override them and restore in `finally`. `emit!` accepts a
map or a zero-argument function. The function runs only when the registered
event passes `:min-level`, which avoids constructing fields for disabled events.
Call `unconfigure!` before destroying a configured environment. Captured scopes
belong to their environment and cannot be installed in a different one.

`diagnostics.delivery` owns one writer process. Admission uses a fixed number of
credits, including the record currently being written. A full channel, a dead
writer, or admission contention returns `:dropped`; the producer performs no IO.
Writer failures are counted and the worker continues. `close!` stops admission,
drains until its deadline, and terminates a blocked writer.

```beam-lisp
(ns diagnostics.delivery.walkthrough
  (:require [diagnostics.delivery :as delivery]))
(def written (atom []))
(def channel (delivery/open! 4 #(swap! written conj %)))
(delivery/submit! channel {:example/count 4})
(delivery/close! channel 1000)
[(:written (delivery/stats channel)) (:pending (delivery/stats channel)) @written]
```

```bl-result written
[1 0 [{:example/count 4}]]
```

## OTP privacy and journal output

Install `diagnostics.otp/install!` once at application boot, before sensitive
work. It owns the VM's Logger handlers and installs a primary privacy filter.
Authenticated diagnostics are reprojected against the registered schemas.
Unknown strings, format arguments, reports and metadata become a minimal event.
Report callbacks never execute. The filter's failure path also emits a minimal
event; it never returns the original report.

The default writer produces one JSON line on stderr with a syslog severity
prefix. With systemd's `SyslogLevelPrefix=yes`, journald removes that prefix and
retains the native priority. Each JSON record is at most 8192 bytes including its
newline. Oversized records omit optional fields and retain their core identity
with `diagnostics/truncated=true`.

`diagnostics.delivery/stats` reports accepted, written, failed, dropped and pending
records independently of logging. `loss-count` counts local projection and sink
failures; delivery statistics also expose downstream loss. Diagnostics are lossy;
audit receipts and recovery state belong in durable storage.

Application registries accept 256 events and 128 keyword enum members. Fields
remain limited to 24 and JSON records to 8 KiB. `diagnostics/health` exposes
finite counters for unknown events, invalid non-nil fields, sink failure and
truncation. Optional absent fields and disabled events are not losses.

Trusted nested context may explicitly clear a context key with nil. Detached
work still uses `with-linkage-fn` to mint fresh trace/attempt IDs.

`diagnostics.code/configure!` accepts a trusted release catalog keyed by existing
module/function spellings. `stack` projects at most eight frames to catalog site
handles, arity and catalog line; it never emits arguments or unknown paths.
`with-operation-fn` registers a local execution handle for its dynamic lifetime;
`sample` resolves that handle internally and takes at most three snapshots over
four seconds. It accepts no PID and reads no dictionaries or messages. Expose
this only through an authenticated operator control plane, never public input.

`diagnostics.health/start!` can publish a private atomic sample every 15 seconds
at a trusted `/run/` path whose parent the service manager provisions. This
worker operates independently of Logger delivery; failed publication leaves a
stale file. Consumers must distinguish stale samples from healthy channels.

`credential/refresh-completed` reports the actual renewal boundary: a finite
provider, numeric status, returned/failed/raised outcome, recovery category and
elapsed milliseconds. Credential values and provider bodies remain excluded.
Connection/client/integration/run handles are optional reserved context IDs.

`diagnostics.health/start!` starts a VM-owned supervisor for a single periodic
publisher, returning its PID; `stop!` stops that supervisor. Samples include
channel capacity, boot/release identity and projection counters. The health
file is independent of Logger, atomically replaced and mode 0600 in a
service-provisioned private directory. A failed write leaves an old sample;
consumers must check sample age instead of interpreting it as current health.
