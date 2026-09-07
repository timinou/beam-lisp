# data.tap — a bounded, subscribable history of frames

A **tap** is where a running system publishes what it just did, so anything
else can watch. It has two halves:

- a **ring** — the last `cap` frames, in order, each stamped with a monotonic
  `:t`. Reading history is a plain vector read.
- a **subscriber set** — processes that want every frame the instant it lands,
  delivered as an ordinary message `[:tap/frame frame]`.

The tap knows nothing about what a frame *is*. A live view publishes
`{:ops … :tree … :ms …}` per commit; a job runner could publish
`{:job … :status …}`. The pattern is the same: a bounded log plus a fan-out.
This is the shape of Clojure's `tap>`/`add-tap`, with history added so a late
subscriber (a dev tool that opens after the fact) can still see what happened.

Because frames hold *values* (persistent data), keeping the last few hundred
is cheap — a frame that carries a whole rendered tree shares structure with
the frame before it.

```beam-lisp
(ns data.tap)
```

## Opening a tap

```beam-lisp
(defn open
  "A new tap. `opts` may set `:cap` (frames kept; default 200)."
  ([] (open {}))
  ([opts]
   {:cell (atom {:t 0 :frames [] :subs #{}})
    :cap (get opts :cap 200)}))
```

## Publishing

`publish!` stamps the frame with the next `:t` and the wall-clock `:at`,
appends it to the ring (dropping the oldest past `cap`), and sends it to every
subscriber. It returns the stamped frame, so the publisher can carry `:t`
onward (a live socket sends it to the browser, for instance).

A dead subscriber costs nothing: `erlang/send` to a dead pid is a no-op.
Subscribers are pruned lazily on `unsubscribe!`.

```beam-lisp
(defn publish!
  "Append `frame` (a map) to the tap, stamped with :t and :at, and deliver
   [:tap/frame frame] to every subscriber. Returns the stamped frame."
  [tap frame]
  (let [cap (:cap tap)
        stamped (atom nil)]
    (swap! (:cell tap)
           (fn [s]
             (let [t (inc (:t s))
                   f (assoc frame :t t :at (System/system_time :millisecond))
                   fs (conj (:frames s) f)
                   fs (if (> (count fs) cap) (subvec fs (- (count fs) cap)) fs)]
               (reset! stamped f)
               (assoc s :t t :frames fs))))
    (doseq [pid (:subs @(:cell tap))]
      (erlang/send pid [:tap/frame @stamped]))
    @stamped))
```

## Reading history

```beam-lisp
(defn frames
  "Every retained frame, oldest first."
  [tap]
  (:frames @(:cell tap)))

(defn latest
  "The most recent frame, or nil."
  [tap]
  (peek (frames tap)))

(defn frame
  "The frame stamped `t`, or nil if it has aged out (or never was)."
  [tap t]
  (first (filter (fn [f] (= t (:t f))) (frames tap))))

(defn between
  "Frames with `from` <= :t <= `to`, oldest first."
  [tap from to]
  (into [] (filter (fn [f] (and (>= (:t f) from) (<= (:t f) to))) (frames tap))))

(defn size
  "How many frames are retained."
  [tap]
  (count (frames tap)))

(defn clear!
  "Drop the history (the :t counter keeps climbing, so old :t never reappear)."
  [tap]
  (swap! (:cell tap) (fn [s] (assoc s :frames [])))
  tap)
```

## Subscribing

```beam-lisp
(defn subscribe!
  "Deliver every future frame to `pid` (default: the caller) as [:tap/frame f]."
  ([tap] (subscribe! tap (erlang/self)))
  ([tap pid]
   (swap! (:cell tap) (fn [s] (assoc s :subs (conj (:subs s) pid))))
   tap))

(defn unsubscribe!
  ([tap] (unsubscribe! tap (erlang/self)))
  ([tap pid]
   (swap! (:cell tap) (fn [s] (assoc s :subs (disj (:subs s) pid))))
   tap))

(defn subscribers
  [tap]
  (:subs @(:cell tap)))
```

## What this unlocks

A tap turns "the system did something" into a value with an address (`:t`).
Anything downstream — a dashboard, a timeline scrubber, a test recorder —
reads or subscribes; the publisher never knows they exist. That inversion is
what lets a whole dev-tool family grow without the app changing.
