# Namespace loading

Declare the names you need. Beam Lisp initializes ordinary aliased or explicitly
referred dependencies when you use them:

```clojure
(ns app (:require [reports :as reports] [math :refer [square]]))
(square 5)              ; initializes math
(reports/summary data)  ; initializes reports
```

A function call, a first-class var read, a macro expansion, or a protocol
extension can be the first use. Aliases and visibility rules apply before that
use. Each dependency keeps the search roots from its declaration; changing the
current directory does not redirect a deferred dependency.

Use a bare require for initialization effects:

```clojure
(ns app (:require [app.registration]))
```

Bare requires and `:refer :all` initialize at declaration time. `:refer :all`
takes a snapshot of public names at that point. Explicit loader calls initialize
the requested namespace immediately. Concurrent first uses share loader
ownership, and recursive requires use the same cycle guard.

## Editing and rebuilding

`bl build` builds the complete configured inventory, including literate sources.
An unchanged unit reuses its artifact. An ordinary dependency body edit rebuilds
that dependency while consumers whose interfaces remain covered can reuse their
artifacts. Interface and macro/helper changes invalidate affected consumers.
Compiler changes rotate the generation and require a coherent image rebuild.
Freshness uses content, not only file size or modification time.

A stale library artifact with available source is compiled and cached on demand.
A cache hit replays initialization; a compile already runs it. A failed
initialization propagates instead of silently evaluating its earlier effects a
second time. `BEAM_LISP_AOT_STRICT=1` refuses stale artifacts and names the rebuild
command. `BEAM_LISP_AOT_REPAIR=off` disables automatic library repair.

The build driver accepts `:scope :scoped` for a partial inventory. Scoped builds
preserve unrelated manifest entries, logs, and BEAMs; a full build owns deletion.
A deleted scoped source remains until a full authoritative inventory removes it.

## Definition tables and live edits

An AOT namespace carries its function declarations in the BEAM as a shared literal. Its environment stores a small reference to that table; reading declarations does not copy the whole namespace through ETS. Source-loaded and edited namespaces use an environment-local map snapshot.

The declaration table is available before value initializers run. Initializers keep their source order, and the namespace becomes ready after initialization completes. An initializer can define another function in its own namespace: the new definition extends the declarations and leaves a live map snapshot.

Before a live edit replaces a namespace shim, every environment referencing its table materializes its own snapshot. Existing map snapshots stay unchanged; only the writing environment's table receives the edit. Removing a definition or explicitly storing an empty table remains a local override. Destroying a fork removes its snapshots and preserves other environments' tables.

A table reference names the currently loaded module, not an immutable helper-body certificate. Compiler specialization still needs checked binding/domain facts and body-change validity; a stable name or signature is not enough.

## Lazy values and memory

Lazy values retain realized elements so later consumers see the same values.
Concurrent consumers share a force attempt. Arbitrary reducers use the chunked
memo walk: stopping with `reduced` keeps the realized prefix instead of restarting
producer effects. Count and `to-list` use non-halting fold recipes.

`:lazy_cache_budget_bytes` bounds growing lazy publications through atomic native
admission. A refusal after production is terminal for that cell and wakes its
waiters; reading it again does not rerun the producer. Already-published values
remain readable. Reference-cell updates retain their separate mutation contract.

Finite eager inputs share one immutable native cursor root. Replaying a cursor
position returns the same chunk; advancing one consumer does not consume another
consumer's position.
