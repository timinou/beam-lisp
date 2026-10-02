# Edge cases, and what the design does about them

A design is only as good as the cases it survives. This is the connector system
under pressure: two holes that were real (both now closed), a set of cases that
change the design, and the parts that held.

Status vocabulary: **closed** (the mechanism exists — the design was wrong about
it), **decided** (a rule now covers it), **open** (a follow-up owns it).

---

## Part 1 · Two holes, both closed

### H1 · The fill could never fire — closed

The design said a query "translates to a network request naturally", spelled as:

```clojure
:where [?m :conn/key [:gmail "18c…"]]      ; ✗ the provider is NEVER called
       [?m :~msg/messages ?subject ?from ?when]
```

**A clause that matches nothing produces no rows, so the join never reaches the
`:~` clause and the provider never runs.** A fill cannot be a filter *over the
mirror*, because the mirror is precisely what is missing.

The fix needed no new clause kind: `datom` already has a clause that **binds** —
*"A predicate `[(> ?age 40)]` filters. A function `[(* ?age 2) ?double]` binds."*
So the fill is a **function clause**:

```clojure
:where [(conn/ensure :~msg/messages ?key) ?m]
       [?m :~msg/messages ?subject ?from ?when]
```

with three requirements that follow from the engine's semantics rather than from
taste:

- **self-contained** — input from `:in` and literals only, because clause order is
  the planner's business, not the author's;
- **idempotent** — it may run once per binding row, and the `:unique` window makes
  that free;
- **key-only** — a `:bf` fill would run inside the very scan it was feeding.

### H2 · RLS cannot gate a fill — closed

An earlier revision claimed fills were "safe by construction". That is true of one
thing and false of another, and the difference matters:

- **True:** no *cross-connection* leakage. A fill resolves its credential from the
  **connection**, never from the query, so connection A can never cause a request on
  connection B's token.
- **False:** connection A's token can still be used *on behalf of* a principal who
  should not have it. `auth.rls` narrows **rows**; a fill is an **action**, and there
  is no row yet to narrow — the fill is what creates it.

**∴ RLS gates what you READ. An authorization check gates what you DO.**
`conn/ensure` checks `(env/principal)` against the account itself, before fetching.

---

## Part 2 · Cases that change the design

### E1 · A renamed mailbox orphans the mirror — decided

Workspace admins rename users. If `:conn/account-id` is the address, a rename changes
every key at once: the mirror misses wholesale and re-syncs into a *second copy* of
every entity, orphaning the first.

**Decided:** the account identifier is the provider's **immutable subject** —
Google's OIDC `sub`, *"unique among all Google accounts and never reused"*. The
address becomes `:account/label`, a mutable attribute. The same rule kills a second
bug for free: after a revocation and re-consent the grant is provably the *same
account*, because the subject is the same.

### E2 · One message in two mailboxes is two entities — decided, and correct

The same mail delivered to work and home produces two rows, and that is honest: there
are two mailboxes, two read states, two label sets. `as-of` will even show them
diverging. It is not a bug, and it must not be "fixed" by deduplicating on content —
that would merge two things that genuinely differ.

But the *everything index* wants "show me this thread once". That is a **query**, not
a schema: dedup on the one identity every provider agrees on, the RFC `Message-ID`.
**∴ the domain pack carries `:msg/rfc-id`** — Gmail exposes it in `payload.headers`,
Graph as `internetMessageId`, IMAP natively — and dedup becomes a rule, not a
special case in the mirror.

### E3 · Two connections, one account, different scopes — open

An app connects the same mailbox twice: once `gmail.readonly`, once `gmail.modify`.
By §1 both resolve to the **same** `:conn/account-key` — right for the mirror (same
mailbox, so the rows *should* be shared) and wrong for the cursor and the credential,
which are per-grant.

Worse than cosmetic: two connections keeping the same aspect both write the cursor,
and the slower overwrites the faster — **silently skipping changes**, which is the
exact failure mode §2's laws exist to prevent.

**Decided in shape, open in build:** the *mirror* is keyed by account; the
*credential and the cursor* are keyed by `(account, scope-set)`. And **the cursor row
IS the lease** — `proc.queue` already has `:lease`, and its window doctrine ("the
window CLOSES when the job settles") is exactly exclusive ownership. A second
connection then either shares the lease or is refused, and neither outcome can
silently skip.

### E4 · A shared mailbox has more than one principal — decided

A team mailbox is authorized by several people, and each may connect it. So
`:conn/principal` is **cardinality-many**, and the membership filter of
`accounts-and-credentials.md` §2 joins through it without caring how many there are.

### E5 · Multi-account scoping must be a join, not an equality — closed

`auth.rls/attribute-filter` binds one constant. Two accounts as two injected clauses
would **AND** — and `[?m :conn/account-id "a"] [?m :conn/account-id "b"]` against a
cardinality-one attribute matches *nothing*. The failure is silent: an empty result
reads as "no mail", not as "your permission filter is unsatisfiable".

**Closed** by the membership filter, which needs no engine change: `inject` takes any
clause vector, and `rls`'s own docstring already names membership as the
generalisation.

### E6 · An RLS filter can hijack the caller's variables — open

A filter that binds `?acct` will silently **join** to the caller's `?acct` if they
happened to write one. Two consequences, and they are not the same severity:

- It can never **widen** — monotonicity holds, and that is the property the whole RLS
  design rests on.
- It can silently **narrow** the caller's own query. The filter's
  `[?m :conn/account-id ?acct]` and the caller's `[?x :something ?acct]` now
  intersect, and the caller gets fewer rows than their query meant, with no error.

**Fix:** the filter builder parses the caller's query, collects its variable set, and
picks names it does not use. Mechanical and testable — and it belongs in `auth.rls`,
not in the connector, because *any* filter that binds fresh variables has this
problem.

### E7 · A fill-bearing query is not a fast read — decided

`conn/ensure` blocks on the network, so a `datom/q` containing one has network
latency and a fence. **A UI must never run one in a render path.** This generalises
the environment note that I/O can stall arbitrarily — nothing that renders should
depend on it.

**Decided:** `ensure` is fenced (60 s default); a fill-bearing query is documented as
a *fetch*, not a read; and `conn/keep` is the answer for anything that renders — keep
the aspect warm and let the render path read the mirror.

### E8 · A multi-day backfill dies on the 7-day token — open

The Testing-status refresh token expires in 7 days. A backfill that dies from
`invalid_grant` correctly commits **no** sync cursor — a partial sync token would be
a lie, and the next run would silently skip the gap.

But that also discards the whole run's work. **Decided:** the backfill needs its own
**position row**, committed *per page* — safe because mirror writes are idempotent
(§2 law 2) — wholly distinct from the sync cursor, which commits only at end-of-run.
A backfill page never writes a cursor; a sync never writes a backfill position.
Owned by `FUP-119`.

### E9 · Erasure versus an append-only store — open

`datom` never forgets: changing an attribute appends a retraction, and `as-of` still
resolves the old value. For a personal index that is the whole point. For a SaaS with
a GDPR erasure obligation it is a liability — and RLS does not fix it, because RLS
hides rows, it does not remove them.

**The answer already exists in the tree:** excision. **Decided in principle:**
erasure is an **explicit, audited excision**, never a side effect of a sync. A sync
must never be able to destroy history, and a deletion *at the provider* is a **fact**
(Drive's `trashed`, a remote deletion), not an excision.

### E10 · Freshness rides on the wall clock — decided

`:fresh "PT5M"` compares against now. A machine with a badly wrong clock treats
everything as stale (a fill storm against a metered API) or everything as fresh
(stale reads served as current).

**Decided:** freshness is **advisory** and the **ETag is authoritative** — the same
posture as the budget ("the meter is advisory; the 403 is authoritative"). A 304
costs 5 units instead of 100, and it is the only thing that actually knows.

### E11 · An unguarded query is a bug, and dropping `conn/q` removed the choke point — open

Queries now go straight to `datom/q`, which is a feature — but it means there is no
single place where the connector could enforce a principal. The repo's existing
answer is the route layer (`auth/guard`), and that is fine; what is missing is making
the omission *visible*.

**Open:** a lint, or a `conn/scoped` that requires a principal and is the documented
way to run a connector query. Not a gate — a way to see.

---

## Part 3 · What held under pressure

Recorded because it is evidence rather than assertion:

| stressed | result |
|---|---|
| **`auth.rls` composes with time travel** | injected clauses *"carry no basis of their own"*, so a guarded query behaves identically against `as-of`, `since` and `valid-at` — a principal's rows are scoped in a historical view with no extra machinery |
| **injection is monotonic** | an injected filter *"is incapable of granting access to a row the unfiltered query would not have returned"* — a buggy filter can only hide, never leak |
| **`[?x ...]` collection binding is real** | *"takes MANY values — this is how you write `IN (...)`"*, so account sets need no query rewriting |
| **the composite key prevents silent mailbox merging** | and it makes `:bb` fills unambiguous, since the bound key names the account *and* the service |
| **no cross-connection leakage** | the credential resolves from the connection, never the query — the property survives every case above |
| **`:unique` doubles as single-flight and idempotency** | so `ensure` may be called many times per query and still issue one request |
| **`:lease` is available for the cursor** | E3 needs no new mechanism, only a decision to use the one that exists |
| **content addressing makes retries idempotent** | Drive's `sha256Checksum` means a re-fetched file cannot duplicate |
| **`datom.migrate` gates tier promotion** | a wrongly-placed attribute is visible through `plan` against real data, not through discipline |
| **`:db.type/time` is AVET-orderable** | the cross-domain time join is an index seek, not a scan |

---

## What this changes

- **`an-api-is-a-relation.md` §3** — the fill is a *function clause*: self-contained,
  idempotent, key-only; and `ensure` authorizes.
- **`accounts-and-credentials.md`** — the account identifier is the immutable
  subject; `:conn/principal` is cardinality-many; §2 answers scoping, with RLS gating
  reads and authorization gating actions.
- **`FUP-119`** — the backfill needs a position row distinct from the sync cursor.
- **Two follow-ups** — hygienic RLS filters (E6, which belongs to `auth`, not the
  connector) and the cursor-as-lease plus the visible-principal lint (E3, E11).
- **`PLAN-137`** — the hazards list carries E9 (erasure is excision, never a sync
  side effect) and E10 (freshness is advisory).
