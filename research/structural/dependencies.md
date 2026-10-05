> **Final verified record:** 91 assurance assertions passed. Real column projection: 12 store rows initially, 0 after an unrelated write, 14 after a relevant write. This is a closed generated single-store projection/declared dependency model, not automatic tracing of arbitrary code. Changed plans, nested expiry and historical/racing capture are guarded.
>
> See [results.json](results.json), [strategy.md](strategy.md), and [README](README.md). Source-only authoring expectations below are historical and superseded by this final record where they disagree.


# Dependencies — dependency certificates and queued-commit relevance

Status: **research-only, UNRUN**. Authored against the pinned worktree
`/home/user/.cache/bl-structural-spikes` at base
`54e4c6134565d5aa921e6d55ec0e7c57bd429f62`, branch
`perf/structural-efficiency-spikes`. No production default, no deployment, no
main-branch mutation. Every result below is an **expected** result; the
orchestrator runs the tests and records the measured ones.

Origin: PLAN-165 proposition A — "make dependency-aware invalidation reusable
and sound", and its explicit warning that (a) a manually supplied attribute
subset is not a proof of an arbitrary view's dependencies, and (b) once a live
view can skip a render, skipping "the last commit" cannot strand a previously
skipped relevant commit.

Files:

- `research/structural/dependencies.bl` — the module
  (`ns research.structural.dependencies`).
- `research/structural/dependencies_test.bl` — executable tests + logic proofs
  (`ns research.structural.dependencies-test`).
- this note.

## 1. What the spike decides

Two questions share one object — a **dependency certificate**, captured from an
explicit read plan and reused as a cache key and a relevance predicate.

1. **Projection cache.** May a derived multi-column projection reuse its rows?
   Only when a freshly recomputed certificate is *usable*, its plan is
   *identical* to the requested projection's plan, and its token set is *equal*
   to the build-time certificate's. Usable = produced by `capture`/`project`
   with the nonce, structurally sound, complete, no whole/unknown token
   (top-level or nested), no ACL token expired (top-level or nested).
   Otherwise recompute. Unknown ⇒ recompute.
2. **Queued live commits.** May a live socket skip rendering an observed batch
   of commits? Only when the certificate is usable and **no commit in the whole
   queued batch** is relevant. An empty batch renders. Unknown commit, unknown
   attributes, or an unusable certificate ⇒ render. Otherwise skip.

## 2. The read DSL, and why completeness is enforced

`capture` accepts only a closed vocabulary of descriptors
(`sound-kinds = #{:store :attr :empty :basis :acl :provider}`):

| descriptor | token it produces | real datom affordance |
|---|---|---|
| `store-read` | `[:store store-id]` | `datom.store/identity-of` |
| `attr-read a` | `[:attr store-id a mark]` | `datom.attr-basis/basis-t-for` |
| `empty-read a` | `[:empty store-id a mark]` | `datom.attr-basis/basis-t-for` (a **negative** read) |
| `basis-read` | `[:basis basis-t]` | `datom/basis-t` |
| `acl-read k exp attrs` | `[:acl store-id k exp #{attrs}]` | an exact-expiry authorization window |
| `provider-read id reads` | `[:provider store-id id #{inner-tokens}]` | a computed relation's declared `:reads` |

Rules:

- `:complete?` is **computed** by `capture`, never supplied by the caller.
- An `inferred-read` (arbitrary/unclassifiable code) is recorded but makes the
  whole plan unsound, so `:complete? false` and `:cert/source :unsound`.
- **Declaration-only vs real reads.** A standalone `capture` reads NO rows: it
  records a declared plan as tokens. It is not evidence that any view performed
  those reads, and there is no automatic inference of an arbitrary function's
  reads. Only `project` produces a real-read certificate (mode `:projected`)
  because it builds the reads itself; `project` reuses only a `:projected`
  certificate whose plan is identical to the requested one.
- **Boundary, not forgery-proofing.** The `NONCE` distinguishes a captured
  certificate from a map assembled without one, but it is *visible* in the
  returned map: it is **not** unforgeable and **not** a signature. `usable?`
  additionally checks canonical **structural integrity** — the plan is a
  non-empty, sound sequence; there is exactly one token per descriptor; each
  token's kind matches its descriptor's kind. Reuse rests on plan identity +
  structural integrity + token equality, never on secrecy. A caller who already
  holds a certificate and mutates its fields is **outside** the trusted
  boundary.
- **Malformed input fails closed, never throws.** `descriptor-sound?` validates
  every field a descriptor kind requires; `reads-sound?` rejects
  non-sequential / empty / nested-unsound plans; and `usable?` /
  `commit-relevant?` answer `false` / `true` conservatively for a malformed or
  incomplete certificate map.
- One unsupported descriptor anywhere (including inside a `provider-read`)
  unsoundifies the whole plan — a partial dependency set must never justify
  reuse for the part it omitted.

This is the `datom.watch/ALWAYS-RELEVANT` discipline (BUG-100) lifted to a
cache key: anything the DSL cannot name fails closed.

## 2a. Hardening pass (independent review findings)

- **Plan identity.** `project` compares the requested attrs/neg-attrs to the
  cached certificate's descriptor set and rebuilds on any difference. A cache
  built for another projection can never be handed back.
- **Recursive validity.** Expiry and whole-token checks descend into
  `provider-read` nested token sets, so a nested ACL that outlives its deadline
  (or a nested `:whole` token) refuses reuse.
- **Historical / racing reads.** `basis-t-for` answers the store's LATEST write
  whatever db value the caller holds. `capture-with-pinned` marks a certificate
  `:stale?` and `:unsound` when any planned attr/empty token's mark lies ABOVE
  the certificate's pinned basis — the rows are historical, or a write
  interleaved capture. Such a certificate is never cached, so historical rows
  cannot be republished under current marks. Unknown ⇒ rebuild/refuse.
- **`:store` token.** It names an IDENTITY, not a version; it can never move.
  A commit on the same store is nevertheless treated as relevant
  (conservative), while a commit on another store is irrelevant.

## 3. Why each edge is a separate token

- **Store identity.** Every attr/empty/acl token embeds
  `datom.store/identity-of store`, so two certificates over different stores
  can never compare equal even with identical marks. `store-read` makes the
  store a first-class dependency.
- **Empty / negative read.** A projection that asks "are there aliases?" and
  gets none must record a mark. A rows-inferred design (or an attrs-only plan)
  records nothing, so a later insert is invisible — the primary negative
  control. (`naive-reads` models that plan.)
- **ACL exact expiry.** The token carries the exact millisecond, and `usable?`
  refuses at `now >= expiry`. No minute bucket; a cached permission set cannot
  outlive its own deadline. The check is RECURSIVE: an ACL nested inside a
  `provider-read` expires on the same terms.
- **Provider / computed relation.** A `provider-read` carries the nested plan
  the relation performs, so a write to any underlying attribute moves the
  provider token.
- **Whole basis.** A `basis` observation is invalidated by any commit, because
  the read's meaning *is* the basis.
- **Schema footprint.** Schema is datoms; a projection whose columns depend on
  attribute definitions must declare that dependency. There is no schema
  version, so the sound choices are a `provider-read` over the relevant schema
  attributes, or the conservative `basis-read` (any write invalidates). The
  `basis-observation` test is the conservative end; `provider-read` models a
  relationship/computed-relation footprint.

## 4. The queued-commit model (liveness)

`live.socket/commit-queued?` coalesces a commit burst by letting the newest
commit render for the whole burst. That is sound **today** because every
handler renders unconditionally. Adding relevance changes the premise: the
newest commit might be *irrelevant*, so skipping on it strands an earlier
*relevant* commit.

- `naive-last-required?` consults only the last queued commit.
- `batch-required?` (the candidate) renders when the certificate is unusable,
  the batch is empty, **or any commit in the batch is relevant**.

`relevant-commits` exposes the witness set. A commit on a store the
certificate does not read is irrelevant; unknown is always relevant.

## 5. Logic-backed proof scope (model, not runtime)

The veritas/z3 section states an abstract theorem over a bounded Boolean
domain. It is **not** evidence about the runtime; it is evidence that the
design's predicate covers every declared facet while the naive predicate
cannot.

Domain, stated explicitly:

- **Live theorem:** 2 booleans `q_0`, `q_1` = relevance of two queued commits.
- **Cache theorem:** 6 booleans `d_0..d_5` = whether each facet changed
  (`d_0=attr`, `d_1=store`, `d_2=empty`, `d_3=acl`, `d_4=provider`,
  `d_5=basis`); a 7th `d_6` = "unknown" for the always-render law.

Queries (veritas `exists`/`for-all` over `tuple-of`/`bool-of`; `one-of` for the
finite facet enumeration):

1. `∃ (q_0,q_1). ¬q_1 ∧ q_0` → **:proven** — the stranding state exists for
   last-commit-only.
2. `∀. (¬(¬q_1∧q_0)) ∨ (q_0∨q_1)` → **:proven** — candidate covers it.
3. `∀. ¬q_1 ∨ (q_0∨q_1)` → **:proven** — candidate never loses a last-relevant.
4. `∃ (d_0..d_5). ¬d_0 ∧ (d_1∨…∨d_5)` → **:proven** — attrs-only drops an
   ignored facet.
5. `∀. ¬(d_1∨…∨d_5) ∨ (d_0∨…∨d_5)` → **:proven** — candidate recomputes on
   every ignored facet.
6. `∀. ¬d_6 ∨ (d_0∨…∨d_6)` → **:proven** — unknown always renders.
7. `∃ f ∈ {:store,:empty,:acl,:provider,:basis}. ¬(f=:store)` →
   **:proven, :enumerate** — a non-attr facet exists (finite enumeration).

`z3/open` is the supervised oracle handle; no caller-held port exists to leak
(`z3/open` returns `:z3-leases`, not a process). Proofs route through
veritas → oracle, whose solver is released per question by the supervised
pool; the validation process owns solver lifetime.

The modality is asserted (`:proven`), never a bare "no counterexample found".
A finite 2^n Bool domain also exhausts, so `:proven` holds even if the
symbolic rung declines and the enumerate rung answers.

## 6. Executable counterexamples (the concrete witnesses)

| design | trigger | expected runtime witness |
|---|---|---|
| rows-inferred / attrs-only the plan drops the `:empty` read | insert `:p/alias` after a build | `changed-facets` contains `:empty`; `recompute? true`; `naive-recompute? false`; the naive plan's `reusable?` is `true` (stale) |
| last-commit-only relevance | batch `[relevant,irrelevant]` | `naive-last-required? false`; `batch-required? true`; `relevant-commits = [relevant]` |
| hand-built / inferred certificate | any | `:complete? false` or `usable? false` (structural integrity); every commit `relevant? true` |
| cross-store | `recheck` a certificate against another store | `reusable? false`; `changed-facets` contains `:store` |
| ACL expiry | `now == expiry` | `reusable? false`; `changed-facets` contains `:acl` |
| changed plan | `project` a cache with different attrs/neg-attrs | `:reused? false`; plan identity mismatch |
| nested ACL expiry | a `provider-read` whose nested plan holds an ACL past `now` | `usable? false`; `changed-facets` contains `:acl` |
| stale db / racing read | `project` a db taken before a relevant write (mark > pinned) | cert `:stale? true` / `:complete? false`; `:reused? false`; never reused later |
| malformed plan / cert | non-keyword attr, non-int expiry, non-seq nested plan, empty plan, forged inconsistent map | `:complete? false` or `usable? false`; no throw; every commit `relevant? true` |
| `:store` token | commit on the declared store vs another store | same-store `relevant? true`; other-store `false` |
| basis dependency | unrelated write under a `:basis` read | `reusable? false`; `changed-facets` contains `:basis` |

## 7. The read-count oracle (expected; UNRUN)

No run has been made, so no measured cost is claimed: the shape below is
EXPECTED and the orchestrator records the actual counters.

`datom.profile/watch` decorates the store; its `:rows` counter counts rows the
substrate returned from range/scan reads (certificate checks use `:get`, which
returns zero rows — so `:rows` isolates the projection's column reads).

Fixture: 6 entities × 3 columns (`:p/name`, `:p/score`, `:p/tag`) plus a
declared negative read on `:p/alias`. `dep/project` builds/reuses.

Expected:

1. first build: `:reused? false`, 6 rows, store `:rows > 0`;
2. unrelated write (`:p/audit`): `:reused? true`, store `:rows == 0` — the
   per-attribute marks for `:p/name/:p/score/:p/tag` did not move;
3. relevant write (`:p/score`): `:reused? false`, store `:rows > 0`, 7 rows;
4. negative-column write (`:p/alias`): `:reused? false`, store `:rows > 0`.

Counters are zeroed **after** each write, so a write's own reads (validation,
supersession) are not attributed to the projection.

## 8. Production integration seam

Reuse the existing facilities; do **not** add a parallel analyzer or checker.

- **Certificate keying** extends `datom.attr-basis` (per-attribute marks,
  durable `MARK-IDENT` record, `basis-t-for`, `note!`) and
  `datom.derived` (durable records). A production version would live beside
  `datom.attr-basis`/`datom.derived` and be keyed by `datom.store/identity-of`.
- **Projection cache**: the seam is the Knowledge `knowledge/project.bl`
  snapshot/since cache (currently keyed by store + WHOLE basis + vocab hash).
  A certificate replaces the whole-basis key with a per-column certificate so
  an unrelated write stops rebuilding every column. It must be assembled
  against ONE pinned `db` value, and the plan must be declared by the
  projection author, not inferred.
- **Live relevance**: the seam is `live/socket.bl`. `on-commit` currently
  re-renders every observed commit; `commit-queued?` coalesces bursts. A
  production step is: compute a socket's certificate from the view's declared
  reads, and have `on-commit` skip only when the **whole queued batch** is
  irrelevant, defaulting to render on unknown. `listen-options` (line ~464)
  deliberately rejects manual `:attrs`; this spike agrees — an attrs subset is
  not a proof. `ALWAYS-RELEVANT` remains the fail-closed default.
- A socket's certificate must include authorization sources and any
  basis/time/provider reads (e.g. `:live/outcome`, ACL dependencies); those are
  exactly the facets attr-only sets miss.

## 9. Fallback / refusal conditions (must be preserved)

- Unknown attribute set, unknown commit, or unreadable payload ⇒ render.
- Incomplete / unsound / hand-forged certificate ⇒ recompute and render.
- Expired ACL ⇒ recompute and render.
- Different store identity ⇒ no reuse.
- Empty queued batch ⇒ render (never silently skip everything).
- Unknown dependency read ⇒ `inferred-read`, which unsoundifies: fail closed.
- Historical / racing read (a planned mark above the pinned basis) ⇒ the
  certificate is `:stale?` / `:unsound`; never cached; rebuild/refuse.
- Malformed descriptor or certificate ⇒ `:complete? false` / `usable? false`;
  never throws; commits stay relevant.

## 10. What remains unverified (honest gaps)

- **UNRUN.** No test has executed; all outputs above are expected. Actual
  `:modality`, `:engine`, counter values and row counts are unknown until the
  orchestrator runs.
- The veritas proofs are **model theorems over a bounded Boolean domain**.
  They do not prove the runtime functions behave as modelled; the runtime
  tests are the concrete instances, and they too are unrun.
- `z3` unknown/timeout is **not** a proof. If a symbolic rung answers
  `:unknown`, the assertion `:proven` fails — deliberately. A truncated or
  unknown solver answer must never be recorded as proven.
- The experiment measures rows returned by the store, not wall-clock time or
  reductions; cost attribution across a warm/cold page cache is out of scope.
- The certificate is only sound if the projection author's declared read plan
  is actually complete for the view. `capture` is declaration-only: it reads
  no rows and is not evidence a view performed the reads. The DSL can make the
  completeness flag COMPUTED and can check structural integrity against the
  captured plan, but it cannot prove a human declared the right plan, and it
  cannot stop a caller who already holds a certificate from mutating it; that
  caller is outside the trusted boundary.
- Provider dependency is modelled from a declared nested plan; wiring it to
  `datom.query.relation`'s real `:reads` and to authorization sources is not
  done here.
- Genuine CROSS-STORE COMPOSITION is unimplemented. A certificate keys one
  store identity and `project` reads one store; there is no composition of two
  stores' certificates, and no global `live.socket` cutover.
- No integration into `live.socket`, `knowledge/project.bl`, or any cache has
  been made; the seam is described, not cut over.

## 11. Exact proposed test command

One capped VM (see `research/structural/README.md`; the shared batch also
lists the other modules):

```sh
systemd-run --user --collect --wait --pipe --working-directory="$PWD" \
  --setenv=BL_DAEMON=off \
  --property=MemoryMax=8G --property=MemorySwapMax=2G \
  --property=RuntimeMaxSec=1200 \
  ./bin/bl --cold test -p . research/structural/dependencies_test.bl
```

The two files are self-contained given the repository-root code path (`-p .`):
`research/structural/dependencies_test.bl` requires
`research.structural.dependencies` from `research/structural/dependencies.bl`.

UNRUN — the orchestrator runs the command above. The adversarial cases added
in the hardening pass are, by name:

- `changed-plan-never-reuses`
- `nested-provider-acl-expiry-is-honoured`
- `malformed-plans-and-certificates-fail-closed`
- `store-token-relevance-is-store-scoped`
- `stale-db-after-a-relevant-write-never-poisons-the-current-cache`
- `a-forged-certificate-cannot-forge-a-reuse`
