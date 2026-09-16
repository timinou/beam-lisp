# datahike ↔ datom differential oracle

PLAN-115 proves the datahike API is a **projection of datom's single engine**,
not a second engine. This harness keeps that claim honest, feature by feature,
with published datahike as the oracle.

## The pieces

| file | role |
|---|---|
| `corpus.edn` | Scenarios in datahike's spelling — schema, txes, reads. The **one** source of truth both engines run. |
| `run_jvm.clj` | Runs the corpus against datahike `0.8.1861`, freezes typed answers → `expected.edn`. |
| `expected.edn` | **Committed** JVM answers, engine-neutral encoded. The gate needs no JVM. |
| `../../bl/datom/datahike_differential_test.bl` | Replays the identical corpus through datom, compares to `expected.edn`. |

## Encoding (engine-neutral)

The two engines' native reprs never have to match structurally — only their
meaning does:
- decimals → `{:dec "100.05"}` (plain string)
- query result sets → a **sorted** vector of tuples
- collection find (`[?x ...]`) → sorted vector
- pull → the map, ref values as `{:db/id N}`
- entity → the map with `:db/id` dropped (ids are not stable across engines)
- an expected error → `{:error true}`

Entity identity is compared only through a `:db/unique` attr, never by raw eid.

## Scenario status

Each scenario carries `:status`:
- `:ready` — datom must match the JVM **now**; the test asserts it.
- `:pending` — waits on a wave's datom feature; reported, not asserted.

`expected.edn` holds the JVM answer for **both**, so a wave flipping
`:pending → :ready` needs only a corpus edit, never a re-capture.

## Running

```sh
# capture (only when the corpus changes — needs the JVM + network for datahike)
clojure -Sdeps '{:deps {org.replikativ/datahike {:mvn/version "0.8.1861"}}}' \
        -M test/oracle/datahike/run_jvm.clj

# the gate (no JVM)
mix bl test test/bl/datom/datahike_differential_test.bl
```

## The driver

In W0 the bl side is a **direct, documented hand-translation** of the datahike
call onto datom's API (q arg-order, report-key rename). From W1 the real
`datahike.api` shim **replaces** that driver — the test then exercises the shim,
and the hand-translation is deleted. The `:pending` scenarios are the W1+ TODO
list, each pinned to the exact divergence its wave must close.
