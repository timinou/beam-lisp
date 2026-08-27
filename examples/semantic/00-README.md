# Semantic similarity & graph ML, in the datom store

These examples show a **whole class of capabilities** that open up once
embeddings live in the database as ordinary facts: semantic search, hybrid
semantic-plus-structured queries, clustering, dimensionality reduction,
community detection, and — the apotheosis — a full **GraphRAG** pipeline over a
real book.

The thesis in one line: **a vector is just a fact.** Store an embedding as a
datom and it is durable, time-travelable, and transactional like every other
fact — and it *joins* with them. No separate vector database to keep in sync;
similarity is a query clause beside `:where` patterns.

## How to run

```
mix beam_lisp.run --path priv examples/semantic/01-embeddings.bl
```

Each file is self-contained and prints a narrated walk-through.

## The two halves

**01–10 run offline, instantly, deterministically.** They use a tiny built-in
*fake embedder* (`_embed.bl`) — a word-hashing scheme, NOT a real model — so the
mechanics and the query syntax run for real with zero network. Every file marks
where a real `ReqLLM`/Gemini call would swap in. The *algorithms* are real; only
the vector source is stubbed.

| # | file | shows |
|---|---|---|
| 01 | embeddings | what a vector is; store one as a datom; cosine by hand |
| 02 | similar-to | nearest-neighbour search; "more like this" |
| 03 | hybrid | semantic + factual + time filters in ONE query |
| 04 | local-rag | on-device retrieval over a personal journal, offline |
| 05 | recommend | "similar, in stock, under $50" |
| 06 | dedup | near-duplicate detection feeds `:same-as` facts back |
| 07 | cluster | k-means vs density clustering; themes emerge |
| 08 | reduce-2d | project to 2-D coordinates for plotting |
| 09 | community | communities over the link graph vs content clusters |
| 10 | time-travel-search | nearest-to-X *as the corpus looked last week* |

**11–15 use REAL Gemini embeddings** (`gemini-embedding-001`) over the complete
**Sherlock Holmes canon** from Project Gutenberg, and build GraphRAG end to end.
They need `GOOGLE_API_KEY` and network for the first run; embeddings are cached
to disk, so every run after the first is offline and free.

| # | file | shows |
|---|---|---|
| 11 | ingest | download the canon, split, embed (cached), store as datoms |
| 12 | naive-rag | plain RAG baseline — and why it fails a GLOBAL question |
| 13 | entity-graph | extract entities + relationships; the prose becomes a graph |
| 14 | communities | detect + summarize communities; the GraphRAG index |
| 15 | graphrag | local (entity-anchored) vs global (community) search |

## Why this is more than a demo

Similarity search, a graph database, clustering, and community detection are
usually four systems. Here they are one file of datoms and a handful of query
clauses, because the datom model already had the right shape — an embedding is
one more kind of fact, and "closest to" is one more kind of clause.
