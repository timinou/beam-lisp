# Lazy cache admission: one linearized byte quota (PLAN-154 B, repair of the two-counter reservation)

Supersedes **§2.2 "The atomic reservation"** of
`!tasks/artifacts/lazy-budget-admission-repairs.md` (the two-counter protocol).
Everything else in that artifact — the counted overheads (§2.1), where admission
is applied (§2.3), the peek (§PLAN-154 D), the lane routing, the host-side
`admit!` semantics — is unchanged and still describes the shipped code.

Writer scope for THIS repair: `native/lazy_memo/src/lib.rs` only, plus this
file. Host files (`priv/host/*.bl`, `priv/boot/*.bl`, seeds, `.so`) were read but
not modified; the uncommitted native/host changes of the previous worker are
preserved (this diff adds to them).

Verification actually performed: `cargo test --offline` (25/25 green, repeated
8×) and `cargo build --offline` (zero warnings) in `native/lazy_memo`. No VM was
started, no seed regenerated, no publication run, no git staging.

---

## 1. The defect

Shipped (rejected) protocol, verbatim shape:

```
admission:  held = RESERVED.load();  if RETAINED.load() + held + delta > budget -> Over
            RESERVED.CAS(held, held + delta)
commit:     RETAINED += new ;  RETAINED -= old ;  RESERVED -= delta
```

Two counters, one CAS. The CAS token (`RESERVED`) is only HALF the state the
guard tested, so the guard's snapshot is torn and the CAS can succeed against a
retained total the publisher never observed.

### 1.1 The interleaving that overadmits (ABA)

`budget = 100`, empty ledger, publishers **A** and **B**, each wanting a 60-byte
growth:

| # | A | B | ledger |
|---|---|---|---|
| 1 | | read `RESERVED = 0`, `RETAINED = 0`; guard `0 + 0 + 60 <= 100` passes | 0 / 0 |
| 2 | reserve 60 → `RESERVED = 60` | | 0 / 60 |
| 3 | commit: `RETAINED = 60`, `RESERVED = 0` | | 60 / 0 |
| 4 | | `CAS(RESERVED, 0 → 60)` **wins** — the token it guarded on came back | 60 / 60 |

Final occupancy `60 + 60 = 120 > 100`. The commit in step 3 moved BOTH counters
and restored the one B was CASing: a word-level ABA. `reserve_loop`/`reserve_once`
both had this shape (`RETAINED` read once, `RESERVED` CASed).

### 1.2 The second, quieter hole: subtract-before-add

Two paths (`compare_exchange_impl`, `put_impl` — the policy-exempt ref/volatile
writes) committed as

```rust
saturating_sub(&RETAINED_BYTES, old.retained_bytes);
saturating_add(&RETAINED_BYTES, retained_bytes);
```

For the window between those two atomics the *published total was transiently
LOW by `old`*, so an admission racing it could reserve room that was about to be
taken. The admitted path had the order right (add first); these two did not.
A ledger must never under-state itself — over-stating only refuses early.

---

## 2. The protocol now

One authoritative word. `retained` and `reserved` survive **as diagnostics only**.

```rust
struct Ledger {          // native/lazy_memo/src/lib.rs
    occupied: AtomicUsize,   // AUTHORITATIVE: committed bytes + bytes in flight
    retained: AtomicUsize,   // diagnostic: committed half
    reserved: AtomicUsize,   // diagnostic: in-flight half
}
static LEDGER: Ledger = Ledger::new();
```

```
reserve(delta, budget, fast?):
    loop { held = OCCUPIED.load()
           target = held.checked_add(delta)   // overflow -> Over, never a wrap
           if target > budget -> Over
           if OCCUPIED.CAS(held -> target) -> Ok            <-- LINEARIZATION POINT
           else retry (fast lane: single attempt -> Contended) }
    on Ok: RESERVED += delta            // diagnostic mirror

release(delta):    OCCUPIED -= delta ;    RESERVED -= delta        // abandon paths
enter(bytes):      OCCUPIED += bytes ;    RETAINED += bytes        // a state arrives
leave(bytes):      OCCUPIED -= bytes ;    RETAINED -= bytes        // a state departs
commit:            enter(new) ; leave(old) ; [release(delta) if reserved]
```

`delta == 0` takes no CAS and touches no counter: a claim, a waiter registration
or a terminal un-strand still costs exactly zero atomics on the byte ledger.

### 2.1 Every path that moves the ledger

| path | ledger op | note |
|---|---|---|
| `allocate` / `nif_new` / `nif_new_fast` / `nif_cursor` (initial value) | `enter(retained_bytes)` | creation is gated in the host by `admit!`; not budget-refused natively (unchanged policy) |
| `MemoCell::destructor` (last ref dropped) | `leave(state.retained_bytes)` | one debit; `Mutex<Option<State>>::take` ran first |
| `MemoCell::detach` (cycle collector breaks a dead cycle) | `leave(state.retained_bytes)` | exactly once; `detach` and `destructor` are mutually exclusive through the same `take` |
| `exchange_version_impl` — GROWING commit | `enter(new) ; leave(old) ; release(delta)` | net `new − old − delta == 0`: the credit BECOMES retained |
| `exchange_version_impl` — SHRINKING/equal commit | `enter(new) ; leave(old)` (`delta == 0`) | net `−(old − new)`: the word falls by exactly the shrink |
| `exchange_version_impl` — abandon (cycle / new-edge fast reroute) | `release(delta)` | before the state lock is dropped |
| `exchange_version_impl` — ceiling verdict | nothing | `Over` never took a credit |
| `exchange_version_impl` — lost fast-lane CAS | nothing | `Contended`; a failed CAS leaves the word where the winner put it |
| `exchange_version_impl` — unreachable emptied-cell arm | `release(delta)` | defensive: a credit must not leak on an `Err` return after a reserve |
| `compare_exchange_impl` (unadmitted ref write) | `enter(new) ; leave(old)` | no credit; order fixed to add-before-subtract |
| `put_impl` / `put` (unadmitted volatile write) | `enter(new) ; leave(old)` | same |
| `reclaim_*` / `enqueue_reclaim` | **no ledger op** | bytes were already debited when the state left the live set; dropping an `OwnedEnv` is not a byte event |

`alloc` of a `Cursor` is `read_only` and charges only its source cell's state,
so it needs no separate debit.

### 2.2 Ordering rules (load-bearing)

1. **Add before subtract, always.** Every multi-op transition (`enter`/`leave`,
   commit = `enter`+`leave`+`release`) can transiently over-state `occupied`
   but never under-state it. Over-stating refuses early; under-stating
   overadmits. (`enter` itself is two atomics — `occupied` then `retained` — and
   `leave` mirrors it; a diagnostic reader can see them disagree by one state's
   bytes mid-flight, which is why no decision may read the diagnostics.)
2. **The commit releases the credit LAST**, after the replacement is retained.
   Releasing first would let a racing admission take room that is about to be
   re-occupied.
3. **The credit lives only on the reserving call's stack.** It is created inside
   `Ledger::reserve` and consumed by `Ledger::release` — called either by the
   abandon arms or by the commit of the SAME invocation. It is never published
   as a per-cell token, so no other publisher can release it, and `reserved` (the
   boolean that says a credit was taken) is a local.

---

## 3. Why it is sound

**Ledger invariant.** `occupied = Σ(live state bytes) + Σ(in-flight credits)`
holds at quiescence, and `occupied ≥` that sum at every instant.

**L1 — the guard and the CAS are the same read.** `reserve_loop`/`reserve_once`
load `occupied` once, compute `target = held + delta`, and CAS *that word* from
*that value*. `target > budget` therefore describes the true occupancy at the
instant the CAS is attempted: a CAS that succeeds means "occupancy was `held` and
`held + delta` fits".

**L2 — ABA is benign with one word.** Suppose the word moves away and back to
`held` between the load and the CAS (cancel, or commit+release). The CAS still
succeeds — soundly, because a restored value means the *occupancy* is `held`
again, not that a stale half of a pair was restored. Nothing was committed in
that interval that the guard did not already see, because a commit can only
return the word to `held` by *shrinking* it (a growing commit leaves it
`held + delta`). In the two-counter version the restoring value belonged to a
different quantity than the one the guard's retained read described — that is
exactly the overadmission of §1.1. The regression test `the_torn_two_counter_
snapshot_overadmits_the_rejected_protocol` scripts that interleaving against a
copy of the rejected protocol (and asserts 120 > 100), while
`the_single_quota_guards_and_cas_the_same_word` scripts the same interleavings
against the ledger: the cancelled one admits (soundly) and the committed one is
refused.

**L3 — no hole at the reserve/commit boundary.** While a credit is outstanding
the growth is *already* in `occupied`, so every concurrent admission counts it.
At the commit the word is `+new`, then `−old` (transiently high), then `−delta`,
landing on `Σretained_new + Σother credits` exactly. For a growing publication
the net is zero — the reservation becomes retained without the word ever
dipping — so there is no instant at which the bytes are neither reserved nor
committed.

**L4 — the ceiling is a real bound.** Reservations are serialized by the single
CAS, and every later admission reads the word the CAS wrote, so at most
`budget − Σreserved` bytes of further growth can be admitted while a credit is
outstanding. Two publishers that each start below the ceiling cannot jointly
exceed it (`concurrent_reservations_never_jointly_exceed_the_budget`,
`the_fast_lane_admits_at_most_one_growth_that_fits_once`,
`two_publishers_that_do_not_jointly_fit_the_ceiling`). The one honest caveat is
policy, not protocol: **unadmitted** publications (ref/volatile writes, cell
creation) are exempt and can take the total over the ceiling by themselves —
they keep the ledger exact, but the ceiling bounds only the admitted paths.

**L5 — exactly once.** A credit is created under the target cell's state mutex;
the same invocation holds that mutex from the reserve to the commit or to the
release, so no other publisher can be inside the window on that cell, and the
cell can be neither destructed (the NIF holds the `ResourceArc`) nor detached by
the collector (`detach` needs the same mutex) meanwhile. `enter`/`leave` are
paired per state, and a state leaves the live set exactly once because
`Mutex<Option<State>>::take` is the only way out (`destructor` then sees `None`).
Tests: `a_credit_is_released_exactly_once_and_only_by_its_holder`,
`a_commit_consumes_its_credit_without_a_hole_in_the_ledger`.

**L6 — bounded, non-blocking fast lane.** Admission is one CAS. There is no new
global lock and no spin on the fast lane (`reserve_once` answers `Contended`, and
the host reroutes to the dirty lane); the dirty lane's retry loop holds only its
own cell's mutex, so publishers on different cells cannot deadlock.

---

## 4. Invariants to hold the next patch to

1. `LEDGER.occupied == retained + reserved` at quiescence (asserted by
   `assert_ledger_exact` in every new test).
2. `occupied ≥ Σlive + Σcredits` at ALL times — never under-state: add before
   subtract, release the credit last.
3. Only `Ledger::reserve` may create a credit; only `Ledger::release` may consume
   it; each credit is consumed exactly once, in the reserving call.
4. Every admission decision reads `occupied` and nothing else. `retained` and
   `reserved` are for `nif_retained_bytes`/`nif_reserved_bytes`/`stats` only.
5. Every path that changes a state's byte count calls `enter`/`leave` (a new
   path that moves a state without touching the ledger is a bug, not an
   optimisation).
6. A growth of 0 must remain CAS-free: control transitions must commit at any
   budget, or a refused publication strands its owner and waiters.

---

## 5. Tests added (`native/lazy_memo/src/lib.rs`, `mod tests`)

| test | proves |
|---|---|
| `the_torn_two_counter_snapshot_overadmits_the_rejected_protocol` | the counterexample: the rejected protocol jointly exceeds the ceiling (120 > 100); `torn_guard`/`torn_cas` are the rejected code, kept as the yardstick |
| `the_single_quota_guards_and_cas_the_same_word` | the restoring (cancelled) interleaving admits soundly; the committing interleaving is refused |
| `a_commit_consumes_its_credit_without_a_hole_in_the_ledger` | growing commit leaves `occupied` where the credit put it; shrinking commit lowers it by exactly the shrink; never dips below the truth; `reserved` settles to 0 |
| `two_publishers_that_do_not_jointly_fit_the_ceiling` | two 60-byte growths under a 100-byte ceiling: one `Ok`, one `Over`, and the loser still `Over` after the winner commits |
| `a_credit_is_released_exactly_once_and_only_by_its_holder` | A's release returns exactly A's delta; B's credit and the committed total are untouched; nothing leaks |
| `a_lost_cas_leaves_the_ledger_where_the_winner_put_it` | `Contended` is a no-op: no credit, word unchanged |
| `the_fast_lane_admits_at_most_one_growth_that_fits_once` | 8 racing fast attempts → exactly one `Ok`; deterministic outcome under a nondeterministic scheduler |
| `concurrent_reservations_never_jointly_exceed_the_budget` | 16 threads × 100 bytes on a 1000-byte ceiling never exceed it |
| `an_unadmitted_write_never_understates_the_ledger` | enter-before-leave keeps the total above the truth during a policy-exempt ref write |
| `an_unrepresentable_growth_is_refused_not_wrapped` | `checked_add` overflow at the ceiling → `Over`; `accounted_bytes(u64::MAX)` → `badarg` |
| `a_non_growing_publication_is_never_refused` | `delta == 0` is `Ok` at/over the ceiling and touches no counter |
| `admission_reserves_only_while_the_total_fits_the_budget`, `a_released_reservation_returns_the_room_it_held`, `the_fast_lane_answers_over_rather_than_contending` | the primitive's `Ok`/`Over` boundaries (rewritten from the two-counter form) |

The five reservation tests that referenced the old two-counter signatures were
rewritten against `Ledger`; all other tests in the module are untouched and
still pass (`accounting_never_wraps`, `the_cell_overhead_is_charged_with_the_
payload`, `growth_is_only_the_excess_over_the_state_replaced`, cycle search,
`edge_plan`, `Version`, `Deps::Keep`, plus the collector's own tests).

---

## 6. Preserved surfaces

* Public NIF names and arities are unchanged; **no** NIF was added or removed.
  `nif_retained_bytes/0` and `nif_reserved_bytes/0` keep their names and answer
  the same quantities (now the diagnostics), so the host's
  `retained_bytes + reserved_bytes` reading remains the total occupancy.
* `nif_peek/1`, `nif_exchange_version_admitted/8`,
  `nif_exchange_version_admitted_fast/8` and every pre-existing NIF are
  untouched.
* `MemoStats` keeps exactly its previous field set (`op_peek`, `op_budget`,
  `reserved_bytes` included); no field was renamed, added or dropped.
* The `RETAINED_BYTES`/`RESERVED_BYTES` statics were folded into `Ledger`; no
  public read shape changed.

---

## 7. Remaining risks (honest)

1. **Behaviour change at the extreme: `accounted_bytes`.** It was
   `size_of::<MemoCell>().saturating_add(estimate)`; it is now
   `checked_add(..).ok_or(BadArg)`. On a 64-bit target the only reachable
   difference is an estimate that would overflow `usize` (previously it saturated
   — which would have wedged the cache at `usize::MAX` and, worse, made later
   subtractions under-state the ledger). Such an estimate is now `badarg`. On
   32-bit targets `u64` estimates that do not fit `usize` were already `badarg`.
   No caller in `priv/host` passes a value near either boundary.
2. **`saturating_add`/`saturating_sub` still clamp.** They now early-return on
   `0`, but a *real* underflow would still clamp at 0 rather than panic. That is
   only reachable if the invariant is broken (a double `leave`, a missing
   `enter`). A `debug_assert` on the pre-state would catch that earlier; it was
   not added because these helpers are also used by tests on bare counters.
3. **Diagnostic drift is visible but harmless.** A `stats/0` reader can catch
   `occupied` and `retained` mid-transition. Nothing decides on them; the host
   test `the-cheap-counter-agrees-with-the-stats-map` compares each diagnostic
   against its own NIF, which is consistent by construction.
4. **`admit!` still reads `retained_bytes/0` alone** (host, by design: it is the
   pre-claim soft gate; the sound enforcement is the native reservation). Under
   contention it can therefore refuse a claim that the native admission would
   have admitted, or admit one the native side refuses later. That asymmetry is
   pre-existing and documented in the host docstring; not changed here.
5. **The ceiling does not bound unadmitted paths.** Ref/volatile publications and
   `nif_new` add bytes without a reservation. This is the remembered policy
   (§2.3 of the repairs artifact), not a bug, but it means a hostile ref workload
   can exceed `lazy_cache_budget_bytes`.
6. **Host-side fold ownership (out of scope, appears already repaired).** The
   review of the previous revision reported that `publish_folded` could run a
   recipe without ownership and that a budget refusal after the recipe leaves the
   cell `:pending`, so the next consumer repeats already-executed effects. The
   host docstring in `priv/host/lazy_seq.bl` now states the reducing consumers go
   through `claim_recipe` + `complete_attempt`, and `publish_folded` is described
   as "UNCLAIMED, AND NO LONGER THE FOLD PATH". I did not trace that call graph
   and did not touch host files; if the report is still live it is a host-side
   repair, not a native one.
7. **No end-to-end evidence here.** These are pure-Rust unit tests; the NIF was
   not rebuilt, no BL/VM suite was run, and `priv/native/lazy_memo.so` (gitignored)
   plus the committed seed still predate the previous worker's NIFs. The runtime
   gates (`test/bl/lazy_budget_test.bl`, `memo_bounds_sunset_port_test.bl`, …)
   remain the orchestrator's.
