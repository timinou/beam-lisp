# datom files — a file is a fact, its bytes are not

`:db.type/file` makes a file an ordinary attribute value: queryable, historical,
speculatable, broadcast. The datom holds a ~50-byte content-addressed
**descriptor** — `{sha size media-type}` — and the **bytes** live in a blob store
chosen once at connect time, which by default follows the database's own tier.

Design doc: `docs/datom-files-a-file-is-a-fact.md`.

Run any file with:

```
mix beam_lisp.run --path priv examples/datom/files/NN-name.bl
```

## The one idea

A datom's value is copied into every covering index, and in AVET it is part of
the *key*. Bytes therefore cannot be the value. Content-addressing the
descriptor makes a file behave like every other value: immutable (`as-of`
resolves the same bytes forever), deduplicated (same bytes, one blob),
idempotent to upload (retries are free), and "edited" by asserting a new fact.

## Tiers

| database store | bytes go to | opt-in |
|---|---|---|
| `store-ets` / `store-map` (memory) | `blob-ets` (memory) | `{:blobs :tmp}` — a temp directory |
| `store-fjall` (disk) | `blob-fs` at `<db>.blobs`, a sibling dir | `{:blobs (datom.blob-s3/open …)}` (FUP-025) |
| `store-hobbes` (cluster, later) | `blob-s3`, required | — |

The store declares its default via `datom.blob/DefaultBlobs`; the choice is a
property of the store (registry cell), so a second connection inherits it and a
conflicting one is refused.

## The files

| # | file | shows |
|---|---|---|
| 01 | `01-attach.bl` | one-shot `datom/file` vs two-phase `put-file!`; the datom and the broadcast carry no body; dangling descriptor refused; `file-bytes` / `file-stream` / `file-url`; dedup; metadata as attributes |
| 02 | `02-tiers.bl` | memory → memory, `:tmp` opt-in, disk → sibling dir; configured once (inherit / refuse); `close!` deletes a `:tmp` dir and syncs a durable store; the S3 seam |
| 03 | `03-history-and-gc.bl` | replace and retract keep old bytes for `as-of`; `with` stages into a blob overlay; `gc-files!` sweeps orphans only, inside the writer; why retracted bytes stay |

## Write path, in one line

Bytes leave in the **caller's** process (`put-file!`, parallel); the single
writer validates a 50-byte descriptor (`-blob-has?`) and commits the index.
Blobs before index: a crash between them leaves an orphan (GC-able), never a
datom pointing at nothing.
