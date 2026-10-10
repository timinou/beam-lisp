# Persistent project services

A finite task can opportunistically use a warm VM. A service must have one.
Declare `:service true` on its `env.bl` task:

```clojure
{:name "studio" :vm "shared"
 :tasks {"studio.dev" {:run "dev.bl" :service true}}}
```

The installed launcher starts the owner VM, waits for authenticated readiness,
and attaches. It never retries a sent command or falls back to a temporary VM.
Failures return an error; inspect `bl vm logs`. `--cold` explicitly overrides
this policy for foreground development. The task must keep running when cold.
`--warm-required` or `:warm "require"` selects the same transport explicitly.
The ordinary `:warm "start"` policy still starts in the background and lets a
finite first command run cold. Source checkout launchers remain cold tools.

Service-task metadata establishes transport, not application ownership. Use
`vm.service/acquire` inside the task to initialize one realm-owned service and
return its URL. The existing realm manager reserves a slot before acknowledging
it. Matching identities reuse it; incompatible identities reject. Initialization
continues after client disconnection, and readiness is returned only on success.
A failed owner can be acquired again. Identity must contain the world root,
storage mode and compatible backend/frontend revisions. Do not put secrets in it.

`vm.service/stop!` calls the service's cleanup callback and waits for its owner
to exit. Cleanup must stop listeners and work before closing durable storage.
Currently realm drain still uses forced member teardown: graceful service stop
must precede realm close. Route leases and bounded shutdown remain separate gates.
