# Current values in reverse order

Datom's current reverse facet answers “which entities have these values?” from
live values. Its key order is attribute, value, entity, using the existing Datom
codec under a private internal prefix. History stays authoritative for older
transaction bases, valid-time views and incomplete adoption.

The facet belongs to `datom.current`. It shares the native store and atomic source
commit with forward current pairs and committed attribute marks. It supports
schema-indexed attributes, whose values already have an ordered AVET encoding.
It has no application-owned counter, cache, budget ledger or background scheduler.

## Coverage and reads

Each attribute has a durable header containing format, schema definition, epoch,
phase, source cutoff, source through-basis and bounded adoption cursor. A header
is current only when its through-basis equals the committed attribute mark.
An older writer advancing that mark invalidates the header. A later maintained
write cannot certify a gap.

`datom.current/reverse-values` accepts an immutable database, attribute and optional
excluded values. A certified hit returns current `[entity value]` rows. `nil`
requires the caller's ordinary historical path. Excluding a value uses physical
ordered ranges around its exact prefix.

A hit requires a current view without since/valid-time filters, matching schema,
complete coverage and a through-basis no newer than the database's basis. Header
and committed marker are checked before and after materializing rows. A concurrent
relevant commit discards the result. Snapshots never borrow newer values.

## Source commits

The native connection passes schema to the extended current transaction-ops port.
Each changed pair uses the existing current-value reduction, preserving realized
transaction order and cardinality. Retractions remove old reverse entries;
assertions publish current entries in the SAME source commit.

An empty attribute can be certified on its first commit after bounded native
probes establish that source history and derived prefixes are empty. A preexisting
or incomplete attribute stays uncertified. Unsupported bounded substrate access
never becomes an empty-column assertion.

Excision removes the named reverse values and dirty entries with source erasure,
then advances coverage in that SAME commit. It cannot leave a derived value that
later adoption resurrects.

## Bounded adoption

`datom.conn/adopt-current!` performs one bounded step in the existing writer turn.
It accepts a physical-row budget, not a promise that an entity has little history.
The store must support native bounded ordered pages; no whole-range paging
fallback is certified as bounded.

1. **Clear.** Delete stale facet and dirty-prefix rows in bounded pages. Source
   writes remain authoritative and advance coverage metadata. They do not publish
   partial reverse results.
2. **Build.** Capture the current attribute cutoff under the writer. Scan AEVT in
   bounded physical pages. Apply only source datoms through that cutoff. New native
   writes maintain reverse values concurrently. During this phase removals retain
   current-basis tombstones and an ordered dirty frontier, so an older scanned
   assertion cannot resurrect a newly retracted value.
3. **Drain.** Once the source cursor finishes, no older assertion can replay.
   Later writes use ordinary physical deletion. Bounded dirty-frontier steps
   remove remaining tombstones, checking their current value under the writer.
4. **Complete.** An empty dirty frontier and matching source marker are certified
   atomically. No unbounded final rescan or stop-the-world history rebuild occurs.

A legacy marker gap or changed schema restarts clearing. Crashes retain phase and
cursor. Readers use correct historical fallback throughout incomplete phases.
Source commits and adoption pages share the SAME writer, so a concurrent update
cannot fall between captured coverage and derived publication.

## Native capacity consumer

The capacity active-state relation first asks the certified facet and physically
excludes exactly `:released`. Unknown keyword states remain counted. Missing-state
and immutable-identity guards remain authoritative. Until adoption completes,
capacity uses its existing correct indexed-history path. Fresh stores can certify
from their first state commit; old stores advance through bounded native steps.

## Required qualification

All source is unqualified until these native gates pass:

- Fresh empty/current coverage, many-valued changes, same-transaction retract and
  reassert, excision, refused commits and durable reopen.
- Old bases, history, since and valid-time views; a source commit between coverage
  check and row read must trigger fallback.
- Old stores, interrupted adoption, actual concurrent writer changes, and legacy
  committed attribute marks without facet maintenance.
- At least 100 actual queue enroll/cancel/release cycles, then native capacity
  admission/repair with zero released-history index traversal after certification.
- Unknown states still count, unknown effects still block release, original body
  execution remains once, and incomplete coverage never returns fabricated emptiness.
