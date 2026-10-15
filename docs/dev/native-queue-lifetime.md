# Native queue worker lifetime

`proc.queue-runtime/stop!` distinguishes stopping the scheduling actor from
stopping its accepted physical worker bodies:

```clojure
(runtime/stop! server)                         ; actor only, compatibility default
(runtime/stop! server {:workers :stop})         ; await owned bodies and actor
(runtime/stop! server {:workers :stop :timeout-ms 5000})
```

Use strict shutdown before closing the queue's connection or any application
store used by its callback. Close those resources only after a `:stopped` or
`:already-stopped` result. A refusal is not permission to close the stores.
The timeout must be an integer from 1 through 30000 milliseconds.

The native owner retains an ephemeral physical-worker inventory independently
of durable claims. Claim expiry frees a scheduling slot; it does not prove that
the old body has exited. Strict shutdown includes expired live bodies and bodies
retained across an earlier actor-only stop. A newly started native owner inherits
those inventories. Workers cannot enter the callback before the owner registers
their lifetime, and a body whose owner dies before that release exits without
entering the callback.

Only the registered native owner or its exact, already-dead retained owner grants
this cleanup authority. A custom actor with the same name, or an older owner
without physical lifetime evidence, cannot establish strict shutdown. Inventories
contain local PIDs and are never serialized into job payloads.

Restarting an older owner in the same VM does not recreate missing lifetime
evidence. Its new owner retains that incomplete status and refuses strict cleanup;
a fresh process or an explicit migration authority must establish the boundary.

Stopping a local body does not undo external IO. Durable jobs, attempt records and
effect checkpoints remain unchanged. An effect accepted remotely before its
response was lost still requires reconciliation; shutdown must not turn it into
an unsubmitted or cancelled effect. Restart uses the existing claim clock,
checkpoint and recovery rules.

The focused `test/bl/proc/queue_owned_stop_test.bl` uses Veritas HTTP to exercise
an accepted mutation with a blocked response and readback after restart. It also
exercises expired live workers, actor-only compatibility and inherited bodies.
Its fixture cleanup owns only its own actors, worker PIDs and temporary stores.
