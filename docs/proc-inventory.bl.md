# Automatic native owner discovery

The runtime registers application-scoped servers, supervisors, `proc.evolve`
slices and shared `proc.queue-runtime` owners at their existing start boundaries.
Application code supplies no separate live-process list. Unscoped legacy actors
remain outside the index; discovery does not imply that every possible producer
in an application has been found.

```clojure
(require '[proc.inventory :as inventory])
(inventory/snapshot "my-app" 100 10000)
; {:status :valid :scope :observed-owner-index
;  :participants [...] :receipt ... :scanned ...}
(inventory/recheck! receipt)
; {:status :current :scope :observed-owner-index}, or :stale
```

`page` accepts application ID, previous cursor (initially nil), and page size
1–1000. A snapshot collects pages under one registration revision with a total
role budget (default 10,000). Changes return stale rather than silently retrying
forever. A receipt from a partial page cannot authorize a complete inventory:
recheck requires the current total, distinct keys, exact registration tickets,
native component identity and PID liveness. Receipts are opaque, ephemeral VM
observations. They are not portable deployment or migration authorizations.

Each ordered index key starts with the application ID. Paging does not scan
other applications or the shared variable table. Native component joins use
existing generation leases, evolution registration tickets and queue owner
registrations, without messaging arbitrary actors. Returned participants omit
leases, callback functions, native tickets and execution environments. Counts
describe roles; a containing actor and its evolution slice may share a PID.

Capabilities describe precisely what was discovered:

- `:retained-drain`: a server or supervisor holds its native generation lease.
  Its callback module and arbitrary state cannot yet be switched automatically.
- `:managed-evolution-slice`: the existing explicit versioned request/state/
  reply protocol supports native rehearsal, revision checks and FIFO publication.
  A slice covers its own state, not all state of a containing custom server.
- `:unmanaged-evolution-slice`: versioned evolution exists, but managed-client
  admission and retirement are unavailable.
- `:queue-handler-transition`: the shared native queue owner has its existing
  handler publication, job adoption and retained-generation protocol.

The Env process owns the index and per-application revision tables; a supervised
collector monitors PIDs. A collector crash preserves entries, rebuilds counts
and monitors, prunes dead or closed roles, and changes the incarnation so old
cursors refuse. Closing a role records its exact ticket before contacting the
collector; a collector failure cannot resurrect that role while its PID survives.
Replacing Env itself invalidates the runtime's broader native contexts and
tables: the collector refuses that replacement and requires a fresh VM. This
is not an implementation of zero-downtime native-host replacement.

Discovery and migration are separate. Rechecking an observed index does not
close future admissions, prove candidate message/reply/state compatibility,
authorize shutdown, or make several actor commits atomic. Upgrade planners must
use actual candidate contracts and component transition authorities, retain old
code while accepted work drains, and fence old producer/factory admissions before
retirement. Normal message dispatch does not invoke inventory checks. Registration
adds work once at process/role start; monitor cleanup and explicit role close
update the index without scanning unrelated application state.
