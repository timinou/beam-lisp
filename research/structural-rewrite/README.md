# Trivia-preserving structural rewrite

The fix for `deodorant/fix-source`'s `pr-str` collapse — built from first
principles on the reader's end-spans (Phase 1 of the one-form work).

## The problem

`fix-source` splices `(pr-str fixed)` at a smell's span. `pr-str` re-renders the
whole matched subtree on one line, so multi-line captures and every comment
inside them are destroyed. Measured on the engine tree: a sweep dropped
`ir.bl` 249→238, `model.bl` 364→340, `smt.bl` 533→496 lines — comments gone. A
blanket run is unusable; only single-line smells splice cleanly.

## The fix

Every reader node now carries a full span `{:line :col :end-line :end-col}`. A
rule's capture variables (`?x`) bind to whole sub-**nodes**. To rewrite, we
slice each capture's **original source bytes** out of the file and splice them
into the new skeleton; only the rule's own literal tokens are newly rendered.
Everything the rule did not name stays byte-identical.

## Measured (same input, a multi-line `if` with a comment)

Input:
```clojure
(defn process [items]
  (if (not (empty? items))
    (do
      ; keep the good ones
      (filter good? items))
    nil))
```

`fix-source` → `(if (not P) A nil)` reduced to `when-not`:
```clojure
(defn process [items]
  (when-not (empty? items) (do (filter good? items))))     ; COMMENT GONE, do collapsed
```

`span-rewrite` → same rule, capturing `?a` = the whole `do` block:
```clojure
(defn process [items]
  (when (empty? items) (do
      ; keep the good ones
      (filter good? items))))                              ; comment + shape PRESERVED
```

Both reparse; the span-rewrite output is byte-identical to the input everywhere
outside the `if`→`when` skeleton.

## Files

- `span_rewrite.bl` — `line-offsets`, `slice-node`, `node-match` (structural
  match over reader nodes), `rewrite-source` (whole-tree, non-overlapping,
  right-to-left splice).

## Productionization

Fold into `deodorant`: a smell already carries a pattern; add a `:render` that
composes original slices instead of `pr-str`. Then the blanket sweep the user
asked for becomes safe — every idiom fix across every `.bl` file, comments and
formatting intact. This is what makes `deodorant fix --all` a first-class command.
