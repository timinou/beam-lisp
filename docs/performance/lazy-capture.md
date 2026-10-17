# Lazy cells and what they capture

Every lazy cell (`map`, `filter`, `for`, `keep`, … over a seq) is created with
the memo resources its thunk can reach, so the native graph can invalidate it.
Finding them means walking the thunk's **captured environment**
(`BeamLisp.LazyMemo/dependencies`). A thunk that closes over a big value — a
hydrated world, a render snapshot — would pay a walk of that whole value for
every cell it creates.

## What the runtime does about it

- A value proven to hold no resource is remembered **by identity** (BEAM terms
  are immutable: the same heap object always has the same contents). A later
  capture of the same object costs a pointer compare.
- This applies **at every depth** of the walk, not only to the top-level
  captured values: a small wrapper `{:snap snap :i i}` around a remembered
  snapshot costs O(1) per wrapper, and so does a 4-key world map
  `{"entities" big …}` whose big child is remembered.
- The memo is a per-process table bucketed by an O(1) shape key and holds up to
  256 values, so a render's working set of tens of live big values does not
  thrash (it was a 16-entry list).
- A value that **does** hold a lazy seq, memo handle or function is never
  remembered; its dependencies are reported every time. No edge is lost.

Measured on the walk path (40 captures, a 1 700-record world):

| shape | before | after |
|---|---|---|
| 40 small wrappers around one snapshot | 36 ms | 1.2 ms |
| a 4-key world map, 40 captures | 38 ms | 0.12 ms |
| 18 distinct big values, rotated 3× | 52 ms | 23 ms |

## What app code can do

- Prefer eager `mapv` / `filterv` / `reduce` in hot render paths: no cell, no
  walk. A vector of elements is a valid child list in hiccup
  (see `grammar-of-the-web.md`).
- For a large value captured by many lazy pipelines, declare it plain once:

  ```clojure
  (BeamLisp.LazyMemo/plain! world)   ; returns world
  ```

  The contract is yours: declare only values that hold no lazy seq, memo
  handle or function (plain hydrated data). Declaring a value that does hides
  that dependency from cells that capture it. When unsure, don't — the walk
  proves cleanliness on its own, once per value.
