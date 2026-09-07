# tooling.incremental — render only what changed

A live view normally works like this: something changes, so the whole view
re-renders into a fresh hiccup tree, and a differ compares the new tree against
the old one to discover what actually moved. The rendering is total; the diff
does the finding.

That is backwards when most of the screen did not change. If a keystroke touches
one field, you should not rebuild the header, the sidebar, and the table just to
discover they are identical. `incremental` flips it: let each piece of the view
be a value that **knows what it depends on**, so a piece recomputes only when its
own inputs move. The diff then confirms a small change instead of searching a
whole tree for it.

The mechanism is already in the language. A `derived` recomputes only when a
dependency's value changed; a `memoize`d component returns the *identical*
hiccup for the same inputs. And the live differ short-circuits on equal
subtrees — `(= old new)` yields zero patch ops. Put those together and unchanged
parts of the screen cost nothing to re-render and nothing to diff.

```beam-lisp
(ns tooling.incremental)
```

## A component that remembers its output

`component` wraps a render function so that, given the same inputs, it returns
the *same* hiccup value — not an equal-but-fresh one, the memoized one. When the
differ meets that identical subtree, it stops: no walk, no ops.

```beam-lisp
(defn component
  "Wrap a pure render fn (inputs -> hiccup) so equal inputs return the identical
   hiccup, letting the differ prune that subtree. This is `memoize` named for
   its role in a view."
  [render-fn]
  (memoize render-fn))
```

## A subtree wired to its own state

`subtree` builds a piece of view as a `derived` over the refs it reads. It
recomputes only when one of those refs actually changed, so a part of the screen
tied to `body-state` is untouched when only `header-state` moves. Deref it (with
`@`) where you compose the view.

```beam-lisp
(defn subtree
  "A view piece as a derived over `deps` (atoms/deriveds) and a `render` thunk
   returning hiccup. It recomputes only when a dep's value changes; between
   changes it returns its cached hiccup, which the differ prunes."
  [deps render]
  (BeamLisp.Reactive/derive deps render))
```

## Why this makes rendering incremental

Two facts compose:

- **A memoized/derived piece returns identical hiccup when its inputs are
  unchanged.** Not merely equal — the same value.
- **The differ short-circuits on `(= old new)`** with zero patch ops
  (`live.diff`, the identical-subtree branch).

So when one field changes, only the piece that reads it recomputes; every other
piece hands back the value it already had, and the differ skips each of them in
O(1). Rendering stops being "rebuild everything, then find the change" and
becomes "recompute the one thing that moved." Measured on a three-row board
where one row's text changed: one row recomputed (not three), and the diff
produced one op (not a full-tree walk). On a header/body split where only the
body's state changed: the header recomputed zero further times, and the diff was
one op.

## What stays true

- **Correctness is unchanged.** The differ still produces exactly the ops that
  turn the old tree into the new one; incremental rendering only makes the
  unchanged parts cheaper to produce and to compare.
- **Purity is the contract.** A component memoized on its inputs must be a pure
  function of those inputs; a side-effecting render does not belong here.
- **It composes, it does not replace.** `incremental` is ordinary values —
  `memoize` and `derived` — arranged for rendering. There is no framework and no
  new render loop; the existing mount/commit/diff/patch path is untouched.
