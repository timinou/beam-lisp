# jj in front, datom in the back

Two questions hide inside one sentence. "Should jj manage code?" is about the
**working copy and the change model** — snapshots, revsets, rebases, merges, the
operation log. "Should datom be the VCS in the back?" is about **where history
lives and what can be asked of it** — objects, refs, provenance, queries. They
have different costs, and either answer can hold without the other.

Today beam-lisp answers neither. Code lives in git (this checkout: ~900 commits,
`.git/hooks/pre-commit` written by `bl check --install-hook`), and git appears in
exactly one line of the language's own runtime —
`lib/beam_lisp/daemon/names.ex:173`, where a branch name qualifies an instance
name. The language's idea of a change is `dev.change`: plan → preview → verify →
apply → receipt, hash-guarded, journaled as JSON under
`.beam-lisp/change-journal/`. Its idea of the code is `codebase`: source parsed
into datom facts, cached content-addressed at `.blanalysis/<ns>.<sha>.fjall`.
Provenance exists and is real — it is just sha256, per file, with no history
behind it.

## What jj is, as of v0.45.1

| fact | value |
|---|---|
| latest release | v0.45.1, 2026-09-03 (v0.41 … v0.45: monthly) |
| license | Apache-2.0 |
| prebuilt binaries | 6 target triples (x86_64/aarch64 × linux **musl**, apple-darwin, windows **msvc**) plus a docs tarball |
| artifact | ~10 MB compressed, **31,077,192 B** static-pie on disk, three files in the archive (`jj`, `LICENSE`, `README.md`) |
| integrity | each asset carries a `sha256:` digest in the release metadata — pin it like ERTS |
| source | 3 crates (`jj-core`, `jj-lib`, `jj-cli`); `lib/src` 95 files / 2.5 MB, `cli/src` 170 files / 2.4 MB |
| weight | `jj-lib` pulls `futures`, `pollster`, `rayon`, `gix` (optional), `tokio` (optional), ~40 deps |

`jj-cli` is published as a *library* crate (`cargo install jj-cli`), and
`cli/src/lib.rs` exports `cli_util`, `commands`, `templater`, `ui`.

## What jj hands you: five named storage seams

Upstream's own architecture page states the principle: *"it should be easy to
change where data is stored … commits (and trees, files, etc.) are stored by the
commit backend, operations (and views) by the operation backend, the heads of the
operation log by the op-heads backend, the commit index by the index backend, and
the working copy by the working copy backend."* The backend in use is named by a
plain file per seam — `.jj/repo/store/type`, `.jj/repo/index/type`,
`.jj/repo/op_store/type`, `.jj/repo/op_heads/type`.

| seam | trait | file | size of the contract |
|---|---|---|---|
| commit backend | `Backend` (`#[async_trait]`, `Any + Send + Sync + Debug`) | `lib/src/backend.rs` | 13 methods: `read/write_file`, `read/write_symlink`, `read/write_copy`, `get_related_copies`, `read/write_tree`, `read/write_commit`, `get_copy_records`, plus id lengths and root ids |
| operation log | `OpStore` | `lib/src/op_store.rs` | `name`, `read/write_view`, `read/write_operation`, `resolve_operation_id_prefix`, `gc` |
| op heads | `OpHeadsStore` | `lib/src/op_heads_store.rs` | heads of the operation DAG |
| index | `IndexStore` + `Index` / `ReadonlyIndex` / `MutableIndex` / `ChangeIdIndex` | `lib/src/index.rs` | `IndexStore::name()`; `Index::evaluate_revset()` — **revsets are evaluated by the index**, ancestry, heads, changed paths |
| working copy | `WorkingCopy` / `LockedWorkingCopy` / `WorkingCopyFactory` | `lib/src/working_copy.rs` | snapshot/checkout against a `TreeState` |

Registration is a compile-time registry: `StoreFactories`
(`lib/src/repo.rs:434`) with `add_backend`/`add_index_store`/… , populated by
`default_backend_factories()` (`lib/src/default_backend_factories.rs`) with
`simple`, `git`, (test-only) `secret`, `DefaultIndexStore`, `SimpleOpStore`,
`SimpleOpHeadsStore`, `LocalWorkingCopy`. The stock CLI hardcodes that default
set (`cli/src/cli_util.rs:4421`), and exposes `CliRunner::add_store_factories`
(`cli/src/cli_util.rs:4468`). The sanctioned recipe is in-tree:
`cli/examples/custom-backend/main.rs` — 209 lines that implement `Backend` by
delegating to `GitBackend` and register it under a name:

```rust
store_factories.add_backend("jit", Box::new(|settings, store_path| { … }));
CliRunner::init().add_store_factories(create_store_factories()).add_subcommand(…).run()
```

∴ a datom backend is **possible and upstream intends it**: implement one trait
(plus the op/index seams if you want them datom-side too), ship our own `jj`
binary with that factory registered, and write `datom` into
`.jj/repo/store/type`. What it is *not* is a plugin: stock `jj` cannot load it.
The upstream API carries no stability promise — *"a lot of thought has gone into
making the library crate's API easy to use, but not much has gone into 'details'
such as which collection types are used, or which symbols are exposed"* — and the
`libification` label ("Everything concerning jj-lib API's for thirdparty
developers") is an open effort, not a finished contract. A production embedder
already hit the sharp edge: jj#5685 reports a custom op-heads implementation whose
RPC call could fail and panic the library.

Second surface, and the cheaper one: the CLI is machine-readable. `json(value)`
is a template function (`docs/templates.md`), so one JSON object per commit and
one per operation, verified locally against the pinned binary:

```json
{"commit_id":"0d9de1e1…","parents":["0000…"],"change_id":"txvvprly…",
 "description":"","author":{"name":"","email":"","timestamp":"2026-09-12T17:54:10+01:00"}, …}
```

```json
{"id":"b977c061…","parents":["8a0970be…"],
 "time":{"start":"2026-09-12T17:54:10.784+01:00","end":"2026-09-12T17:54:10.799+01:00"},
 "description":"snapshot working copy","hostname":"…","username":"…",
 "is_snapshot":true,"workspace_name":"default","attributes":{"args":"jj status"}}
```

That second object is the whole argument for S1 in one line: jj's operation log is
already a fact log — an actor, a host, a start and end time, a description, an
operation DAG in `parents`, and the command that caused it. Nothing needs to be
invented to import it.

## What datom hands you

The object model already matches a VCS in three places where it matters:

- **Content-addressed bytes are a first-class value.** `:db.type/file` is a
  ~50-byte descriptor `{sha size media-type}`; the bytes live in the blob port
  (`-blob-put/-get/-has?/-delete/-shas`), deduplicated, immutable, resolvable
  through `(as-of db t)`. That *is* a file-object layer — it was designed for
  attachments and reads as a VCS object store. `gc-files!` already sweeps bytes
  no datom in history references.
- **Canonical encodings of arbitrary terms.** `datom.codec/encode-value`
  canonicalizes any BEAM term — closures included, by hashing
  (`test/bl/datom/terms_test.bl`) — so any structure (a directory, a commit
  body) has a stable content address without inventing a format.
- **History is free.** Monotonic tx ids, `as-of` / `since` / `history`,
  O(1) immutable snapshots, `datom/with` for speculative transactions, and the
  commit broadcast a live view can watch.

And three constraints a VCS design must respect:

- **One writer per process.** Transactions serialize through a single Agent per
  store, and the registry cell holds the durable store's lock until `release!`.
  A second OS process cannot open a live fjall database. jj-as-a-separate-
  process therefore *cannot* be datom's writer, and a datom store cannot be
  shared between the `bl` daemon and a spawned `jj`.
- **Write amplification.** A datom lands in every covering index — EAVT, AEVT,
  and for indexed attributes AVET and VAET. That is 2–4 index entries per fact.
  Facts want to be small; a VCS object store wants one blob per object. This is
  exactly why `datom-files` separates the 50-byte descriptor from the bytes, and
  a commit model should do the same.
- **No ordered-tree value.** Trees are entities with refs (or the encoded-term
  trick above); there is no native directory type. History is linear at the tx
  level, which is fine — a commit DAG is *data* (parent refs on commit
  entities), not tx structure.

## The mapping, if datom is the back

| jj | datom |
|---|---|
| `FileId` (blob) | `:db.type/file` descriptor + blob port — sha256 already, dedup already |
| `TreeId` | entity whose entries are `{:tree/entry …}` refs, or `encode-value` of an ordered map → sha |
| `CommitId` | entity: `:commit/parents` (refs), `:commit/change`, `:commit/tree`, `:commit/author`, `:commit/description`, `:commit/timestamp` |
| `ChangeId` (survives rewrite) | `:change/id`, unique-identity — the handle humans and agents use |
| operation log | datom transactions: a tx is already reified (`:db/txInstant`), and op metadata rides as ordinary datoms on it |
| refs, bookmarks, tags | ref-valued datoms; moving a ref is a new fact, history keeps the old |
| conflicts (`Merge<T>`) | cardinality-many — jj's conflict *is* datom's native multi-value |
| revsets | Datalog over the commit relation, with the ancestors relation as recursive rules |
| index | derived; rebuildable; never a source of truth |
| working copy | the filesystem, snapshotted |

The isomorphism is real but asymmetric. jj's *objects* are small, hot, and read
whole on an index build or a full history walk (jj's own `Store` caches 100
commits and 1000 trees); datom's *facts* are what a query wants to
join. Putting objects in datom costs a round trip and an index fan-out per
object; putting facts anywhere but datom costs the joins.

## Three ways to put datom in the back

**S1 — mirror (jj is authority, datom is a derived view).** After each operation,
read `jj op log -T json(...)` and `jj log -T json(...)` and transact the facts:
commits, changes, refs, touched paths, op metadata. Joined with `codebase`
facts, `dev.change` receipts, and `!tasks` org items. Nothing is forked, nothing
is written back; the view is disposable and rebuildable from the op id it last
saw. Cost: an importer the size of `codebase.bl` plus a watermark. Risk: staleness
(a view, not a lie) and an import that must be idempotent per op id.
Precedent in-repo: `.blanalysis` caches, the AOT seed, the served site — all
derived state.

**S2 — authority flip (datom is authority, jj materializes).** `bl` writes change
facts first (extending `dev.change`'s receipt from JSON to a datom relation), the
materializer writes files, jj snapshots them and its op log is imported back.
This is the literal "datom VCS in the back" for anything beam-lisp authorises.
It only holds if authority is *total*: a hand-run `jj rebase` in a managed tree is
a second master. Cost: an authority rule enforced by the tooling (a lock, a
`bl vcs`-only path, a reconcile step), plus the S1 importer anyway. Buys: one
fact space where intent, verification, and code history are the same query.

**S3 — backend swap (vendored jj with a datom `Backend`).** Our own `jj` binary,
`datom` written into `.jj/repo/store/type`, the object read/write path crossing
into the BEAM. Buys: one store, no import, jj's UI on datom's objects.
Costs: a permanent fork of a monthly-release Rust project; async traits and
`Pin<Box<dyn AsyncRead>>` that the BEAM cannot drive; a round trip per object read
against an LRU of 100 commits / 1000 trees; a datom store that must be owned by
the jj process while it runs and by the daemon otherwise; and an API with no
stability promise. It is the strongest version of the idea and the most
expensive. Nothing about S1 or S2 forecloses it, and both of them produce exactly
the measurements that would justify it.

## Measured, on this host, pinned v0.45.1

```sh
sha256(jj-v0.45.1-x86_64-unknown-linux-musl.tar.gz) = f3543835…cc825f72   # matches the release digest
jj --version        # jj 0.45.1-7c41cdeb…, static-pie, 27 / 75 / 175 ms
jj status           # fresh colocated repo, snapshots a new file: 166 / 253 / 302 ms
jj log -T json(self) --no-graph   # 88 / 122 / 296 ms
jj git init --colocate            # works; same repo visible to git
```

Two conclusions follow. Vendoring a pinned prebuilt is *routine* here — the drop
already fetches z3 by sha (`mix bl.z3.fetch`, `tooling/drop/erts.lock`), and jj
is a third of z3's size. And jj is a **command**, not a per-keystroke hook:
0.1–0.3 s per invocation is fine for "make a change", wrong for "file saved".

## Assessment

**jj: yes — as the first-party change engine, shipped as a pinned prebuilt used
through its CLI.** It is the only piece of this stack whose alternative is years
of our own work: working-copy snapshotting, revsets, rebase/amend with stable
change ids, conflict objects, `jj op undo` for everything, colocated git for
GitHub. Vendored as a *cargo dependency* it would poison the drop (asynchronous
Rust, 3 crates, ~40 deps per crate, monthly churn, an explicitly unstable API,
per-target NIF builds under the libc rule). Vendored as a *binary* it is one lock
entry, one fetch task, one spawn per command — and the contract we depend on is
its command line plus templates, which we can smoke-test in CI the way the drop
smoke-tests z3 today. First-party then means: in the drop, in `bl doctor`, behind
`bl vcs …`, versioned by us.

**datom: yes — as the fact layer, no — as jj's object store.** The value is not
storage efficiency; jj is better at being jj's store. The value is that history
lands in the same fact space as intent and proof, so questions that today take a
human (or an agent's guess) become one Datalog program:

- which changes ever touched `datom.conn/gc-files!`, who asked for them, and what
  verification did they carry — history ⋈ `codebase` ⋈ `dev.change` receipts ⋈
  org tasks;
- since release R, which new calls appeared with no matching verification receipt
  — the anti-drift query behind "agents claim work is done";
- the whole repo *as of* t: code facts, task state, and verification state at the
  same basis-t, because `as-of` already composes;
- against a speculative `with`, what a change would do to the history before it
  exists.

So the recommendation is **S1 now, S2 as the deliberate direction, S3 only if a
measurement demands it**. Concretely: import jj's operations into datom under a
watermark, move `dev.change`'s receipts from JSON files into a datom relation,
and keep git colocated as the interop and release format — GitHub stays the
remote, and datom never becomes the only copy of a repository we must push.

The one rule that makes the whole thing safe: **a derived view may lag; it may
never disagree.** The mirror is rebuilt, not reconciled — keyed by op id, and
refreshable wholesale. `bl doctor` reports the watermark (last imported op vs
`jj op log -r @`), and a mismatch is a rebuild, not a merge.

Two things this breaks and must be re-planned, not discovered:

- **The commit hook goes away.** jj has no pre-commit hook — every command
  snapshots. `bl check --install-hook` (and the CI story around it) must move the
  proof gate into `bl` itself and into CI; git hooks remain only for the
  colocated git side.
- **Reconcile cost is real.** A hand-run `jj` command in a managed tree is
  legitimate until S2 makes datom authoritative; from then on it is a conflict
  between two masters and needs an explicit rule.

## What would change this assessment

- A full import of a 10k-commit repo taking minutes, not seconds, would push the
  fact layer toward "recent history only" — a windowed view rather than a mirror.
- Shipping a datom `Backend` that reads objects over a unix socket and stays
  within ~2× of `jit`'s delegated-to-git benchmark in `cli/examples/custom-backend`
  would make S3 respectable and reopen it.
- A drop-size ceiling on a target we care about (Windows, macOS) colliding with
  +31 MB would make jj an *optional* tier rather than a first-party default.
- Upstream shipping a stable, versioned backend ABI (or a dynamic factory
  registry) would remove the fork tax and make S3 cheap. It has not, and the
  `libification` work is explicitly unfinished.

## Open questions

1. Whose code does this manage first: beam-lisp *applications* (the drop's users),
   or this repository's own development? The second needs the git-colocated story
   to be airtight before anything moves.
2. Is the mirror allowed to be lossy — recent history plus touched paths — or must
   it be the whole DAG from the root commit?
3. Where does the change gate live once `jj` replaces the hook: in the `bl`
   daemon's FIFO, in `bl vcs commit`, or only in CI?
4. Does this repository's own `.git` stay the release format indefinitely, with
   `.jj` as a local convenience — or is GitHub the only thing keeping git alive?
