# Searching code by meaning

`grep` finds what you can name. Most questions about code cannot be named.

> where do we check that a transaction's schema is valid

No function is called `check-transaction-schema-valid`. The words are in prose,
not in identifiers. The answer is `datom.conn/run-tx-pipeline` and the three
functions around it, and the only way to reach them is to search for what the
code *means*.

This is how that works in beam-lisp, and what it costs.

## A static embedding model is a lookup table

A transformer is not required to turn text into a vector. Distillation can
compress one into a matrix: every token in the vocabulary gets a row, an input
becomes the average of its tokens' rows, and the result is normalised. Nothing
attends to anything. An embed is a hash lookup and a mean.

That compression is extreme, and it is worth knowing by number.

| model | shape | params | weights on disk | NDCG@10 (CoIR) |
|---|---|---|---|---|
| `potion-code-16M-v2` | static, 256-d | 16M | 32 MB (fp16) | 39.1 |
| `potion-code-16M-v2` + BM25 | static + lexical | — | — | **43.4** |
| BM25 alone | lexical | — | — | 42.3 |
| `jina-embeddings-v2-base-code` | transformer, 768-d | 161M | ~644 MB (fp32) | higher |

Three facts sit in that table.

**It is small enough to be a default.** 84 MB resident against a transformer's
644 MB of weights is the difference between "the language ships a semantic tier"
and "the language needs a GPU box". The Rust side holds the f32 matrix; the file
on disk is half that.

**It is fast enough to re-do.** The 177 functions of beam-lisp's own datom layer
embed in 306 ms, or 1.7 ms per function. Indexing a whole checkout costs seconds,
which means the index does not need an invalidation story elaborate enough to be
worth caching.

**It is not a replacement for grep.** A static model scores *below* BM25 on the
CoIR code-retrieval benchmark, and the hybrid of the two scores above both. The
honest conclusion is not "use embeddings instead" — it is that lexical and
semantic fail on different questions, and a system that can only ask one of them
is worse than one that can ask either.

## The model is data, and lives where data lives

The weights are downloaded, sha256-pinned, and kept under
`$BEAM_LISP_MODEL_DIR` or `$XDG_CACHE_HOME/beam_lisp/models`. They are not in
`priv/` — the solver's precedent, and the wrong one here: a solver binary is
fetched per checkout, while a model is the same bytes for every checkout,
project and worktree on the machine, and copying it per tree buys nothing.

Nothing at query time touches the network. `mix beam_lisp.embed.fetch` is the
only step that does, and after it, search runs with the cable unplugged.

Absence is the ordinary state of a fresh checkout, so absence reads as absent:

```
code.embed/available?     can semantic search run here?
code.embed/info           what is live, and if nothing is, the command that fixes it
code.embed/require-model! a handle, or a loud error naming the missing piece
```

Requiring the namespace loads nothing — the handle is a `delay`. Calling it
reads 32 MB of weights once and keeps them.

## Where the weights live, and what crosses

`native/code_embed` is a Rust crate behind `defnative`, and its resource holds
the matrix. The alternative — a bl vector of 16M floats — is 16M boxed values
plus list overhead, and every embed crosses the boundary twice. Behind the
resource the arithmetic happens where the numbers already are.

A batch crosses **once**, as packed little-endian f32 bytes: one binary holding
`count × dim` floats. That is already the shape `datom.vector`'s `DVec` stores,
so the bytes get sliced by row and become vector bodies with no decode, no
re-encode, and no float ever boxed on the way through.

## A vector is a fact

An embedding is asserted like anything else:

```clojure
[?e :fn/embedding ?v]
```

Same conn, same transaction, same basis, same time axis as `[?e :fn/name
"search"]`. So similarity is a *clause*, not a service:

```clojure
[(similar-to :fn/embedding ?q 10) [?e ?score]]
```

The clause composes. It joins with the fn facts, the call graph and the type
facts in one query, and the query engine returns rows — not a ranked list from
somewhere else. That is the whole reason a vector database is not a separate
component here: there is nothing to keep in sync, because there is no second
system.

## The clause sees one entity at a time

A clause is evaluated per binding, and that shapes what you can ask.

**Generate** — the entity is free. `[(similar-to :fn/embedding ?q 10) [?e
?score]]` yields the 10 nearest of everything. This is the ordinary case.

**Score** — the entity is already bound. The clause scores *that* entity against
the query. Useful ("how relevant is this function to what I am looking for?"),
and it is what makes a bound entity column a filter rather than a rescoring.

**Nearest within a set** — not expressible, and the two ways of trying are both
silent.

Bind the entity from a pattern over a literal — `[?e :fn/ns "datom.tx"]` — and
the query returns *every* function in that namespace, each scored, unbounded by
`k`. It looks like a ranking. It is not one.

Bind the same pattern from an `:in` variable instead, and the engine carries the
variable as one set-valued binding, which the provider reads as a single bound
entity, matches nothing, and answers zero rows. An empty candidate set and an
empty answer are indistinguishable from the outside.

The k-nearest-within-a-set question is answered where the whole set is visible
at once — the vector kernel — which is what `code.semantic/search-in` does. It
is nine lines, and it is not a clause.

## What gets embedded

A function, as its qualified name followed by its source:

```
datom.vector/search
(defn search
  "The `k` nearest of `candidates` to `query` …"
  …)
```

Both halves earn their place. The name carries the identifier tokens a query may
name outright; the source carries the vocabulary a query describes but never
spells. The model was trained on exactly this pairing — a natural-language
question to a function body.

The slice runs from the function's first line to the next top-level form,
trimmed of the blank lines and `;; ── section ──` heading that introduce the
*next* function. Without that trim a function absorbs its neighbour's prose, and
the symptom is a ranking that is subtly wrong for a reason no error message will
ever name.

## The live part costs nothing

An embedding is a fact, so "keep the index current" is not a subsystem:
re-index the file that changed, and a watch on `[?e :fn/embedding ?v]` reports
exactly which embeddings moved. No polling, no diffing layer, no separate
invalidation protocol — the database already tells you when a fact changes.

`examples/code-semantic/02-live.bl` runs that loop: ask a question whose answer
does not exist, add the function, re-index, ask again.
