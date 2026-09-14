# Searching code by meaning

`grep` finds what you can name. Most questions about code cannot be named.

> where do we check that a transaction's schema is valid

No function is called `check-transaction-schema-valid`. The words are in prose,
not in identifiers, and the only way to reach the code that means them is to
search for what the code *means*. Asked over `priv/`, that question answers:

```
datom.db/schema-of            0.48
datom.schema/validate-value   0.45
datom.conn/schema             0.45
```

This is how that works in beam-lisp, and what it costs.

## What it answers

Four questions, all of them asked of beam-lisp's own source in the runs below:

* **Behaviour you cannot name.** "parse a number out of a string" →
  `datom.time/parse-int`, `datom.time/parse-point`. No keyword in the question
  appears in either function.
* **The sibling you forgot.** `bl search --like datom.tx/validate` →
  `datom.tx/expand-store-ops`, `datom.tx/uniqueness-violation`,
  `datom.tx/map-form->ops`. Near-duplicate code scores high, which makes this an
  overlap radar before a refactor.
* **One namespace.** `--ns datom.file "read a file from disk"` — the same
  question asked of a subsystem.
* **Meaning AND structure in one query.** `code.semantic/search-returning`
  answers "nearest among the functions that return a string" — the candidate
  set comes from a datom, the ranking from the model. Two kinds of knowledge,
  one query, because an embedding is a fact like any other.

The last one is the shape that generalises: any fact in the index can narrow a
search, and any function's own embedding can be a query vector (`similar`),
because a vector is a value — there is nothing special to build.

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

**It is small enough to be a default.** 83 MB of resident weights against a
transformer's 644 MB is the difference between "the language ships a semantic
tier" and "the language needs a GPU box".

**It is fast enough to re-do.** The 177 functions of beam-lisp's own datom layer
embed in 27–36 ms, or about 0.17 ms per function, once the model is loaded
(266–278 ms, paid on the first call). Indexing a whole checkout costs seconds,
which means the index does not need an invalidation story elaborate enough to be
worth caching.

**It is not a replacement for grep.** A static model scores *below* BM25 on the
CoIR code-retrieval benchmark, and the hybrid of the two scores above both. The
honest conclusion is not "use embeddings instead" — it is that lexical and
semantic fail on different questions, and a system that can only ask one of them
is worse than one that can ask either.

## The model is data, and lives where data lives

The weights are downloaded, sha256-pinned (three files, and the digest of
`model.safetensors` is the model's identity), and read from the FIRST of three
roots that holds a complete copy:

| root | who puts it there | who reads it |
|---|---|---|
| `$BEAM_LISP_MODEL_DIR` | you, explicitly | anything — an explicit pin is an ANSWER, never a fallthrough |
| `<drop>/priv/embed/potion-code-16M-v2` | `mix bl.build`, so the `bl` you install already carries it | a drop: no network, no Mix, no cache needed |
| `$XDG_CACHE_HOME/beam_lisp/models/…` | `mix bl.embed.fetch` (its default) | a source checkout — one copy per machine, not per worktree |

The middle root is why the shipped `bl` can answer at all: a drop carries no
Mix, so "fetch the model first" is not an instruction a drop's user can follow.
The weights travel inside it, and `--no-embed` is the one way to build a drop
without them. The third root is why a working tree carries no 33 MB per branch:
the bytes are identical everywhere on the box, so they are cached rather than
copied per checkout — the z3 precedent buys nothing here.

What makes a copy identifiable is the `DIGEST` file the fetch writes LAST, after
every weight has verified against its pinned sha256: a partial download must not
look like a model, and weights with no digest have no provenance — the digest
is what identifies the vector space every stored embedding was made in.

Nothing at query time touches the network. Only a fetch does, and after one
fetch (or one build) search runs with the cable unplugged.

Absence is the ordinary state of a checkout that has neither fetched nor built,
so absence reads as absent — and names every root it looked in, which is also the
diagnosis (the shape of that message is under `bl search` below).

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

That the weights really are off the heap is measurable, not a claim: loading the
model moves RSS by 83 MB (85 028–85 120 kB across three runs) and the BEAM's own
`erlang:memory(total)` by **43–51 KB**. The whole vector column costs the heap
1.5 MB for 177 embeddings — where it belongs.

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

## One door into the index

Everything that indexes goes through `code.semantic/index!`, and under it
through one chain:

```
index!            a set of [ns path] — the only entry point, one band per file
  └ index-source! one file: facts + one embedding per function, ONE transaction
      └ cached-facts  the project's store, keyed by sha256(source)
```

That is deliberate, and it is what keeps three callers from drifting apart. The
`bl search` command, the examples, and the tests all ask for an index in the
same words and get the same answers: the same cache, the same entity bands, the
same behaviour on a file that cannot be read. A second loop in a caller is how
two indexers start disagreeing about what "indexed" means.

Three properties belong to the door rather than to any caller:

* **Cached analysis.** Facts come from the project's store, because an analysis
  is a pure function of the source bytes: nothing re-analyzes an unchanged file.
  `codebase/blanalysis-dir` resolves in four tiers — `$BL_CACHE_DIR` (set it and
  nothing else is consulted: the store goes where you point, which is the CI
  lever, and it moves ONLY the store — the embedding weights resolve through
  `BeamLisp.Model` instead (pin, bundled, or cache), so
  `XDG_CACHE_HOME` is not a substitute for it), else `$BLANALYSIS_DIR` (the
  per-call spelling tests use), else `<project>/.local/bl/cache`, else
  `$XDG_CACHE_HOME/beam_lisp/cache/<tree id>` for a project that cannot be
  written to: an installed drop, a mounted checkout, a CI read-only bind. The
  fourth tier is keyed by the same 16-hex tree id a `bl` daemon uses, so
  re-extracting a payload finds its analysis again instead of paying for it
  twice. The project is the nearest ancestor of the corpus that looks like one
  (a `.git`/`.hg` root, `mix.exs`, `priv/boot/core.bl`, an extracted drop's
  `bin/bl` + `releases/`); with none, the corpus you pointed at is the project —
  never the filesystem root. `.local/bl/` is gitignored, and `bl doctor` reports
  the directory.
* **The source questions cache their analysis too.** `bl ask symbols` and
  `bl ask dead-code` are answered from `lsp/document-symbols`, which costs
  seconds a file cold, and that analysis is remembered as `<kind>.<sha>.term`
  beside the stores — same content address, same project rule, same eviction,
  because an entry is one artifact whether it is a store or an analysis. The two
  questions share the one analysis, so `dead-code` — which needs the symbols for
  both its passes — pays for it once, and a question over an unchanged file
  re-reads it instead of re-deriving it.
* **The stores accumulate, so a cap and a verb exist.** One store per (source,
  source revision) means every edit mints a new one and the old one is garbage
  the moment the source moves on. `bl cache status` shows what a tree holds, per
  directory, and whether the total is over the cap (`BL_CACHE_MAX_MB`, default
  2048 MB); `bl cache prune [--max-mb N] [--dry-run]` deletes the OLDEST stores
  first and never the newest, which is the one the run that just finished wrote.
  `bl search` prunes after it indexes, so the ceiling holds without anyone
  remembering it.
* **The vectors are IN that store.** `:fn/embedding` is a COLUMN of it, not a
  second cache: the same file, the same sha, the same reopen. One marker datom
  on entity 0 records which model filled the column (`fn/embedding=potion-
  code-16M-v2@75cf7a6c`), so a warm file is not sliced and the model is not
  called at all — and a NEW model refills the column without touching a fact.
  That column is why a warm run costs seconds rather than minutes.
* **Several files at once.** One file's index is CPU-bound and touches nothing
  shared, so `code.semantic/index!` analyzes up to four files in parallel and
  MERGES them in input order. The seam is deliberate: an in-memory connection's
  tables belong to the process that opened it and a store's writer is one
  process, so workers analyze and the caller transacts. `$BL_INDEX_WORKERS`
  moves the count (`1` is the serial path — the same code with a fan-out of
  one). Measured on 10 cold files: 8869 ms serial against 6425 ms at four
  workers — 1.4x, where four separate PROCESSES on the same files get 4x
  (2443 + 1597 + 1894 + 2701 ms of index time, run concurrently). The serial
  fraction is inside the VM rather than in the box, and that gap is filed
  rather than papered over. A warm corpus does not care either way: the same
  10 files index in 2377 ms.

* **A corpus is remembered whole.** The per-file stores still cost one OPEN each,
  and a 101-file corpus is 101 fjall directories to open and pull. So the
  analysis of a whole corpus is also memoized as a single artifact beside them,
  under the same cap and eviction: `manifest.<key>.term`, where the key is the
  model plus every source's hash IN ORDER (source `i` owns the id band
  `(offset-for i)`, so order is part of the corpus's identity). A run over
  byte-identical sources reads that one file; anything else — an edit, an
  addition, a deletion, a model change — misses, and the stores answer for
  exactly the files that moved. The footer says which happened (`· corpus cached
  101/101`). A memo that is there and unreadable is a MISS WITH A NAME, never a
  silent fallback.

  Measured on 101 files: 113454 ms warm (96 of 101 stores reopened) against
  96802 ms with the memo — so the opens are about HALF a warm run, and the other
  half is the merge: `shift-ids` plus a transaction per file into the in-memory
  connection the query runs against (FUP-067). The memo removes the half it can.

* **Banded ids.** Each source gets its own million-wide id band (`offset-for`),
  because `codebase/index-source` numbers entities from a fixed base and two
  files sharing a conn would otherwise silently overwrite each other.
* **Resilience with a name.** A source the analyzer cannot read yields
  `{:file path :skipped reason}` instead of aborting the set — and the caller is
  expected to SAY so. An index one file smaller that reports itself as complete
  is worse than a crash.

One transaction per file is the last part of the shape: the facts and the
vectors that describe them commit together, so no query can find an embedding
whose function does not exist yet.

## `bl search` — the same question, from the shell

```sh
bl search "where do we check that a transaction's schema is valid?" -p priv
bl search "read a file into lines" -p src -k 5
bl search --like datom.tx/validate -p priv          # more like this
bl search "ship an order" --ns my.orders -p src      # one namespace
```

Four flags, no new vocabulary: `-p` is the library-root flag `bl run` already
takes (and the roots are the corpus), `-k` is how many hits come back (10 by
default), `--ns` narrows to one namespace, and `--like NAME` asks the other
question — functions that look like `NAME` — instead of a question in English.

`bl ask` is the neighbouring verb, and it answers a different kind of question:
it walks the codebase's FACTS (who calls this, what breaks if I change it),
while `search` ranks functions by what they MEAN. Two questions, two verbs —
asking one with the other's tool is how you get a plausible answer to a
question you did not ask.

`search` is one `lazy` entry in `bl.cli` (`"search" (lazy "bl.search")`), which
is what keeps the optional dependency optional: the CLI does not load the
feature's source until someone asks for it, so a checkout with no model weights
answers every other verb at the same cost and never fails on their behalf.

Exit codes are the CLI's usual three: `0` a search ran, `1` something broke,
`2` the command line was wrong (no query, a `-k` that is not a number). A
missing model is `2` as well, and says so:

```
bl search: the model weights are not on disk — looked in <drop>/priv/embed/potion-code-16M-v2, ~/.cache/beam_lisp/models/potion-code-16M-v2 (`mix bl.embed.fetch` fetches them into the cache; a built `bl` ships them)
  a source checkout fetches the weights once, then searches offline forever:
    mix bl.embed.fetch
  a built `bl` carries them (`mix bl.build`; `--no-embed` leaves them out)
```

### What it costs

Measured on a laptop over beam-lisp's own `priv/` — 156 files, 2565 functions.
The index runs THROUGH the project's store, and the vectors are a COLUMN of
that same store, so the first run pays for the analysis and everything after it
pays for a reopen:

| phase | first run (no store) | every run after |
|---|---|---|
| read the sources (they must be hashed) | 17 ms | 17 ms |
| analyze them (`codebase/analyze-cached`: miss → hit) | **~520 s** | 5–10 ms per file |
| derive the vectors (`:fn/embedding`, a column) | ~0.5 s (0.2 ms each) | **nothing — read from the store** |
| answer one question | ~300 ms | ~300 ms |

Both runs of one question, over `priv/lib` — 101 files, 1,623 functions — with
the analysis store deleted first:

```
$ rm -rf .local/bl
$ bl search "read a file into lines" -p priv/lib -k 3
3 of 1623 functions in 101 files  (index 178184 ms · query 187 ms)

$ bl search "read a file into lines" -p priv/lib -k 3
3 of 1623 functions in 101 files  (index 26933 ms · query 417 ms · cached 101/101 · vectors 101/101)
  mcp.transport-stdio/read-line-safe   line 27   0.7456977367401123
  mcp.tools/read1                      line 274  0.5515622496604919
  code.semantic/form-starts            line 88   0.5239207148551941
```

The same two runs on the corpus you actually work in — `priv/lib/code`, 2 files,
48 functions — where the store is created beside the sources. `status` counts
every entry in that directory: stores and the per-file analyses `bl ask`
remembers:

```
$ bl search "read a file into lines" -p priv/lib/code -k 3     # nothing cached yet
3 of 48 functions in 2 files  (index 7151 ms · query 29 ms)

$ bl search "read a file into lines" -p priv/lib/code -k 3     # everything cached
3 of 48 functions in 2 files  (index 2534 ms · query 1214 ms · cached 2/2 · vectors 2/2)

$ bl cache status
  104 entries  36 MB  /home/user/code/undefine/beam-lisp--semantic/.local/bl/cache
total 36 MB · cap 2048 MB (under)
```

`examples/code-semantic/01-search-by-meaning.bl` indexes eight real source files,
so its FIRST run pays the full cold analysis — 79 s measured — and reopens the
store in seconds after that. The example suite skips that file for this reason
(the mechanism it demonstrates is covered by `test/bl/code/semantic_test.bl`);
run the demo with `mix bl run`.

The footer says what the store earned. `cached 101/101` is every analysis
reopened; `vectors 101/101` is the stronger claim: no source was sliced and the
model was not called once. The two runs answer with the same three functions and
the same scores, because they are the same vectors.

27 s for 101 files is ~270 ms a file — a store reopen plus a pull of the facts
AND their vectors (an embedding is a blob, so both indexes are read). Nothing
in that is the model or the reader; a per-stage timer is the next thing to
build, rather than a guess about which half dominates.

ANALYZING is the first run's whole cost, and it is seconds PER FILE —
macroexpansion of every form: 0.7 s for a small file, 30 s for
`priv/boot/compiler.bl`. The cache is content-addressed (sha256 of the source),
so an unchanged file is a REOPEN: measured per file, 180–2300 ms cold against
5–10 ms warm.

What a warm run still pays is the part that is not cached yet: the facts are
read back out of each store (a scan, 50–350 ms per file) and the embeddings are
recomputed. Measured end to end over the 100 files of `priv/lib` (1591
functions): **first run 448 s, warm run 83 s**. Closing that gap is a known next
step rather than a mystery — the embedding column can live in the SAME
content-addressed store the analysis does, one more column of the same facts,
and then a warm run is a reopen and nothing else.

A file the analyzer cannot read is skipped and NAMED, never silently dropped:

```
bl search: skipped priv/boot/core.bl — if-let requires a vector for its binding
```

(That one is a real limit of the analyzer, not of the CLI: expanding a macro
template definition that contains a syntax-quoted call is not something the
call-walker can do yet.)

## The live part costs nothing

An embedding is a fact, so "keep the index current" is not a subsystem:
re-index the file that changed, and a watch on `[?e :fn/embedding ?v]` reports
exactly which embeddings moved. No polling, no diffing layer, no separate
invalidation protocol — the database already tells you when a fact changes.

`examples/code-semantic/02-live.bl` runs that loop: ask a question whose answer
does not exist, add the function, re-index, ask again.
