# Streaming a million things without a million things on the heap

A list of a million numbers, walked one at a time, does not need a million
numbers sitting in your process at once. It needs the *one* you are looking at
and a way to reach the next. This is the difference between holding a river and
standing in it.

You do not need to know Rust or schedulers to begin. The idea is small and the
payoff is measured at the end.

## Run the examples

This is a literate Beam Lisp program. Its `beam-lisp` blocks run top to bottom.
From the repository root, with a working build:

```sh
mix run -e '"docs/memory-policy/07-streaming-without-the-heap.bl.md" |> BeamLisp.Loader.read_source() |> BeamLisp.eval()'
```

```beam-lisp
(ns tutorial.streaming)

(defn check [label expected actual]
  (if (= expected actual)
    (println label "ok")
    (throw (ex-info (str "Check failed: " label)
                    {:expected expected :actual actual}))))
```

```bl-result check
&:"Elixir.BeamLisp.Ns.Tutorial.Streaming".check/3
```

## 1. A big input is copied once, not once per step

On the BEAM, sending a value to another process copies it. A naive way to walk
a large list lazily would copy the *remaining* list at every step — the tail
after element 1, then after element 2, and so on. That is quadratic: a
million-element walk copies half a trillion cells.

Beam Lisp does something else. A finite input longer than a small chunk size
is handed to a **cursor**: the whole list is copied *once* into native memory,
and from then on the walk pulls it back a chunk at a time.

```beam-lisp
(check "a big range sums correctly"
       (/ (* 1000000 1000001) 2)
       (reduce + 0 (range 1 1000001)))
```

```bl-result cell1
a big range sums correctly
:ok
```

You wrote `reduce` over a range of a million. Nothing in the source mentions a
cursor. That is the point: the cursor is how the runtime keeps its promise, not
a thing you manage.

## 2. What the consumer actually holds

Walk the sequence and, at each step, you hold one element and a handle to "the
rest." The rest is not a list living in your process — it is a small handle to
the native copy, plus at most one chunk of already-pulled elements.

```beam-lisp
(check "first five of a million" [1 2 3 4 5]
       (vec (take 5 (range 1 1000001))))
```

```bl-result cell2
first five of a million
:ok
```

Taking five out of a million does not realize the other 999 995. The walk pulls
one chunk, hands you five, and stops. Your process heap never sees the rest.

```text
process heap:   [ current chunk (<= 32) ] ── handle ──> native copy of the list
                       ^ tiny, bounded                        ^ one copy, off-heap
```

## 3. Why this is not slow

Pulling a chunk crosses from Beam Lisp into native code and back. There are two
ways to make that crossing. One is safe for *any* amount of work but pays a
scheduler detour every time — right for copying a megabyte, wasteful for
copying thirty-two integers. The other runs directly on the normal scheduler
and is far cheaper, but is only safe when the work is provably small.

A chunk is at most thirty-two elements. So the cursor measures its input **once**,
when it is created: if thirty-two elements fit comfortably, every chunk takes
the cheap crossing; only a cursor whose elements are individually large takes
the safe-but-slow one. The decision is made from the input's actual size, never
guessed, and it holds for the whole walk.

```beam-lisp
(defn evens-below [n]
  (filter even? (range 0 n)))

(check "streamed filter still correct"
       [0 2 4 6 8]
       (vec (take 5 (evens-below 1000000))))
```

```bl-result cell3
streamed filter still correct
:ok
```

## 4. The measured payoff

Two independent things improve, and they are separate promises.

**Memory.** A consumer that folds a million-element list holds the whole list;
a consumer that folds the same input through a cursor holds one chunk. Measured
in `scripts/memocell_prototypes.exs`: **15.81 MB versus about 0.02 MB** — the
consumer's heap is roughly three orders of magnitude smaller.

**Speed.** Pulling a chunk on the cheap crossing versus the safe-but-slow one,
measured in `scripts/memocell_cas_breakdown.exs`: **about 1.15 microseconds
versus about 16.8 microseconds per chunk** — a fourteen-fold difference. Before
this, the memory was already saved but every chunk paid the detour; now the
off-heap walk is cheap enough to be the default for any finite input past the
chunk size, not a special case you opt into.

```beam-lisp
(println "Streaming: all checks passed")
```

```bl-result cell4
Streaming: all checks passed
:ok
```

## What stays true

- **One copy.** The input enters native memory once. Deferred tails carry a
  small handle, never a fresh copy of the remainder.
- **Bounded consumer heap.** At most one chunk lives in your process while you
  walk. This is a promise about the consumer, not about the native copy, which
  stays alive as long as any cursor into it does.
- **The lane follows the data.** Small elements stream on the cheap crossing;
  large elements take the safe one. You never choose; the size does.
- **Correctness is independent of the lane.** The same values, in the same
  order, come out either way. Speed is the only thing the choice changes.

## Keep exploring

- `lib/beam_lisp/seq_cursor.ex` — the chunk adapter that keeps one chunk on the
  heap and threads the lane decision.
- `native/lazy_memo/src/lib.rs` — `cursor`, `cursor_chunk`, and the
  `dirty_chunks` decision made once at creation.
- `docs/memory-policy/shared-lazy-values.bl.md` — the memo cell these cursors
  are built on, and why ownership follows references.
