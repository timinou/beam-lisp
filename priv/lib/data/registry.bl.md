# data.registry — a roll-call of live things

Again and again a program needs a *list of active things*: open connections,
running jobs, tracked values, mounted views, feature flags. Each time, someone
hand-rolls the same shape — a map held in a process, an ad-hoc "add" and
"remove", a scan to list what is there. `registry` is that shape, once, done
well.

The idea is a roll-call. A live thing **signs in** with a name and whatever you
want to remember about it; later you can **list** who is present, **look one
up**, or **sign it out**. Nothing more — but because it is one shared,
GC-owned cell underneath, the roll-call is safe to read and write from many
processes at once, and it never becomes a second, subtly-different
implementation in every module that needs "a list of things".

```beam-lisp
(ns data.registry)
```

## Sign in, sign out

A registry is a value you `open`: an atom holding a map from a generated id to
an entry. `enroll` signs a thing in with a `kind` (a keyword bucket), a `name`,
and a `meta` map of whatever else matters; it returns the id. `retire` signs it
out. Both are plain `swap!`s on one cell, so concurrent enrolments never lose
each other.

```beam-lisp
(defn open
  "Create a fresh registry. Hold the returned value and pass it to the other
   functions; it is one shared cell, safe across processes."
  []
  {:cell (atom {:next 0 :entries {}})})

(defn enroll
  "Sign a thing in under `kind` with a `name` and a `meta` map. Returns the id
   you later pass to `retire`. Records the moment it joined."
  [reg kind name meta]
  (let [result (swap! (:cell reg)
                      (fn [s]
                        (let [id (+ 1 (:next s))]
                          (-> s
                              (assoc :next id)
                              (assoc-in [:entries id]
                                        {:id id :kind kind :name name
                                         :meta meta
                                         :since (System/system_time :millisecond)})))))]
    (:next result)))

(defn retire
  "Sign a thing out. A retired id simply disappears from the roll-call."
  [reg id]
  (swap! (:cell reg) (fn [s] (update s :entries dissoc id)))
  reg)
```

## Read the room

The roll-call is meant to be read. `entries` is everyone present, oldest first;
`of-kind` filters to one bucket; `lookup` finds one by id; `count-by-kind` is
the histogram — the shape of what is live, at a glance.

```beam-lisp
(defn entries
  "Every enrolled entry, oldest first. The roll-call, read."
  [reg]
  (sort-by :since (vals (:entries @(:cell reg)))))

(defn of-kind
  "Only the entries in one `kind` bucket."
  [reg kind]
  (filter (fn [e] (= kind (:kind e))) (entries reg)))

(defn lookup
  "The entry with `id`, or nil if it has retired."
  [reg id]
  (get (:entries @(:cell reg)) id))

(defn count-by-kind
  "How many entries of each kind \u2014 the shape of the roll-call."
  [reg]
  (reduce (fn [acc e] (update acc (:kind e) (fn [n] (+ 1 (or n 0)))))
          {}
          (entries reg)))

(defn size
  "How many things are currently signed in."
  [reg]
  (count (:entries @(:cell reg))))
```

## Why one shared cell, and not a process

The obvious alternative is a process (an Agent or GenServer) holding the map.
That works, but it makes every read and write a message round-trip, and it ties
the roll-call's lifetime to a process you must supervise. Backing the registry
with one shared cell instead means: reads are direct (no message), writes are a
lock-free compare-and-swap, and the roll-call lives exactly as long as you hold
it — no process to start, supervise, or leak. A registry is *data*, not a
server, and this module keeps it that way.

## What stays true

- **One shared cell.** Many processes may enroll, retire, and read at once; the
  compare-and-swap makes concurrent writes safe with no locks in your code.
- **A retired id is simply gone.** `lookup` returns nil, `entries` omits it;
  there is no tombstone to reason about.
- **Order is join-order.** `entries` is oldest-first, so a roll-call reads the
  way things arrived.
- **`meta` is yours.** The registry keeps `id`, `kind`, `name`, `since` for
  you; everything else lives in the `meta` map you supply, uninterpreted.
