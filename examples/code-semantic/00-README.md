# code-semantic — asking beam-lisp's source questions in English

Semantic search over the codebase, as a *column* of the codebase's own fact
database. Ask

> where do we check that a transaction's schema is valid

and get `datom.conn/schema`, `datom.conn/run-tx-pipeline`, `datom.conn/transact!`
— functions whose names share no word with the question.

## Run it

```sh
mix bl.embed.fetch                        # once: 33 MB, offline after
mix bl run --path priv --path examples examples/code-semantic/01-search-by-meaning.bl
mix bl run --path priv --path examples examples/code-semantic/02-live.bl
```

| # | file | what it is |
|---|---|---|
| 01 | `01-search-by-meaning.bl` | the **script**: index a corpus, run five kinds of query, print the answers |
| 02 | `02-live.bl` | the **live session**: interactive when a terminal is attached, scripted otherwise. Edit source, re-index, watch the answers change |

## The model is OPTIONAL, and that is the design

The weights are 33 MB of *downloaded* data — not source, not something
`mix compile` produces. So absence is the ordinary state of a fresh checkout,
and everything here is gated on it:

* `code.embed/available?` answers whether semantic search can run at all;
* `code.embed/require-model!` throws a message the example runner classifies as
  an **absent optional dependency** — the examples suite reports these two
  examples as SKIPPED, not as failures;
* requiring `code.embed` loads nothing. The model handle is a `delay`, so the
  33 MB is read on the first call that needs it, never on `require`.

| state | behaviour |
|---|---|
| no model fetched | `code.embed/info` names the fix: `mix bl.embed.fetch` |
| no Rust toolchain (NIF unbuilt) | same — reported as absent, never as present-but-broken |
| model cached | fully offline: nothing at query time touches the network |

## What it costs

Measured on this machine (AMD Ryzen AI 7 350), `VmRSS` from
`/proc/self/status` over three runs, with `erlang:memory(total)` beside it to
separate the BEAM's heap from everything else:

| | cost |
|---|---|
| boot with `datom`, model not required | VmRSS 156–176 MB (what is required varies) |
| `code.embed` + `code.semantic` required, model NOT loaded | no measurable change |
| model loaded | **+83 MB VmRSS** (85 028–85 120 kB), **+43–51 KB** of BEAM heap |
| first embed after load (safetensors parse + tokenizer build) | 266–278 ms, once |
| 177 functions / 160 288 characters | **27–36 ms**, ≈ 0.17 ms per function |
| 177 embeddings live in the conn | 1.5 MB of BEAM heap |

Those last two rows are the point: the model's 83 MB is *Rust's*, not the
BEAM's — the heap moves 43 KB — and a whole codebase's worth of vectors costs
the heap about the size of a photograph.

Indexing *cost* in the demos is dominated by `codebase/index-source` (parsing
and walking), not by the model: the eight-file corpus takes single-digit
seconds of wall clock, of which tens of milliseconds are embedding.

## The two sentences to take away

**A vector is a fact.** An embedding is `[?e :fn/embedding ?v]` in the same conn
as `[?e :fn/name "search"]` — same transaction, same basis, same time axis. So
`[(similar-to :fn/embedding ?q 10) [?e ?score]]` is a datalog clause, and it
joins with everything else the codebase knows.

**A clause sees one entity at a time.** That is right for *generate* (the k
nearest of everything) and for *score* (how relevant is this one function). It
is the wrong shape for *the k nearest within a set*, which is why
`code.semantic/search-in` hands the whole candidate corpus to the vector kernel
at once. The long note in that namespace explains both wrong answers the clause
gives, because both of them are silent and both look plausible.

## Where the code lives

```
native/code_embed/          the Rust NIF: a static code embedding model, resident off the BEAM heap
priv/lib/code/embed.bl      availability, the delayed model handle, text → DVec
priv/lib/code/semantic.bl   indexing (one embedding per function, through the project's store), search, restricted search
priv/std/bl/search.bl       the `bl search` command: corpus → index → question → hits
lib/beam_lisp/model.ex      where a downloaded model lives on this machine
lib/mix/tasks/bl.embed.fetch.ex          the pinned fetch (sha256-verified)
docs/code-semantic-search.md            why this model, why a NIF, and what was rejected
```

Design notes, alternatives weighed, and the model comparison:
`docs/code-semantic-search.md`.
