# autovcs — a daemon that versions its own work

**A probe, not an integration.** Nothing in `lib/`, `priv/`, or `mix.exs` knows
this exists. It answers one question with running code: can the `bl` daemon
carry automatic version control — every mutation it performs becoming a change
with an author, an intent, and an undo — with jj doing the hard part and datom
holding the part that must be queryable?

```sh
research/autovcs/demo.sh          # end to end, ~1 min, asserts its own claims
research/autovcs/fetch.sh         # just the pinned binary path (sha256-verified)
```

## The shape

```
   request ──▶ write bytes ──▶ jj describe -m "<actor>: <intent>" ──▶ jj new
                    │                       │
                    │                       └─▶ op id (the audit trail, jj's own)
                    ▼
              mirror (jj → datom)  ──▶  op/* · cm/* · req/* facts
                    │
                    ▼
              reply: {ok, op, commit, paths, ms}
```

* **jj is the change engine.** It snapshots the working copy, holds a change per
  request with a stable change id, records every command as an operation, and
  undoes anything with `jj op restore`. Snapshotting is not a step the daemon
  schedules: opening the workspace *is* the snapshot, and `jj describe` is what
  gives the result an intent. There is no staging area, so there is no moment at
  which the daemon's work exists but is unrecorded.
* **datom is the fact layer.** The mirror turns jj's operation log, commit log
  and per-commit changed paths into facts (`:op/*`, `:cm/*`), and adds the one
  thing jj cannot know: the *request* that caused an operation — who asked, why,
  and how long the checkpoint took (`:req/*`). Queries are Datalog joins across
  both (`history`, `touched`).
* **The mirror is derived.** Every fact is keyed by a content-addressed id jj
  already minted (operation id, commit id, change id), so re-ingesting is a
  no-op, and a rebuild yields the same facts. A watermark (`:meta/op-head`)
  makes the common case one `jj op log -n 1` away from free.

The protocol is one JSON request per line in, one JSON reply per line out:

```jsonl
{"op":"write","id":"r1","path":"app.bl","content":"…","by":"agent:probe","why":"first cut"}
{"op":"delete","id":"r5","path":"notes.md","by":"agent:probe","why":"answered; drop the note"}
{"op":"status"} | {"op":"history"} | {"op":"touched","path":"app.bl"}
{"op":"undo","id":"<jj operation id>"} | {"op":"stop"}
```

`serve` reads stdin (the daemon shape); `script` reads the same requests from a
file, so a demo is a file and not a shell pipeline. Both call one handler.

## What it proves

`results.md` is a full transcript, produced by `demo.sh` against a throwaway
tree (`/tmp/autovcs-demo`) holding `.bl`, `.md`, `.json` and an ignored build
artifact. The assertions in `demo.sh` are the claims:

1. **Five mutations → five changes**, each carrying its author and intent, and
   the working copy ends *clean* — nothing the daemon did is unrecorded.
2. **jj's own log reads like the session's audit trail**, because the intent is
   passed as the describe message:

   ```
   yy k y w l p y  autovcs probe  agent:probe: the question is answered; drop the note
   qltkwuml  autovcs probe  agent:probe: make it 2, per BUG-9
   ```

   and the operation log keeps the argv that did it:
   `jj describe -m 'agent:probe: make it 2, per BUG-9'`.
3. **The colocated git repo sees the same history** — Git interop is untouched.
4. **Undo is an operation, not a patch.** Restoring to the operation recorded
   after request 3 removes two later changes from the working copy: `app.bl`
   says `1` again and the deleted `notes.md` is back. No inverse patch was
   computed, and no diff was applied.
5. **The mirror answers what jj cannot**: *which requests touched `app.bl`* →
   `r1`, `r4` — with the actor and the reason for each.

## Measured

From `results.md`, on this host (AMD Ryzen AI 7 350, kernel 7.0.14-zen1),
pinned jj v0.45.1:

| what | run A | run B |
|---|---|---|
| bare cold VM (`bl eval '1'`) | 1551 ms | 4305 ms |
| cold VM with the probe and datom loaded, **zero requests** | 12125 ms | 19792 ms |
| one checkpoint (write + describe + new + mirror), 5 samples | 1402–1836 ms | 1373–1703 ms |
| …of which the jj→datom mirror | 765–1176 ms | 690–1008 ms |
| one script pass: 5 mutations + 3 queries, process start to exit | 21529 ms | 28057 ms |

Two runs on the same host, same pinned jj, minutes apart — the spread is real
(46 GB of RAM, zram compressing under load), which is why every number here is a
range and `results.md` is the transcript of the run that produced the right-hand
column. The jj binary itself: a 10.5 MB tarball, 31,077,192 B static-pie on
disk, sha256-pinned.

The second row is the finding that shapes everything: **loading the datom stack
costs 12–20 s, so per-request VCS cannot live in a spawned process.** It has to
live in the warm daemon — which is exactly where it is headed. The per-checkpoint
~1.4–1.8 s is what a warm daemon would actually pay, and ~1 s of that is the
mirror re-reading the whole operation log (fine at 20 operations; it needs
paging or `--at-op`-style incremental reads at 10 000).

## Findings that outlive the probe

1. **jj honours `.gitignore`.** The mirror lives at `<tree>/.autovcs/`; if the
   tree does not ignore it, every checkpoint tracks the journal that describes
   the checkpoint. `status` reports whether the ignore line is present
   (`mirror_ignored`), and the demo's clean-working-copy assertion is what
   catches its absence.
2. **jj has no hooks — and needs none.** `bl check --install-hook` writes
   `.git/hooks/pre-commit`, which has no jj counterpart: commits happen on every
   command. The gate has to move into `bl` itself (or into the daemon's FIFO),
   and CI keeps whatever it does today. This is a workflow change, not a
   technical one, and it should be decided before anything is migrated.
3. **The operation log is already a fact log.** `jj op log -T 'json(self)'`
   yields id, an operation DAG in `parents`, `time.start`/`time.end`, `username`,
   `hostname`, `workspace_name`, `is_snapshot`, and `attributes.args` — the
   command line. The only thing a daemon must add is the request behind the
   operation, which is precisely the part jj cannot see.
4. **`datom` reaches `z3pool` at load.** `datom.time` requires `z3`, which
   requires `z3pool` in `priv/std`, so any program that requires `datom` needs
   `-p priv/std` (or `BEAM_LISP_PATH`). Without it: `namespace not found:
   z3pool`.
5. **A warm daemon from another build fails silently.** With a sibling session's
   daemon running for this tree, a `bl run -p …` that the daemon cannot serve
   exits `1` with *no output at all* — the error only appears with
   `BL_DAEMON=off`. Anyone prototyping in this repository should set
   `BL_DAEMON=off` and be ready to see the real message. The demo does.
6. **One unexplained boot failure.** A payload directory under
   `~/.local/share/drop/` failed to boot with `cannot get bootfile
   .../bin/start.boot` while sibling `bl` processes were running from other
   payload directories (seven of them exist, ~100 MB unpacked each). The
   mechanism is not established; `demo.sh` widens `BL_DROP_KEEP_DAYS` as a
   precaution only.

## Deliberately out of scope

* **Past history.** Nothing is imported from git: this versions work the daemon
  does from here on.
* **Changed paths beyond the daemon's own testimony.** The mirror stores the
  paths each request touched (the daemon's account) and jj's per-commit diff
  summary for new commits. Rename/copy detection is jj's business and is not
  interpreted here.
* **Typed ids and instants.** `:op/parent` and `:cm/parent` are stored as id
  strings, joined in Datalog by value (`[?o :op/parent ?pid] [?p :op/id ?pid]`);
  the ref form is an optimisation, not a semantic change. jj's RFC3339
  timestamps are kept as strings; `:req/at` — the daemon's own clock — is a real
  `:db.type/instant`.
* **`bl` integration.** No verb, no config key, no daemon change. The next step
  if this shape is accepted: one long-lived mirror connection inside the daemon
  (not one per process), a `bl vcs` verb over the same handler, and the request
  ↔ operation join moved from "latest op at checkpoint time" to the operation
  id read from the describe that carries the intent.

## Where to look

| file | what |
|---|---|
| `autovcs.bl` | the daemon: protocol, checkpointing, the mirror, the queries |
| `demo.sh` | the scenario, and every assertion that makes it evidence |
| `results.md` | the transcript `demo.sh` wrote |
| `jj.lock`, `fetch.sh` | the pinned jj (version, url, sha256 per target) |
