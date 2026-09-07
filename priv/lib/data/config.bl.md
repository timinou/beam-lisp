# data.config — one settings sheet everyone shares, read live

Configuration is the bag of settings a program reads constantly but changes
rarely: model aliases, feature flags, endpoints, limits. The trap is in how it
is held. Rebuild the settings map on every read and you pay to reconstruct it a
thousand times a second. Copy it into each process and you hold a thousand
copies. Freeze it into a module and you cannot change it without a redeploy.

`config` holds the settings **once**, in a single shared cell that every process
reads directly. A read is a cell read — nanoseconds, no rebuild, no copy. A
change is a swap, seen by everyone at once. And because settings often need a
per-caller twist (a test override, a fork's own endpoint), a config can carry a
layer of **overrides** on top of its base without disturbing the shared base.

## One verb, many types

An earlier version of this module exposed its own `get` and `set`, shadowing the
language's names and reaching for a qualified `clojure.core/get` escape hatch
inside. That is exactly the anti-pattern the whole `data` effort argues against:
a new verb per type. The fix is the language's own answer — **protocol
dispatch**. A `Config` is a record that implements a small `Settings` protocol,
so `fetch` is one verb that dispatches on the value's type. No shadow, no
escape hatch; a config simply *is* fetchable.

```beam-lisp
(ns data.config)

(defprotocol Settings
  "The reading side of configuration. One verb, dispatched on the value's type,
   so a Config plugs into it exactly as any future settings-shaped type would."
  (fetch [c k] [c k default])
  (settings [c]))
```

## The config type

A `Config` wraps one shared cell holding a base map and an overrides map. The
record is the type protocol methods dispatch on; the cell inside is what makes
reads shared and live.

```beam-lisp
(defrecord Config [cell])

(defn create
  "Hold `base` (a map of settings) in one shared cell, wrapped in a Config.
   Everyone who holds it reads the same copy."
  [base]
  (->Config (atom {:base base :overrides {}})))

(defn ref
  "The config's underlying cell, for use as a `derived` dependency. A Config
   record has a stable identity, so a derived over the Config itself would
   never see a `put`; depend on `(ref config)` instead and the derived
   recomputes whenever a setting changes."
  [c]
  (:cell c))

(defn- effective [c]
  ; overrides win over base; this is the map every read sees.
  (let [s @(:cell c)]
    (merge (:base s) (:overrides s))))
```

## Reading: the Settings protocol

`fetch` reads one key (with an optional default); `settings` returns the whole
effective map. These are the protocol methods, so `(fetch cfg :model)`
dispatches on the Config type — the same call shape any other Settings type
would answer to.

```beam-lisp
(extend-protocol Settings Config
  (fetch
    ([c k] (fetch c k nil))
    ([c k default]
      (let [m (effective c)]
        (if (contains? m k) (get m k) default))))
  (settings [c] (effective c)))
```

## Changing: shared and atomic

`put` changes the base; `merge-in` folds a map of changes. Both are a single
swap on the shared cell, so every reader sees the new value on its next
`fetch` — no reload, no restart, no propagation to wire by hand. These are
plain functions (not protocol methods) because they name a mutation, not a
lookup — but they too take the Config type and touch only its one cell.

```beam-lisp
(defn put
  "Change base setting `k` to `v`. Every holder sees it on the next fetch."
  [c k v]
  (swap! (:cell c) (fn [s] (assoc-in s [:base k] v)))
  c)

(defn merge-in
  "Fold a map of changes into the base at once."
  [c changes]
  (swap! (:cell c) (fn [s] (update s :base merge changes)))
  c)
```

## Overrides: a per-context twist without a second config

An override sits *on top* of the base: a test that needs a fake endpoint, a fork
that points at its own service. `override` sets one; `with-overrides` folds a
map; `clear-overrides` drops them all, returning to the shared base. The base is
untouched, so overrides never leak into what other holders read from it.

```beam-lisp
(defn override
  "Layer a single override on top of the base. Base is untouched."
  [c k v]
  (swap! (:cell c) (fn [s] (assoc-in s [:overrides k] v)))
  c)

(defn with-overrides
  "Layer a map of overrides at once."
  [c overrides]
  (swap! (:cell c) (fn [s] (update s :overrides merge overrides)))
  c)

(defn clear-overrides
  "Drop every override, returning reads to the shared base."
  [c]
  (swap! (:cell c) (fn [s] (assoc s :overrides {})))
  c)
```

## What stays true

- **One verb, dispatched.** `fetch` is a Settings protocol method; a Config
  answers it by type, so there is no shadowed `get` and no escape hatch.
- **One copy, shared.** Every holder reads the same cell; there is never a
  per-process copy to keep in sync.
- **Reads are cheap and live.** A `fetch` is a cell read plus a merge — no
  rebuild — and always reflects the latest `put`.
- **Overrides layer, they do not fork.** An override changes what *this* config
  reads; the base other holders read is untouched until you `put` it.
- **Change is atomic and global.** A `put` is one swap; the next `fetch`
  anywhere sees it.
