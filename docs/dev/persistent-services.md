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
Realm drain first asks all service owners to clean up, with one shared five-second
deadline, then forcibly ends remaining members. Slow or stuck cleanup is therefore
not guaranteed to flush; explicit `stop!` waits without that drain deadline.
Cleanup must not call back into the realm manager while it is draining.
Route leases remain a separate gate.

Reproduce the real launcher regression (with a locally installed build):

```sh
cargo build --manifest-path tooling/drop/Cargo.toml --bin drop-launcher
python3 tooling/drop/tests/persistent-transport.py \
  --launcher /path/to/drop-launcher --build 04805c33
```

The harness uses private runtime/state directories, asserts that the first
returned command's OS VM remains alive and that a second command uses it, and
stops its daemon. On 2026-10-10 this passed against release 04805c33 with the new
launcher: 23,462 ms first boot and 131 ms second dispatch. Runtime service tests
are separate; this older release does not contain `vm.service`.

`vm.ports/claim` accepts `:service true`. The route's descriptor lease belongs
to the calling service process; its death makes the route disappear even while
the shared VM stays alive. Successful acquisition returns `:generation` beside
`:ok`; pass that generation to `release`. A stale cleanup cannot remove a new
route. Legacy root-scoped claims keep their old return shape and require explicit
release. All participating claim/release writers use an OS admission lease, and
duplicate hostnames are rejected with `:host_taken`. Moving an existing claim
requires release first. The port bind is still a probe: listener startup must
handle a real bind failure and release its claim. Unsupported lease acquisition
refuses ownership. Route reads fail closed if a lease cannot be inspected.
