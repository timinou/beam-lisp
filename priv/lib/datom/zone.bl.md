# datom.zone — explicit civil time

`decode` accepts TZif bytes; it reads no file, environment variable or host
timezone. Pass its `:ok` zone value into the conversion functions. A data source
belongs to the application's configuration, with its version and provenance.

```clojure
(require '[datom.zone :as zone])
(def utc (:ok (zone/decode supplied-tzif-bytes)))
(zone/resolve-local utc "2026-09-07T08:30")
;; {:status :unique :instant ... :offset 0}
```

`resolve-local` validates exact ISO minute/second input. `resolve-axis` accepts
the equivalent civil coordinate on datom.time's axis. A unique result has
`:instant` and `:offset`; an ambiguous result lists chronological `:choices`.
`:nonexistent` denotes a skipped local time. `:invalid` denotes malformed or
impossible input. Neither folds nor gaps choose an instant implicitly.

`offset-at` answers a datom.time instant with `:status :known`, `:offset` in
seconds, `:dst?` and `:designation`. `local-parts` adds `:parts` and `:instant`.
`civil-text` renders a civil-axis coordinate for minute or second input.

The reader supports version 1–4 POSIX-timescale transition tables and fixed
POSIX footers. Recurring POSIX footers are currently unmodelled: conversion at
or beyond their final table transition returns `:unknown`. Empty future rules
and the `-00` designation also retain unknown coverage. A zone without any
transitions or footer uses its initial declared type. There is no fixed-offset
fallback for an unsupported recurrence. Leap-aware files explicitly refuse
because their timestamps use another scale.

Malformed input returns `{:error {:code ... :why ...}}`. Counts, indices,
ordering, flags, string termination, footer agreement and a 2 MiB input ceiling
bound decoding. Conversion takes a successfully decoded zone and integer
seconds; the server should retain typed instants, not browser milliseconds.

The format contract is [RFC 9636](https://www.rfc-editor.org/rfc/rfc9636.html).
The tests use pinned IANA fixtures and an independent Python zoneinfo reference.
