# tooling.trace — why did the UI update?

When a live screen flickers and you do not know why, every UI framework gives
you the same non-answer: the view re-rendered, something changed, good luck.
The dependency is implicit in the shape of the render function, so there is
nothing to inspect.

`trace` makes the causal chain explicit and recordable: **a fact changed → these
subtrees recomputed → these patch ops shipped.** Because `incremental` already
expresses each subtree as a value with known dependencies, wrapping that with a
log turns an invisible cascade into a story you can read after the fact.

The record itself is a `data`-shaped value: a bounded log held in one shared
cell. So the trace is not a `println` stream you grep — it is data you can
summarize, count, and show in a panel.

```beam-lisp
(ns tooling.trace)
```

## The log is one shared cell

`open` makes a trace: an atom holding a vector of events, capped so a long
session cannot grow it without bound. `record!` appends; `events` reads;
`clear!` resets (you clear after the first paint so the trace shows *updates*,
not the initial mount).

```beam-lisp
(def ^:private cap 500)

(defn open
  "Create a trace log. Hold it and pass it to the other functions."
  []
  {:cell (atom [])})

(defn record!
  "Append an event map (with at least a :kind) to the trace, capped so it never
   grows without bound."
  [trace ev]
  (swap! (:cell trace)
         (fn [v]
           (let [v2 (conj v (assoc ev :at (System/system_time :millisecond)))]
             (if (> (count v2) cap) (subvec v2 (- (count v2) cap)) v2))))
  trace)

(defn events
  "Every recorded event, oldest first."
  [trace]
  @(:cell trace))

(defn clear!
  "Drop all recorded events (call after the first paint to trace updates only)."
  [trace]
  (reset! (:cell trace) [])
  trace)
```

## A traced subtree records why it recomputed

`traced` is `incremental/subtree` with a log wire attached: each time the piece
recomputes (because one of its deps changed), it records a `:recompute` event
naming itself. Between changes it returns its cached hiccup and records nothing
— so the trace shows exactly the pieces that actually moved.

```beam-lisp
(defn traced
  "A view subtree that records each recompute into `trace` under `label`.
   Otherwise identical to tooling.incremental/subtree: a derived over `deps`."
  [trace label deps render]
  (BeamLisp.Reactive/derive deps
    (fn []
      (record! trace {:kind :recompute :label label})
      (render))))
```

## Recording the patch, and reading the story

`note-patch!` records how many ops the differ produced for an update — the count
of DOM changes actually shipped. `last-update` reads back the causal summary:
which subtrees recomputed and how many ops resulted, the answer to "why did the
UI just update?"

```beam-lisp
(defn note-patch!
  "Record that an update shipped `op-count` patch operations."
  [trace op-count]
  (record! trace {:kind :patch :ops op-count}))

(defn recomputed-labels
  "The labels of every subtree that recomputed in the current trace."
  [trace]
  (->> (events trace)
       (filter (fn [e] (= :recompute (:kind e))))
       (mapv :label)))

(defn last-update
  "A summary of the update recorded since the last clear!: which subtrees
   recomputed, and how many patch ops shipped. The causal answer to
   'why did the UI update?'."
  [trace]
  (let [es (events trace)
        patches (filter (fn [e] (= :patch (:kind e))) es)]
    {:recomputed (recomputed-labels trace)
     :patch-ops (reduce + 0 (map :ops patches))
     :event-count (count es)}))
```

## What this unlocks

With the trace in hand, a change becomes legible end to end: you can see that
editing one field recomputed exactly the one subtree bound to it and shipped one
op — or catch the pathology where an over-broad subscription recomputed a piece
that then produced *zero* ops, meaning it re-rendered for a change it did not
care about. That second case is invisible today; here it is a `:recompute` with
no matching patch, right in the log.

Feed `last-update` to a panel (the pulse chip is the obvious home) and the
program narrates its own updates as they happen.

## What stays true

- **The trace is data.** A bounded vector in one shared cell — summarize it,
  count it, show it; it is not an ephemeral log line.
- **It records only real recomputes.** A subtree that returns its cached value
  records nothing, so the trace names exactly what moved.
- **It is opt-in and removable.** `traced` replaces `subtree` only where you
  want the story; everything else renders exactly as before, untouched.
