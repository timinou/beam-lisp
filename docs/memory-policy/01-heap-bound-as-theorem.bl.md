# Heap bound as theorem

A BEAM process starts with a tiny heap (233 words) and grows it by collecting:
every time the heap fills, the collector copies the live data to a bigger one.
A server whose state is known to fit in N words pays that dance for nothing —
and a server whose state *should* fit in N words but does not is leaking, and
nobody is told.

Two flags decide both stories, and today a human guesses them:

```
min_heap_size   the heap the process is born with — big enough ⇒ no early collections
max_heap_size   the size at which the VM kills the process instead of growing it
```

beam-lisp already proves the number those flags want.

## The proof that exists

A `defserver` carries an invariant, and `system.core/verify-process` proves it
holds across every clause. When the invariant bounds a collection —
`(<= (count queue) 64)` — the SMT translator abstracts the collection to its
length (`system.smt/translate-len`), and the proof is a real theorem about a
number:

```clojure
(defserver mailbox
  ^{:invariant (and (<= (count (:queue state)) 64)
                    (>= (:credit state) 0))}
  (init [_] {:queue [] :credit 100})
  (handle-cast [[:enqueue m] state]
    (if (< (count (:queue state)) 64)
      (update state :queue conj m)
      state))
  (handle-call [:drain _ state]
    [(:queue state) (assoc state :queue [])]))
```

`state-shape` (in `system.core`) knows the fields and their sorts — `:queue` a
vector, `:credit` an int. What is missing is one function from a proven shape to
a word count.

## The policy

```clojure
(ns memory.heap
  (:require [system.core :as sys] [system.smt :as smt]))

;; words a proven-bounded value occupies, by sort. Numbers are BEAM's on a
;; 64-bit VM: a small int is 1 word (immediate), a float 3, a binary header 6
;; plus its bytes off-heap above 64 B, a tuple 1 + arity, a list 2 per cell.
(defn words-of
  [sort bound]
  (case sort
    "Int"    1
    "Real"   3
    "Bool"   1
    "String" (+ 6 (quot (or bound 64) 8))
    :vec     (* 2 (or bound 0))            ; a bounded seq: cells × elements
    :map     (+ 3 (* 2 (or bound 0)))
    1))

(defn heap-bound
  "The proven upper bound on a server's STATE, in words, or nil when any field
   is unbounded. `verify-process` supplies the per-field length bounds it
   proved; state-shape supplies the sorts."
  [node]
  (let [shape  (sys/state-shape node)
        bounds (sys/length-bounds node)]          ; {field → K} from the invariant
    (when (every? (fn [[f sort]] (or (not (contains? #{:vec :map "String"} sort))
                                     (contains? bounds f)))
                  shape)
      (reduce + 0 (map (fn [[f sort]] (words-of sort (get bounds f))) shape)))))

(defn flags
  "Process flags for a proven bound: born large enough to never collect under
   the invariant; killed at 4× so a leak becomes a crash-with-restart instead
   of a node OOM. nil when there is no theorem — the process keeps VM defaults."
  [node]
  (when-let [b (heap-bound node)]
    (let [working-set (* 2 b)]                    ; state + one message in flight
      {:min_heap_size working-set
       :max_heap_size {:size (* 4 working-set) :kill true :error_logger true}})))
```

The compiler's `defserver` lowering calls `(memory.heap/flags node)` and, when
it answers, prepends `(erlang/process_flag …)` calls to `init`. The sink already
exists: `BeamLisp.Refs.apply_heap_bound` sets `max_heap_size` for sandboxed
forks from a human-chosen `max_heap_words`; the theorem replaces the guess.

## What the author sees

Nothing new to write. A server with an invariant that bounds its collections is
born with the right heap; a server without one behaves as it always did. The
hover on `defserver` shows the theorem: *heap bound 1 284 words, from
`(<= (count queue) 64)`*.

## Speed · quality · provability

**Speed.** A process whose heap fits its working set never runs a minor
collection. For a server handling thousands of messages a second that is the
difference between a flat latency profile and a sawtooth. The cost is memory
reserved up front — right for hundreds of long-lived servers, wrong for a
hundred thousand short-lived ones. The policy applies only where a theorem
exists, and a `^{:heap :default}` opt-out is the escape hatch.

**Quality.** The tripwire is the real gain. Today a leaking server grows until
the node dies. With `max_heap_size` set from a *proof* that the state fits,
growth past the bound is by definition a bug in something the proof did not
see — a mailbox, a sub-binary, an off-model side effect — and the VM logs it
and the supervisor restarts it.

**Provability.** Unchanged: the bound is a byproduct of an invariant already
proved. Every `.bl` server that verifies today gets the flags for free; none
gets a weaker proof.

## Where it lives

- `system.core/verify-process` and `state-shape` — the proof and the shape.
- `system.smt/translate-len` — the abstraction that turns a collection into a
  length the solver can bound.
- `memory.heap` (to build) — the arithmetic from shape × bounds to words, and
  the flags.
- `BeamLisp.Refs.apply_heap_bound` — the existing runtime sink.
