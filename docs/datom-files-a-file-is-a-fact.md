# A file is a fact. Its bytes are not.

datom stores files. Not paths to files, not URLs — files, as attribute values
you query, retract, time-travel and broadcast like any other fact. The trick
that makes this cheap is one separation: the **fact** is a fifty-byte
descriptor in the datom; the **bytes** live in a blob store beside the
database, addressed by their own hash.

```clojure
{:db/ident :doc/attachment :db/valueType :db.type/file}

(datom/transact! conn [{:db/id -1 :doc/title "cat.png"
                        :doc/attachment (datom/file png-bytes {:media-type "image/png"})}])

(datom/file-bytes (datom/db conn) (:doc/attachment (datom/entity db e)))
;; => png-bytes
```

## Why bytes cannot be the value

A datom is written into every covering index — EAVT, AEVT, and for indexed
attributes AVET and VAET. In AVET the value is part of the **key**. A forty
megabyte value would be copied several times over and handed to a key encoder
as a forty megabyte term. The database would work; it would just be a terrible
one.

So a `:db.type/file` value is a `DFile`:

```clojure
{:sha <<32 bytes>> :size 4096 :media-type "image/png"}
```

Three fields, about fifty bytes. The `sha` is the sha256 of the content. That
choice — content addressing — is what makes a file behave like a value:

| property | why it follows |
|---|---|
| **immutable** | the same sha always names the same bytes; `as-of` resolves a file from years ago exactly as it did then |
| **deduplicated** | two entities holding the same bytes share one blob |
| **idempotent to upload** | a retried upload of the same bytes is a no-op, never a duplicate |
| **"edited" by asserting** | a new version is a new fact; cardinality-one retracts the old one, and history keeps both |

Metadata beyond those three fields — filename, uploader, created-at — belongs
in ordinary attributes on the entity, where it is queryable. The descriptor
does not grow.

## Where the bytes live: the blob port

Beside `datom.store` (the ordered key/value port every index rests on) sits a
second port, `datom.blob`: content-addressed, unordered, five methods.

```clojure
(-blob-put    bs sha bytes)   ; idempotent
(-blob-get    bs sha)         ; bytes | nil
(-blob-has?   bs sha)         ; O(1) — the writer asks this per file datom
(-blob-delete bs sha)         ; GC only
(-blob-shas   bs)             ; everything held — the GC sweep's input
```

Plus optional capabilities a substrate may declare, dispatched by
`satisfies?` exactly like `datom.store/Scan`:

- `BlobStream` — hand bytes out in chunks, so a large file is never whole on
  the reader's heap
- `BlobUrl` — a `file://` path or a presigned S3 GET, so a client fetches
  bytes without crossing the BEAM
- `Closeable` (shared with the store port) — explicit teardown of what the
  substrate owns

Substrates: `blob-ets` (memory), `blob-fs` (a sharded directory, atomic
rename on write), `blob-overlay` (speculation), and `blob-s3` (the cluster
tier). Every one passes `test/bl/datom/blob_test.bl` unchanged.

## Tiers: bytes live wherever the database lives

Where the bytes go follows where the **database** is. Each store substrate
declares its own default by extending `datom.blob/DefaultBlobs`; nothing above
the store inspects a store's type to decide.

| database store | bytes default to | opt-in |
|---|---|---|
| `store-ets`, `store-map` (memory) | `blob-ets`, in memory | `{:blobs :tmp}` — a fresh temp directory, for files too large to keep on the heap |
| `store-fjall` (disk) | `blob-fs` at `<path>.blobs` — a sibling directory, so database and bytes are moved and backed up as one | `{:blobs (datom.blob-s3/open …)}` |
| `store-hobbes` (cluster) | `blob-s3`, required — local bytes on a distributed database is a database whose files vanish on the next node | — |

The choice is made once, at connect time, and belongs to the **store**: it
lives in the connection registry cell beside the writer and the basis.

```clojure
(datom/connect SCHEMA)                                   ; memory → memory
(datom/connect SCHEMA {:blobs :tmp})                     ; memory → temp dir
(datom/connect-with (datom.store-fjall/open path) SCHEMA) ; disk → <path>.blobs
(datom/connect-with store SCHEMA {:blobs (datom.blob-fs/open "/srv/blobs")})
```

A second connection over the same store inherits the blob store. A second
connection asking for a *different* one is refused with an error. Bytes have
one home per database, and that is enforced, not recommended.

## The write path

The writer is a single process; it serializes every transaction. Bytes must
not flow through it. So the efficient path is **two-phase**:

```clojure
;; 1. bytes leave in YOUR process — a hundred callers upload in parallel
(def f (datom/put-file! conn bytes {:media-type "image/png"}))
;; => {:sha … :size … :media-type "image/png"}   a DFile at rest

;; 2. the writer sees a fifty-byte descriptor
(datom/transact! conn [{:db/id -1 :doc/attachment f}])
```

`datom/file` is the one-shot form for small files: it returns a **staged**
DFile — the same record, still carrying `:body`. Put it in transaction data
and the pipeline uploads the body before the commit and records the descriptor
alone. A body never reaches an index, and a broadcast report never carries one.

Inside the pipeline, after validation and before any datom exists:

- a staged file is uploaded and its body stripped
- an at-rest descriptor is checked with `-blob-has?` — if the bytes are not
  there, the whole transaction is rejected with `:file-missing`

Blobs are written **before** the index commit. A crash between the two leaves
an orphan blob (which GC reclaims) and never a datom pointing at nothing. That
is the right direction to fail in.

## Reading

Bytes are resolved through the **database value**, not the connection:

```clojure
(datom/file-bytes  db f)                ; the binary, or nil
(datom/file-stream db f)                ; a seq of chunks — 64 KiB each from disk
(datom/file-url    db f {:expires 900}) ; file:// or presigned; nil for memory
```

Because the blob store rides on the value, `(as-of db t)` resolves a file that
has since been retracted exactly as it resolves the entity's other facts at
`t`. A historical database answers historical questions, files included.

When the blob store no longer holds a file's bytes, `file-bytes` returns nil.
The datom is still a valid fact; only its bytes are gone.

## Speculation

`(datom/with conn tx-data)` runs the same pipeline against an overlay of the
store, so nothing is committed. Files are speculative in the same way: a staged
body lands in a **blob overlay** the real blob store never sees, and the
returned `db-after` resolves it. Dry-run a migration that attaches files and the
real blob store learns nothing.

## Retraction, history, and garbage

Retracting a file datom removes the fact from the present. It does **not**
delete the bytes — history and `as-of` still reference them. There is no
storage reclaim for a retracted file until excision exists.

What *is* garbage: bytes referenced by no file datom anywhere in history. That
is an upload whose transaction never landed — a `put-file!` followed by a
request that died, or a crash between blob write and index commit.

```clojure
(datom/gc-files! conn)   ; => {:swept 1 :kept 42}
```

The sweep runs **inside the writer**, the one place where "no transaction is
in flight" is true, so a `put-file!` whose transaction is queued behind the
sweep cannot lose its bytes.

## Lifetime

`release!` drops the registry entry so a store can be garbage-collected.
`close!` does that and then frees what the store and blob store *own*: an ETS
table is deleted, a `:tmp` blob directory removed, a durable store synced. A
directory you named, and every durable database, is never deleted by a close.
Both are idempotent.

## Schema rules

`:db.type/file` attributes cannot be `:db/index` or `:db/unique` — a map
descriptor has no meaningful order in AVET. To look files up by content, add a
sibling `:file/sha :db.type/string :db/unique …` attribute and populate it
(a transaction function does this in one place).

A value is checked structurally: a 32-byte sha, a non-negative size, a string
or nil media type, and — for a staged file — a body of exactly `size` bytes.
The constructor is the only place a hash is computed; the writer never
re-hashes, because O(bytes) work does not belong in the serializer.

## Where to look

- `priv/lib/datom/file.bl` — the DFile value and its constructor
- `priv/lib/datom/blob.bl` — the port and its capabilities
- `priv/lib/datom/blob-{ets,fs,overlay}.bl` — the substrates
- `priv/lib/datom/conn.bl` — `put-file!`, `stage-files!`, `gc-files!`, `close!`
- `test/bl/datom/blob_test.bl` — the port's executable contract
- `test/bl/datom/file_test.bl` — the datom-level invariants
- `examples/datom/files/` — three runnable walks through all of the above
