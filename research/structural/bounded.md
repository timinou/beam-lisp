> **Final verified record:** 133 assurance assertions passed, including native Fjall PageScan. A rank scan returned/read 2 rows; additional EAVT visibility/authorization seeks are separate work. General multikey scoring remains posting-wide. Ordered bounded requests refuse wide nonpaged fallback before materialization through Count admission. Cursor/retry/retraction/rank-prefix/overflow regressions are covered. Maintained index updates, general no-Count multikey fallback and end-to-end byte/CPU limits are not production implementations.
>
> See [results.json](results.json), [strategy.md](strategy.md), and [README](README.md). Source-only authoring expectations below are historical and superseded by this final record where they disagree.


# Spike: candidate-restricted authorized top-k / cursor pages over a datom lexical posting index

Status: **authored, NOT RUN.** Every result statement below is either a
*design claim* (expected, to be confirmed by the command given) or explicitly
labelled UNVERIFIED. The orchestrator runs the command once, in the serial
capped VM, and fills the measured columns.

Files (all under `/home/user/.cache/bl-structural-spikes`, worktree only):

- `research/structural/bounded.bl` — module, `(ns research.structural.bounded)`.
- `research/structural/bounded_test.bl` — tests, `(ns research.structural.bounded-test)`.
- `research/structural/bounded.md` — this note.

Base commit: `54e4c6134565d5aa921e6d55ec0e7c57bd429f62` on `perf/structural-efficiency-spikes`.

## Exact test command (proposed)

```sh
cd /home/user/.cache/bl-structural-spikes
BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl test research/structural/bounded_test.bl
```

- The CLI's default library root is the cwd, so `research.structural.bounded`
  at `research/structural/bounded.bl` resolves without `-p`.
- If the runner isolates load paths, add the repo root: `-p /home/user/.cache/bl-structural-spikes`.
- `BEAM_LISP_Z3=/usr/bin/z3` is required for the one symbolic obligation
  (`z3` 4.16.0 present on the host). The finite parity/negative tests do not
  need it.
- One VM. Everything is in-memory ETS except one **conditional** fjall branch
  (see §7), which is skipped when `datom.store-fjall/available?` is false.

## The proposition (PLAN-165 audit, opportunity 6)

The audit's finding, verbatim shape: Knowledger `search-one` ranks, overfetches
a fixed `6*k` window, **then** applies the readable filter — so it may return
fewer than `k` rows while permitted rows sit below the window. Grounded in
current source:

- `apps/knowledger/src/knowledger/search.bl` — `search-one`:
  `(take k (readable (search-one-ranked conn library q (* 6 k) …)))`; the
  docstring itself says "a scoped reader may still get < k".
- `apps/knowledger/src/knowledger/search.bl` — `lexical-chunk-hits` scans the
  whole `:chunk/text` column through `datom/q`, and the passage/entity/procedure
  passes each scan their own columns: a query costs O(corpus) regardless of how
  selective its terms are.

Two independent defects — cost (whole-corpus scan) and correctness (fixed
overfetch + post-filter). This spike prototypes the replacement over
**existing** datom affordances (an indexed attribute + `datom/datoms` AVET
reads + `datom.store/page-datoms` paging + `datom.profile` accounting). It adds
**no** query planner, cache, or analyzer.

## What the spike actually establishes — and the claims it CORRECTS

An earlier revision of this note and module said the page was bounded and
"never walks the whole candidate set". **That was wrong**, and it is corrected
here and in the source. The precise statement is:

> The candidate path is **posting-restricted**, not page-bounded.

Concretely, `page-topk-db` and `indexed-topk-db`:

1. read **every** posting row for **every** query term — `Σ_t df(t)` rows
   (`candidate-scores` / `candidate-scores+`);
2. **materialize a score for every matching document** and **sort the whole
   scored candidate set** (`ranked-score-pairs`);
3. only then walk in rank order, and only the **authorization** step
   (`walk-authorized` / `walk-page`) stops early at `k` permitted rows.

So a first "page" is **not** `O(page)`. The posting read is `O(Σ df(terms))` and
the ranking is `O(c log c)`. What the page bounds is the **ACL entity reads
after ranking**. What the old claim correctly captured is only that the path
never scans `:doc/text` — it is restricted to the query terms' postings.

The three counters are kept separate precisely so this cannot be misread:

| counter | means |
|---|---|
| `:posting-rows` | posting rows materialized by the candidate read (`Σ df`) |
| `:ranked` | candidates that entered the sort (`= :candidates`) |
| `:examined` | ranked candidates the authorization walk visited |

`page-bounds-examined-not-postings-or-ranking` asserts exactly this shape on
the base fixture: 5 posting rows read, 5 candidates ranked, **2** examined.

A genuinely page-bounded top-k needs a posting index **ordered by rank** and a
paged read. This spike provides that for a **single term** (§ "Ordered page"
below); general **multikey** scoring is a posting-wide fallback behind a
work-budget contract.

## What is in the module

Schema the candidate path assumes (the production index schema seam — names map
1:1 onto Knowledger: `doc` ≈ `:chunk`, `term` ≈ a tokenized `:chunk/text`):

| attribute | type | role |
|---|---|---|
| `:doc/text` | string | corpus row value (tombstone-independent listing) |
| `:doc/live` | boolean | soft tombstone |
| `:doc/public` | boolean | readable by every principal |
| `:doc/reader` | ref, many | sparse ACL (principals who may read) |
| `:post/term` | string, **`:db/index true`** | the lexical posting key — AVET prefix read |
| `:post/rank` | string, **`:db/index true`** | DERIVED rank-ordered key (ordered page only) |
| `:post/doc` | ref | posting → document (ref ⇒ AVET+VAET maintained) |
| `:post/tf` | long | the posting's rank contribution |

Reading path:

- `postings-for-term` — `(datom/datoms db :avet :post/term term)`, `df(term)`
  rows. Candidate restriction; `:doc/text` is never scanned.
- `candidate-scores+` / `candidate-scores` — `{doc-eid → Σ tf}` over the query
  terms' postings, plus the real `:posting-rows` counter.
- `ranked-score-pairs` — sort by `(score desc, eid asc)`; the eid is the
  identity tie-break.
- `indexed-topk-db` — EXACT ranked walk with the authorization gate applied
  **during** the walk; returns `{:status :exact :hits :total :candidates
  :posting-rows :ranked :examined}`. `:total` is authorized matches, not page
  length.
- `page-topk-db` — a page after a **provenance cursor**; stops the ACL walk at
  `k` permitted rows. No `:total` (it did not walk the whole candidate set). It
  **still ranks the whole candidate set** — see the correction above.
- `oracle-topk-db` — full authorized sort: enumerates every document (AEVT on
  `:doc/text`), scores each from its own postings, filters, sorts, top-k.
- `fixed-overfetch-db` — the NAIVE control (global rank, top `k*6`, then
  filter), kept so the bug is a named, removable shape.
- `budgeted-topk-db` — the exact-or-refused multikey path under a posting-row
  budget (below).
- `posting-page` / `ordered-topk-page` — the genuinely bounded single-term
  page over the `:post/rank` index (below).
- `index-doc-tx` / `rank-index-tx` / `retract-doc!` — the small index-
  maintenance prototype: add a document with its postings; a second derived
  pass writes the rank key; retire a document and its postings together.

## The work-budget contract (multikey)

`budgeted-topk-db db principal terms k {:max-posting-rows n}` returns a typed
verdict. There is **no state in which a partial ranking is presented as the
answer**:

| status | meaning | hits |
|---|---|---|
| `:exact` | every candidate ranked, every permitted row up to k seen; `:total` present | the true top-k |
| `:refused` | the KNOWN posting rows exceed the budget — declined **before** the read; `:required-posting-rows-at-least` names the (possibly capped) cost | `[]` |
| `:incomplete` | the substrate could not count ahead of the read and the read exceeded the budget; `:resume` is a provenance cursor | `[]` |

Admission uses the store's bounded key count when it has one
(`datom.store/count-capable?` + `count-range` over the term's AVET prefix). On
ETS — which implements `Count` — a budget of 2 against the 5-row `"cat"` column
is **refused with `:hits []`**, not answered with a short page. When the count
is capped at `budget+1`, the verdict reports
`:required-posting-rows-at-least` (a lower bound) and leaves
`:required-posting-rows` nil rather than passing a capped count off as exact.

`verdict-from-scores` re-checks the real `:posting-rows` counter after the read,
so a substrate without `Count` still cannot leak an over-budget exact answer.

## Cursor provenance

A cursor is **not** `[eid score]`. `ranked-cursor` / `ordered-cursor` carry:

```
{:cursor/kind     :ranked-topk | :ordered-posting
 :cursor/store    <store identity, via datom.store/identity-of>
 :cursor/basis    <datom/basis-t>
 :cursor/query    <terms>          ; ranked cursor
 :cursor/term     <term>           ; ordered cursor
 :cursor/principal <principal>
 :cursor/order    :score-desc-eid-asc | :post-rank-score-desc-eid-asc
 :cursor/after    <position>}
```

`page-topk-db` / `ordered-topk-page` call `ranked-cursor-ok?` /
`ordered-cursor-ok?` and **refuse** (`:status :refused`, `:reason
:cursor-mismatch`, `:hits []`) when the store, basis, query/term, principal, or
order differ from the db value they were handed. This replaces the earlier
"cursor replayed on a newer basis resumes" behaviour: an old-basis cursor on a
new basis can resurrect a revoked row or skip one, so it must not be trusted to
the caller. A caller that holds **one** `datom/db` value pages freely against it
(basis stable); a caller that re-derives the db after a write starts over.

Tests: `cursor-carries-store-basis-query-principal-and-order`,
`cursor-replayed-against-a-newer-basis-is-refused`,
`cursor-replayed-with-a-different-principal-is-refused`,
`cursor-replayed-with-a-different-query-is-refused`,
`cursor-shape-not-a-bare-eid-score-pair`.

## Ordered single-term page (genuinely bounded)

`:post/rank` encodes `(term, score DESC, doc-eid ASC)` so a lexicographic AVET
read on the term yields the postings **already in rank order**:

```
value = term + "~|~" + zero-pad(1e12 - tf, 13) + zero-pad(doc-eid, 13)
```

`rank-index-tx` is the derived pass that writes it (it needs the real doc eids,
so it runs after the postings exist — the production basis for extending
`datom.derived`/`datom.reconcile`). `posting-page` reads that prefix with
`datom.store/page-datoms`. `ordered-topk-page` walks the pages applying the
authorization gate as it goes, stopping at `k` permitted rows.

Two API facts make this correct rather than a relabelling, both verified in
current source:

- The AVET key is `index-tag + encode(attr) + encode(value) + encode(entity) + …`,
  and string values encode as `TAG-STR + raw-UTF-8 + 0x00`. A **partial string**
  is therefore not a byte-prefix of a longer value — the trailing `0x00` breaks
  it — so `posting-page` builds its lower bound with `string-prefix-key`, which
  drops that terminator. (`datom.index/key-prefix` + `erlang/binary_part`.)
- `datom.store/page-datoms` dispatches on the substrate's **`PageScan`**
  capability (`datom.store/capability-target`, so a transparent profiler is not
  mistaken for the substrate). fjall and the overlay store implement it; the
  in-memory **ETS store does NOT**, and the documented
  `scan-via-range-page` fallback **materializes the whole range** before taking
  the page.

So the first-page bound is conditional and is reported honestly:

- `:bounded?` is `(datom.store/page-capable? db)`.
- `:rows` is the rows the store **actually read**: the page size where the
  substrate pages, and `df(term)` where it fell back — so a budget cannot be
  fooled by a wide fallback.
- On ETS the same call is correct but wide (`:bounded? false`). The genuinely
  `O(page + denied)` first page is exercised in the **conditional fjall branch**
  of `ordered-bounded-first-page-on-a-paging-substrate`, which asserts
  `:page-rows 2` and `:rows 2` for a limit-2 first page.

`ordered-page-is-bounded-only-where-the-substrate-pages` asserts the verdict's
`:bounded?` equals the substrate's real capability on whichever substrate runs.

## Logic verification — query scopes

Uses the existing logic module `veritas` (not a handwritten `for-all` loop).

1. **Finite exhaustive parity** (`indexed-walk-equals-oracle-over-finite-scenario-domain`).
   `veritas/for-all` over `(apply veritas/one-of scenarios)`. Predicate
   `research.structural.bounded/parity-holds?`. Expected `{:modality :proven,
   :engine :enumerate}`.
2. **Finite exhaustive ordered-page parity**
   (`ordered-page-walk-equals-oracle-over-finite-scenario-domain`). Predicate
   `ordered-page-parity?`: the page walk over the rank-ordered list equals the
   oracle. Real, not a tautology: a mis-ordered input refutes it. Expected
   `:proven` / `:enumerate`.
3. **Finite exhaustive budget honesty**
   (`budgeted-walk-is-exact-or-empty-over-finite-domain`). Domain: `scenarios`
   crossed with `{:exam-budget ∈ [nil 0 1 2 3 100]}`. Predicate
   `budget-walk-is-exact-or-empty?`: an exact verdict equals the oracle and a
   non-exact verdict carries no hits. Expected `:proven` / `:enumerate`.
4. **Finite negative control** (`fixed-overfetch-is-refuted-with-a-witness`).
   `veritas/exists` over the same scenarios; predicate `overfetch-misses?`.
   Expected `:proven` / `:enumerate` with the offending scenario as `:witness`.
5. **Symbolic obligation** (`rank-order-is-asymmetric-symbolically`).
   `veritas/for-all` over `(tuple-of int-of(-1e6,1e6) ×4)`, predicate via
   `(nth q i)` so `system.smt` translates to `q_0..q_3`. Expected
   `{:modality :proven, :engine :oracle}` — asymmetry over an unbounded integer
   domain, not sampled.

**Proof boundary.** What is *proved*: the pure ranking/authorization kernel
equals the oracle on the declared finite domain; the ordered-page walk equals
the oracle when the supplied order is the rank order; a budgeted walk is
exact-or-empty; the comparator is asymmetric symbolically. What is only *tested
by example*: that the datom-backed path realizes the pure kernel (the
store→record mapping is not itself verified). Sections 3–7 are parity-on-
fixture, not proofs.

**Predicate resolution.** The veritas predicates are quoted forms naming
`research.structural.bounded/…` by fully-qualified name; veritas evaluates under
the RUNNING namespace, which `run_ns` binds to the test namespace, so the name
resolves against the globally-interned module namespace — the same mechanism
`datom.profile` uses to call `datom.store/-get` across namespaces.

## Store-boundary work — measured, not a vector-sort relabelling

`datom.profile/watch` + `delta` count at the store boundary. `:rows` is what
came back; `:reads` is `get+range+scan+multiscan+page+count`. The tests assert:

- `candidate-path-reads-fewer-store-rows-than-the-oracle` — the candidate path
  reads strictly fewer store rows than the corpus-wide oracle, and no more store
  requests.
- `candidate-work-is-independent-of-unrelated-corpus-size` — the candidate
  path's store rows are **equal** between a corpus of 6 documents and one of 46
  (40 `"filler"` documents added), while the oracle's rows grow. This is the
  **posting-restriction** claim, measured at the store.
- `page-bounds-examined-not-postings-or-ranking` — the correction: posting rows
  and ranked candidates cover the whole candidate set; only `:examined` is
  bounded.
- `:total` exceeds the page length in the base fixture (`total = 3`,
  `hits = 2`), so a total cannot be read off the page.

## Correctness properties exercised

- **Stable rank / identity tie-break**: equal scores order by ascending eid, and
  the order is deterministic across calls.
- **Pinned basis**: a held `datom/db` value answers unchanged after a revocation
  committed against the live conn; the new value reflects it.
- **Revocation**: retracting a `:doc/reader` datom removes the document from the
  new basis' hits while the held value keeps it.
- **Tombstone**: `:doc/live false` stays a candidate but is never a hit; hard
  `retract-doc!` removes the document and its postings.
- **No readable result**: empty hits and `:total 0` — not an error, not a nil.
- **Cursor provenance**: a cursor carries store/basis/query/principal/order; a
  mismatched basis or principal **refuses** rather than resumes.
- **Sparse ACL**: a denied document ranked above a permitted one is skipped, not
  consumed as a hit.
- **Budget exhaustion**: sparse ACL + a small budget returns `:refused` /
  `:incomplete` with no hits — distinct from the exact empty page a caller would
  read as "no results".
- **Non-positive k**: `k ≤ 0` returns an exact empty result, not an error and
  not a negative overfetch.
- **Ordered page**: single-row pages concatenate to the full rank order; the
  ordered walk equals the oracle for a single term.

## Negative control

- **Logic witness** (veritas, finite): the overfetch shape disagrees with the
  oracle (scope 4).
- **Store witness** (`overfetch-misses-the-permitted-doc-on-a-real-index`): a
  real ETS datom store with six high-score denied documents and one low-score
  permitted document. Expected: `fixed-overfetch-db` returns `[]`, while
  `indexed-topk-db` and `oracle-topk-db` both return the permitted document.

## Production integration seam

Knowledger is a separate tree (`/home/user/code/products/knowledger`); this
spike stays in beam-lisp. The seam facts, for the follow-up:

1. **Schema.** Add an indexed posting attribute (e.g. `:chunk/term`, string,
   `:db/index true`) and posting entities (`:post/chunk` ref, `:post/tf` long).
   Postings are a **derived projection** of `:chunk/text` — maintain them from
   the existing derived/reconciliation machinery, not a parallel cache
   (PLAN-165: extend `datom.derived`/`datom.reconcile`, do not fork).
2. **Read.** Replace `lexical-chunk-hits`' whole-column `datom/q` with a
   `postings-for-term` AVET read per query term, union, and the authorized
   ranked walk. Multikey scoring stays posting-wide; wrap it in
   `budgeted-topk-db` so a query either completes exactly or refuses.
3. **Ordering.** Replace `search-one`'s
   `(take k (readable (search-one-ranked … (* 6 k))))` with the walk that first
   ranks on `db` and applies `knowledger.doc-access/hit-filter` **during** the
   walk, so a permitted row below a denied one is found. `:total` (authorized
   matches) can be reported for the count badge.
4. **Exact production rank index (flagged, NOT built here).** For a genuinely
   bounded **single-term** page, add a rank-ordered posting attribute
   (`:post/rank`, string/index) maintained as a derived projection, and page it
   with `datom.store/page-datoms` (as `posting-page` does). For **multikey**
   top-k to be page-bounded, the same ordered index must carry the summed
   multi-term score, or the engine must have an ordered merge over per-term
   rank indexes. **Neither exists today**; this spike does not build it, and
   `budgeted-topk-db` stays a posting-wide fallback/refusal until it does.
   `datom/attribute-page` is AEVT-only and does **not** page an AVET prefix; the
   ordered page uses the store-level `PageScan` primitive with a key prefix
   built by `string-prefix-key`.
5. **Cursor.** `ranked-cursor` / `ordered-cursor` are the page keys for a "load
   more" affordance; they are rank identities plus provenance, stable under ties
   and refused against a changed basis/permission/query.

## Fallback / refusal conditions (must be preserved in production)

- **No / stale posting index** (a library not yet tokenized, or a maintenance
  lag): fall back to the corpus-scan path — correct, slower — and never return a
  partial-but-silently-short answer. A stale index must be detectable
  (derived-artifact revision); this spike does not implement that validity check.
- **Fewer than k permitted matches**: return what exists with an honest
  `:total`; do not throw and do not pad.
- **No readable result**: empty result, `:total 0` — `:status :exact`.
- **Common-term worst case**: a term posted by nearly every document makes
  `df(term) ≈ corpus`, so the candidate path degenerates to a corpus scan. The
  bounded claim is that work follows the candidate set, not that every query is
  cheap; `budgeted-topk-db` refuses rather than pretending.
- **Substrate without `PageScan`**: the ordered page is correct but wide;
  `:bounded?` is false and `:rows` reports the whole-term read. A caller that
  requires a real bound must check `:bounded?`.
- **Egress**: none. The local lexical candidate path reads only the store.

## What remains unverified / out of scope

- **UNRUN** — no test in this file has been executed; the numbers asserted are
  design expectations. The conditional fjall branch runs only if
  `datom.store-fjall/available?`.
- The store→record mapping is tested, not proved; `datom-candidate ==
  pure-kernel(records)` is assumed.
- The `:incomplete`-after-read branch of `budgeted-topk-db` is not exercised on
  ETS, which is `Count`-capable; it is the no-count-substrate fallback.
- `:post/rank` is built by a one-shot derived pass in the fixture; its
  maintenance under updates (tf changes, re-tokenization) is not modelled.
- The ordered page's rank key assumes terms do not collide with the `"~|~"`
  separator; production must use a collision-free term encoding.
- No fjall/durable path is exercised except the conditional paging-capability
  assertion; the `:bounded?` first-page bound on ETS is the documented
  fallback.
- No concurrency: single process, sequential transactions. Basis pinning is
  exercised against a committed revocation, not against an in-flight writer.
- The ACL model is per-document principal membership; Knowledger's mirrored
  rights are relation-backed (`doc-access`, groups, origins).
- Tokenization, stemming, phrase scoring and multi-field ranking are simplified
  to one posting per whitespace term with a scalar tf.
- `z3` lifecycle: `z3/open` returns a supervised lease handle (`:z3-leases`),
  not a raw port; `z3/with-solver` brackets the symbolic check, and
  `z3pool/pool-stop!` is deliberately NOT called (the pool is VM-wide and shared
  with other suites).

## Files NOT touched

No boot/compiler/runtime file, no production datom module, no Knowledger tree.
Only the three files listed at the top were created.
