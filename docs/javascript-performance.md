# Browser work without changing namespace APIs

String length, slicing, splitting and reversing preserve grapheme semantics.
The JS runtime handles ASCII directly (CRLF still uses Unicode segmentation)
and retains a bounded LRU of Unicode segmentation results. Namespace authors
and callers use the existing string functions.

A bundle can prepare libraries for live compilation with `bl.js/build!`:

```clojure
(js/build! "app.main" {:out "out" :preload ["app.music"]})
```

Preloaded namespaces join the normal compilation graph. Their compiled
functions, values and private macro helpers are bound in each evaluator realm;
their macros are captured in `boot-cache.mjs` at build time. Callers keep their
normal aliases and macro forms. A requested preload fails the build if capture
fails, rather than silently moving library compilation back into startup. Node
is needed to generate this cache. Preload dependencies that provide live macros
must also be listed, in dependency order. Avoid relying on application top-level
initialization: this is the same compiled namespace contract as other JS builds.

For structured-data jobs, `js.worker` provides a native BL transport:

```clojure
(ns ^:js app.browser (:require [js.worker :as worker]))
(defn evaluator [url] (worker/client url))
; (.request client bl-value) => a JS Promise of structured JS data
; (.dispose client) releases the realm and rejects outstanding requests.
```

Inside a module worker, `(worker/serve ready handler)` serializes requests after
`ready` resolves. `handler` receives and returns BL data; conversion belongs to
the transport. Functions, DOM nodes and audio resources stay with their owning
realm. Clients allow 32 outstanding requests and terminate on a 15-second
request timeout, worker failure or disposal. Ordinary evaluation errors reject
only that request. Bootstrap errors terminate the client so its owner can
recreate it. These are ownership APIs for the host, not new requirements for
users of the library running inside the worker.

The runtime's `interop.mjs` also exports `releaseNamespace(name)` for ephemeral
live evaluation. It removes that namespace's vars, aliases, metadata, links and
public JS interface while invalidating namespace lookup caches.
