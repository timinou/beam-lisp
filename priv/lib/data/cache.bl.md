# data.cache — compute once, keep it, ask what you kept

At heart this is **memoisation**: give it a key and a thunk (a zero-argument
function that computes a value), and it runs the thunk at most once per key,
remembering the result. That is the whole job a cache does. The plain name is
the honest one — it is a cache, so it is called `cache`.

What makes it worth a module rather than a one-off map is two additions on top
of plain memoisation:

- **Content addressing + tiers, so "once" means once across restarts.** A key's
  identity is the hash of its inputs, and a hot in-memory tier (a native cell,
  reclaimed by the garbage collector) sits in front of an optional durable tier
  on disk. Ordinary in-process `memoize` forgets everything when the VM stops;
  a `cache` with a directory does not. Same inputs, same slot — this run and the
  next.
- **An index you can query.** Every entry is also a **fact in a small datalog
  database**, so the catalog of what is cached is a `q`, not a black box you
  clear when it misbehaves: what is stored, how large, how often hit, by which
  store, since when.

So: a cache, first and plainly. The content addressing makes it survive
restarts; the datalog index makes it legible. Both serve the one idea —
compute once, keep it.

```beam-lisp
(ns data.cache
  (:require [datom]))
```

## The index: a cache is a set of facts

The catalog lives in one in-memory datom connection. Each entry is an entity
keyed by its content hash (unique identity, so a re-put upserts the same row).
We record enough to answer the questions an operator actually asks.

```beam-lisp
(def ^:private index-schema
  [{:db/ident :entry/hash    :db/valueType :db.type/string :db/unique :db.unique/identity}
   {:db/ident :entry/store   :db/valueType :db.type/string}
   {:db/ident :entry/tier    :db/valueType :db.type/keyword}
   {:db/ident :entry/bytes   :db/valueType :db.type/long}
   {:db/ident :entry/hits    :db/valueType :db.type/long}
   {:db/ident :entry/created :db/valueType :db.type/long}])

; One index shared by every store in this VM, held in an atom so the datom
; connection itself is created lazily and once.
(def ^:private the-index (atom nil))

(defn- index-conn []
  (or @the-index
      (let [c (datom/connect index-schema)]
        ; a concurrent creator may win; keep whichever landed first
        (if (compare-and-set! the-index nil c) c @the-index))))
```

## A store is a value

A `vault` is just a description: a name (which namespaces every key, so two
stores never collide) and a directory for the durable tier. The hot tier is a
single atom holding a map from hash to value — one native cell, shared by all
readers, reclaimed when the store is dropped.

```beam-lisp
(defn open
  "Open (or describe) a vault. `name` namespaces keys; the optional opts map's
   `:dir` is the durable tier's directory (absent = memory-only). Returns a
   plain map you pass to get!."
  ([name] (open name {}))
  ([name opts]
   {:vault/name name
    :vault/dir  (get opts :dir)
    :vault/hot  (atom {})}))

(defn- content-hash [store key]
  ; identity = the store name plus the key's canonical printed form, hashed.
  ; Same inputs anywhere -> same slot, this run or the next.
  (let [material (str (:vault/name store) "\u0000" (pr-str key))]
    (subs (String/downcase (Base/encode16 (crypto/hash :sha256 material))) 0 40)))

(defn- disk-path [store hash]
  (when (:vault/dir store)
    (str (:vault/dir store) "/" hash ".json")))
```

## Recording a fact for every entry

`note!` writes one datom per put. `:entry/hits` accumulates through a read that
increments it, so the index knows not just what is cached but what is *earning*
its slot — the input any eviction policy actually needs.

```beam-lisp
(defn- note! [store hash tier bytes]
  ; the index is bookkeeping, never correctness: if its table is unreachable
  ; (e.g. created by a process that has since exited), swallow it — the cache
  ; still memoises correctly, it just cannot answer "what is cached" here.
  (try
    (datom/transact! (index-conn)
      [{:db/id -1
        :entry/hash hash
        :entry/store (:vault/name store)
        :entry/tier tier
        :entry/bytes bytes
        :entry/hits 0
        :entry/created (System/system_time :millisecond)}])
    (catch _ nil)))

(defn- bump-hits! [hash current]
  (try
    (datom/transact! (index-conn)
      [{:db/id -1 :entry/hash hash :entry/hits (+ 1 current)}])
    (catch _ nil)))

(defn- entry-hits [db hash]
  (try
    (let [rows (datom/q '[:find ?h :in $ ?hash :where [?e :entry/hash ?hash] [?e :entry/hits ?h]]
                        db hash)]
      (if (empty? rows) 0 (first (first rows))))
    (catch _ 0)))
```

## The one door: get!

`get!` is the whole point. Give it a store, a key, and a thunk that computes the
value if it is missing. It looks in the hot tier, then the durable tier, then
finally runs the thunk — writing the result back through both tiers and
recording the fact. The same inputs never compute twice.

```beam-lisp
(defn get!
  "Return the cached value for `key` in `store`, computing it with `(thunk)`
   on a miss and caching the result in both tiers. The thunk runs at most once
   per key per store, this run and \u2014 with a :dir \u2014 across restarts."
  [store key thunk]
  (let [hash (content-hash store key)
        hot  (:vault/hot store)
        path (disk-path store hash)]
    (cond
      ; hot hit: in this VM's memory already.
      (contains? @hot hash)
      (do
        (try (bump-hits! hash (entry-hits (datom/db (index-conn)) hash)) (catch _ nil))
        (get @hot hash))

      ; durable hit: on disk from a previous run. Warm the hot tier.
      (and path (File/exists? path))
      (let [value (Jason/decode! (File/read! path))]
        (swap! hot assoc hash value)
        (note! store hash :hot (byte-size value))
        value)

      ; miss: compute, write through both tiers, record the fact.
      :else
      (let [value (thunk)]
        (swap! hot assoc hash value)
        (when path
          (File/mkdir_p! (:vault/dir store))
          (File/write! path (Jason/encode! value)))
        (note! store hash (if path :durable :hot) (byte-size value))
        value))))

(defn- byte-size [value]
  ; a cheap, honest estimate: the encoded size the durable tier would write.
  (try (String/length (Jason/encode! value)) (catch _ 0)))
```

## The payoff: query the cache

Because the index is datalog, "what is in my cache?" is a query, not a mystery.
These are ordinary `datom/q` calls over the live index.

```beam-lisp
(defn entries
  "All catalog rows for `store` as maps. The cache, made legible."
  [store]
  (try
   (let [db (datom/db (index-conn))
        rows (datom/q '[:find ?hash ?tier ?bytes ?hits ?created
                        :in $ ?store
                        :where [?e :entry/store ?store]
                               [?e :entry/hash ?hash]
                               [?e :entry/tier ?tier]
                               [?e :entry/bytes ?bytes]
                               [?e :entry/hits ?hits]
                               [?e :entry/created ?created]]
                      db (:vault/name store))]
    (map (fn [row]
           (let [[hash tier bytes hits created] (vec row)]
             {:hash hash :tier tier :bytes bytes :hits hits :created created}))
         rows))
   (catch _ [])))

(defn stats
  "A one-line summary of a store: entry count and total bytes."
  [store]
  (let [es (entries store)]
    {:count (count es)
     :bytes (reduce + 0 (map :bytes es))
     :hits  (reduce + 0 (map :hits es))}))

(defn hottest
  "The `n` most-hit entries \u2014 what is actually earning its place."
  [store n]
  (take n (reverse (sort-by :hits (entries store)))))
```

## Why datalog, and not just a map

A plain map would cache values fine. It could not answer "which entries in the
`gemini` store are over 10 KB and were hit fewer than three times" without you
writing a scan by hand, every time, differently. The datalog index answers that
as one `q`, and the same index powers a dashboard, an eviction policy, and a
cost report without any of them re-implementing "walk the cache."

The honest tradeoff: a datom index is heavier than a map (every fact is written
to several ordered indexes, and history is retained). For a cache of thousands
of entries that is a rounding error against the values themselves, and you buy
a queryable, watchable catalog. For a cache of tens of millions, you would
compact or index only a sample. Reach for `vault` when the *question* "what is
cached" matters as much as the values.
