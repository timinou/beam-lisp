# Lazy values: calculate once, keep only what is needed

A lazy sequence is a recipe for values. It does not have to cook the whole
meal before serving the first bite.

This tutorial has two layers:

- **Executable language:** `lazy-seq`, `first`, `take`, and shared values.
- **Runtime ownership:** native memo cells whose memory follows their live
  references. The examples below test values and sharing; the runtime test
  suites additionally check reclamation, cycles, process death, and native
  library cleanup.

You do not need to know Rust, ETS, or garbage collection to begin.

## Run the examples

This is a literate Beam Lisp program. Its `beam-lisp` code blocks run together,
from top to bottom. Shell commands and `text` diagrams are not program cells.
From the repository root, with a working project build:

```sh
mix run -e '"docs/memory-policy/shared-lazy-values.bl.md" |> BeamLisp.Loader.read_source() |> BeamLisp.eval()'
```

The examples are finite, even when they describe an infinite sequence. Each
check prints its label and `ok`, or raises an error. Run in a fresh VM so
previous namespace definitions and lazy values cannot affect the experiment.

```beam-lisp
(ns tutorial.shared-lazy)

(defn check [label expected actual]
  (if (= expected actual)
    (println label "ok")
    (throw (ex-info (str "Check failed: " label)
                    {:expected expected :actual actual}))))
```

```bl-result check
&:"Elixir.BeamLisp.Ns.Tutorial.Shared-lazy".check/3
```

## 1. Write a recipe, then ask for a value

Here is the syntax that matters:

```beam-lisp
(let [calls (atom 0)
      numbers (lazy-seq
                (swap! calls inc)
                (list 10 20 30))]
  (check "nothing calculated yet" 0 @calls)
  (check "first value" 10 (first numbers))
  (check "one calculation" 1 @calls)
  (check "same first value" 10 (first numbers))
  (check "still one calculation" 1 @calls))
```

```bl-result cell1
nothing calculated yet ok
first value ok
one calculation ok
same first value ok
still one calculation ok
:ok
```

Read that slowly:

- `let` gives names to local values.
- `(atom 0)` creates a shared mutable counter. `@calls` reads it.
- `(swap! calls inc)` increases it. This makes the hidden calculation visible.
- `lazy-seq` delays its body.
- `first` asks for the first sequence value, triggering the delayed body.
- The successful answer is remembered. That remembering is **memoization**.

The counter is teaching equipment. Prefer pure calculations in lazy bodies;
we will discuss effects and failures below.

Notice that this one lazy body returns a whole three-element list. Laziness
belongs to the deferred body, not automatically to every expression inside
it. Asking for the first element runs that whole body.

## 2. Build a sequence that has no final element

A lazy body can return a head followed by another lazy sequence. `cons`
constructs that head-and-tail pair.

```beam-lisp
(defn counting-from [n]
  (lazy-seq
    (cons n (counting-from (+ n 1)))))

(check "five numbers" [100 101 102 103 104]
       (vec (take 5 (counting-from 100))))
```

```bl-result counting-from
five numbers ok
:ok
```

Why does this recursion stop long enough to return?

Calling `counting-from` creates a deferred body. When that body runs, its
recursive call creates the *next* deferred body; it does not calculate the
entire future. `take` asks for a finite prefix, and `vec` collects that prefix
into a vector so we can compare it.

Do not ask for the count of the entire infinite sequence, or convert all of it
to a vector. Neither operation can finish. Laziness makes finite observations
of an infinite recipe possible; it does not make infinite work finite.

Also, lazy does not always mean “one element per request.” Some collection
operations work in chunks. A request for one element can calculate a small
batch. Do not use lazy traversal as a precise schedule for external effects.

## 3. Two readers can share one recipe

The identity of the lazy value matters. Giving another name to the same value
does not create another calculation.

```beam-lisp
(let [calls (atom 0)
      shared (lazy-seq (swap! calls inc) (list :ready))
      another-name shared]
  (check "first reader" :ready (first shared))
  (check "second reader" :ready (first another-name))
  (check "one shared calculation" 1 @calls))
```

```bl-result cell3
first reader ok
second reader ok
one shared calculation ok
:ok
```

Calling a *factory* twice is different: each call creates a new lazy value.

```beam-lisp
(let [calls (atom 0)
      make-value (fn [] (lazy-seq (swap! calls inc) (list :ready)))
      a (make-value)
      b (make-value)]
  (check "factory value a" :ready (first a))
  (check "factory value b" :ready (first b))
  (check "two independent calculations" 2 @calls))
```

```bl-result cell4
factory value a ok
factory value b ok
two independent calculations ok
:ok
```

The runtime does not compare the source text of two recipes and decide to
merge them. Sharing comes from sharing the value you already created.

## 4. Share across BEAM processes

The BEAM is the virtual machine running Beam Lisp. Its processes are small,
isolated units of execution. `Task` is an Elixir module that starts work in
one of those processes; the `Module/function` spelling is normal interop.

```beam-lisp
(let [calls (atom 0)
      shared (lazy-seq (swap! calls inc) (list :ready))
      left (Task/async (fn [] (first shared)))
      right (Task/async (fn [] (first shared)))]
  (check "left task" :ready (Task/await left 5000))
  (check "right task" :ready (Task/await right 5000))
  (check "shared across tasks" 1 @calls))
```

```bl-result cell5
left task ok
right task ok
shared across tasks ok
:ok
```

Both tasks refer to the same lazy identity. One evaluates it; the other either
waits for that attempt or reads the completed answer. Which task goes first
is deliberately unspecified. This small example does not force an overlap;
a concurrency test needs explicit synchronization to prove the waiting path.

Both tasks hold handles to one native memo cell. Ordinary BEAM terms do not thereby become a shared mutable heap: the
resource identity is shared, while BEAM terms retain their normal semantics.

## 5. A local name can disappear while its value stays useful

Leaving a `let` is not the same as making its values unreachable. A function
can capture a value and keep using it later.

```beam-lisp
(defn make-reader []
  (let [values (lazy-seq (list 42))]
    (fn [] (first values))))

(let [read-answer (make-reader)]
  (check "capture survives return" 42 (read-answer))
  (check "capture remains reusable" 42 (read-answer)))
```

```bl-result make-reader
capture survives return ok
capture remains reusable ok
:ok
```

`make-reader` returns a function. That function retains `values`, even though
the local name inside `make-reader` is no longer in scope.

This is why a memory policy cannot simply say “delete all memo entries when
the function returns” or “when the creating process exits.” Returned values,
messages, captured functions, and global definitions can keep them alive.

**Ownership must follow actual references, not source-code indentation.**

## 6. Why remembering answers can retain too much memory

ETS is a table managed by the BEAM. A global ETS memo table can look like this:

```text
lazy value ── key ──> global table ──> remembered answer ──> lazy tail
```

The table is a strong owner of its stored terms. Losing the caller's lazy
value does not tell the table to delete its entry. Garbage collection cannot
remove a value that the table still owns.

A memory budget is useful containment: refuse more work rather than consume
all available memory. But it does not answer the ownership question. A larger
budget changes when the program runs out of room, not which entries are safe
to release. An admission check also cannot predict how large an unevaluated
recipe's eventual result will be.

Deleting arbitrary entries is not safe either. A live caller might still need
the remembered answer. Re-evaluating the recipe could repeat an effect or
produce a different result.

## 7. The memo cell: no new author syntax

The source remains ordinary Beam Lisp:

```beam-lisp
(check "ordinary lazy syntax" :hello
       (first (lazy-seq (list :hello))))
```

```bl-result cell7
ordinary lazy syntax ok
:ok
```

There is no `free`, `retain`, `publish`, or ownership annotation for
sequence authors. Those would make ordinary sharing much harder to use.

The runtime gives a lazy value a handle to a **native resource**:
a small object whose lifetime can be tied to the BEAM's resource references.
Rustler is a way to implement such objects in Rust and expose them through
native functions, called NIFs.

Conceptually:

```text
process A ── handle ──┐
                     ├──> memo cell ──> remembered result
process B ── handle ──┘
```

The cell owns the deferred recipe as well as its result. After a
successful evaluation, it releases that recipe and its captured inputs,
keeping only the answer. Leaving a copy of the recipe in every handle could
retain large input sequences even after the calculation finishes. A retryable
failure still needs its recipe; a completed success does not.

No permanent registry owns these cells. A native dependency graph stores
integer identities, not strong resource handles. Completed state and captured
values live in the resource itself. Active evaluators and waiters retain the
handles they need; destroying the final handle removes its graph entry.

A cleanup worker releases saved environments iteratively, so discarding a long
chain does not recurse down a native stack. The library's unload callback drains
and joins that worker before its code can be unloaded.

Once the last reference is gone, the resource can become reclaimable. That is
not a promise of immediate deallocation at the end of a `let`, nor a promise
that operating-system memory statistics fall immediately. Collection timing,
allocator reuse, and resource cleanup are separate concerns.

### The state machine inside

These are design states, not additional language syntax:

```text
Unevaluated ── claim ──> Running ── success ──> Completed(value)
                           │
                           ├── known exception ──> Failed(attempt)
                           │                         │
                           │                  later explicit retry
                           │                         └──> Running
                           │
                           └── ambiguous owner loss ──> Terminal(error)
```

Native operations claim or inspect a cell. The winning BEAM process runs
the Lisp body. Publication and notification of attached waiters occur together
inside one native operation, so an evaluator cannot die between committing its
answer and notifying its waiters. Waiters receive their own attempt's outcome,
even if another caller has already started a retry.

Native operations that can copy large terms or traverse the dependency graph
run on dirty CPU schedulers, not ordinary BEAM schedulers.

**Lisp evaluation stays on the BEAM.** The language interpreter has not moved
into Rust. No native lock should remain held while arbitrary user
code runs, and waiting must not block a BEAM scheduler.

The native layer adds platform build and packaging work. Incorrect native
code can affect the whole VM, so its API should be small and its tests strict.

## 8. “Once” needs a failure rule

Successful memoization and exactly-once external effects are different
promises.

The current runtime shares a successful result. Callers attached to a known
failed attempt receive that failure; a later force may retry. Effects that
occurred before the exception may therefore happen again.

If an evaluating process disappears, the runtime may not know whether its
external effect already happened. Silently retrying would be unsafe. The
owner-loss path is terminal rather than an invitation to repeat the recipe.
Recursive forcing also needs an explicit error instead of a self-deadlock.

The native ownership implementation preserves these distinctions. It
cannot promise exactly-once payments, file writes, or network
requests merely because two callers share a lazy value. Keep external effects
in an explicit workflow with its own retry and idempotency rules.

## 9. What keeps a sequence alive?

Several ordinary references can retain a lazy value:

| Reference | Why it matters |
|---|---|
| A local still used later | A later expression needs the same value. |
| A captured function | Calling the function can use the sequence again. |
| A global `def` | The namespace still offers the value to future callers. |
| A queued message | The receiving process has not consumed it yet. |
| The head of a realized sequence | Its remembered tails can retain the traversed prefix. |
| An active evaluator or waiter | The current attempt still needs its cell. |

For bounded-memory streaming, advancing the consumer is not sufficient if
another reference keeps the original head. Let consumed prefixes become
unreachable; do not accidentally store every prefix in a log or global value.

Lazy results are no longer kept in a global ETS table. Metadata also lives on
the value, not in a permanent identity-indexed table. Adding metadata preserves
the shared memo: annotating a sequence does not replay its recipe.

There is still an important finite-input tradeoff: collection operators use
shared cursors over large, already-eager lists and vectors. Each native input
is copied once, and deferred tails retain small cursor handles rather than
copying the remaining list at every chunk. That removes quadratic input copying.
The finite input storage stays alive while any cursor needs it; this is not a
promise to free prefixes of that storage individually. A genuinely lazy input
is not eagerly consumed merely to create a cursor.

### The hard case: cycles

Two memo cells can indirectly retain one another. Reference counting alone
cannot reclaim every such cycle. A Rustler resource is not automatically a
tracing collector for an arbitrary graph of native-held terms.

This implementation rejects an update that would create a cycle among memo
cells. It scans ordinary tuples, lists, maps, function captures, and metadata
for handles; native graph validation checks their transitive dependencies.
A rejected result becomes a terminal `cyclic_memo` error. It is not returned
successfully to the evaluator and secretly rejected for everyone else.

This is cycle rejection, **not** general tracing garbage collection. An opaque
third-party NIF resource can hide references that this scanner cannot inspect.
Do not construct ownership cycles through foreign native containers and expect
this memo graph to collect them. Recursive evaluation is separately rejected
with `recursive_force`; cyclic retained values need not have been evaluated
recursively to be invalid.

## 10. What this enables—and what it does not

Because temporary lazy values have reclaimable ownership, a compiler can discard
intermediate sequences after compiling a file. A development daemon can run
many compilations without retaining every temporary sequence from every run.
Shared deferred work also becomes easier to reuse between processes without
repeating successful calculations.

The same ownership primitive could eventually support promises or shared
memoized computations. Those are potential uses, not new public APIs supplied
by this tutorial.

Memory ownership does not decide which compiled files are fresh. Lazy AOT
still needs a trustworthy compiler generation; compiler reload still needs
safe publication of code. These are separate contracts.

## 11. How to know the runtime design is correct

The executable examples establish the author-facing meaning. The ownership
implementation is also exercised by native and host tests. Its acceptance
criteria are:

1. Synchronize many callers on one cell and prove that one attempt runs.
2. Preserve results when handles cross processes or escape in closures.
3. Exercise exception retries, evaluator death, memo-owner loss, and recursive
   force without duplicate ambiguous effects or stranded waiters.
4. Create and discard many cells, collect, and measure retained cells and
   memory. Verify a plateau over repeated batches, not one convenient sample.
5. Keep a deliberately live handle during that test and verify it still works.
6. Exercise chains, shared tails, and cycles with explicit expected lifetimes.
7. Compile the toolchain repeatedly and verify that temporary memo retention
   does not grow with every completed compilation.

Do not turn an allocator's delayed release into a flaky exact-byte assertion.
Use resource-lifetime instrumentation and bounded memory trends together.

```beam-lisp
(println "Shared lazy values: all checks passed")
```

```bl-result cell8
Shared lazy values: all checks passed
:ok
```

## Keep exploring

- `priv/boot/core.bl`: the `lazy-seq` macro wraps its body in a zero-argument
  function—a **thunk**, meaning a recipe with no arguments.
- `lib/beam_lisp/lazy_seq.ex`: realization, sharing, waiting, failure, and memo
  retention semantics.
- `lib/beam_lisp/lazy_memo.ex`: native loading, dependency discovery, and soft
  live-memory admission checks.
- `native/lazy_memo/src/lib.rs`: cells, atomic publication, cycle checks,
  shared input cursors, and resource cleanup.
- `lib/beam_lisp/seq_cursor.ex`: the finite-input chunk adapter.
- `test/beam_lisp/lazy_memo_native_test.exs`: native lifetime and cursor checks.

Building from source requires Cargo when a current native artifact is absent.
The normal Mix build installs the library before compiling `.bl` sources.
A release carries it in the application's `priv/native` directory. Restart the
VM after changing native runtime modules: live NIF upgrades are deliberately
unsupported.

`BeamLisp.LazyMemo.stats()` exposes `live_cells`, `retained_bytes`, and
`pending_reclaims`. These describe native memo/input storage, not the whole VM.
`retained_bytes` is a live-term estimate, not an exact RSS measurement or a hard
allocator limit; pending cleanup and shared binary storage are separate costs.
The configurable `lazy_cache_budget_bytes` remains a soft admission guard.
It never evicts a live answer to make room.
- `test/beam_lisp/wave23_lazyseq_test.exs`: runtime regression cases, including
  cross-process attempts and failures.

The central idea is small: **share the answer while someone needs it, and let
ownership—not a permanent table—decide how long it lives.**
