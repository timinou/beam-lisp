# Three tiers: universal → domain → service

A connector mirrors remote things into `datom`. The first question is not "how do
we fetch?" — it is **"where does an attribute live?"**, because the answer decides
whether a query survives a change of provider.

Get it wrong in the small direction and every provider needs its own query. Get it
wrong in the large direction and the domain model is a fiction nobody fills. So the
placement is decided by a rule, not by taste:

```
T1  UNIVERSAL   :conn/*                                    every remote resource
T2  DOMAIN      :msg/*  :sched/*  :file/*  :person/*       what KIND of thing it is
T3  SERVICE     :gmail/*  :gcalendar/*  :gdrive/*  :graph/*   the quirks
```

One entity carries all three:

```clojure
{:conn/service  :gmail            ; T1 — who it came from
 :conn/account-id "me@work.com"   ; T1 — which mailbox
 :conn/remote-id "18c…"           ; T1 — the provider's id
 :conn/title    "Q3 planning"     ; T1 — the shared display projection
 :msg/thread    "18c…"            ; T2 — a message's own shape
 :msg/labels    #{:inbox :starred}; T2
 :gmail/label-ids ["INBOX" "STARRED"]}  ; T3 — the provider's own spelling of it
```

---

## The placement test

One question, asked in order:

| question | if yes |
|---|---|
| does **every** remote resource have it? | **T1** |
| do **two unrelated providers of the same kind** have it? (Gmail ∧ Graph; Calendar ∧ CalDAV; Drive ∧ S3) | **T2** |
| does **only one**? | **T3** |
| must a query **survive a provider swap**? | it must be T1 or T2 — otherwise it is provider-coupled *by design*, and should say so in writing |

The last row is the one that matters. "Provider-coupled by design" is a legitimate
answer — sometimes you *want* Gmail's `labelIds`. What is not legitimate is being
provider-coupled without knowing.

---

## The three rules

**R1 — a one-way door.** A lower tier may *add*, never *redefine*. There are two
steps now, so there are two chances to notice. `:msg/labels` is fine; a second
`:gmail/title` means T1 is missing an attribute and should grow one.

**R2 — absence is the null.** A T2 attribute is *optional by construction*: a
provider that cannot fill `:msg/in-reply-to` simply does not write it. `datom` has
no NULL, so "this provider does not expose it" and "it has no value" are the same
honest fact — and `:conn/raw` still holds whatever it *did* say, so nothing is
lost by declining to promote something.

**R3 — relations are T2, specs are T3, and `:as` is the adapter.** This is the
load-bearing one:

```clojure
;; T2 — msg.bl. The RELATION, and the SHAPE of its fill. No method is named.
:~msg/messages
{:arity 4
 :mirror {:entity :conn/key :cols [:conn/title :msg/from :conn/when]}
 :fill   {:on-miss :key :key :conn/key :fresh "PT5M" :max 1}
 :scan   {:page :page}}

;; T3 — connector/google/gmail.bl. The SPEC, binding a method onto that relation.
:gmail.messages.get  {:http [:get "/gmail/v1/users/{userId}/messages/{id}"]
                      :as   {:relation :~msg/messages :mode :bb}}
:gmail.messages.list {:as   {:relation :~msg/messages :mode :bf}}

;; T3 — connector/microsoft/graph.bl. A DIFFERENT provider, the SAME relation.
:graph.messages.get  {:as   {:relation :~msg/messages :mode :bb}}
```

Two things fall out, and both are the point:

- **A query never names a provider.** `[?m :~msg/messages ?subject ?from ?when]`
  returns Gmail *and* Graph messages, told apart by `:conn/service`. Swap providers
  and the query is unchanged — the last row of the placement test, satisfied
  structurally rather than by discipline.
- **The key is `:conn/key`, the composite, not `:conn/remote-id`.** Two providers'
  ids collide in a shared relation, so identity must be the tuple. A `:bb` fill is
  then unambiguous **by construction**: the bound key already names the service, so
  the fill knows which provider to call, and a key from a service this connection
  does not have is a clean error rather than a guess.

**T2 must not live under `connector`.** A message imported from a local mbox and a
message synced from Gmail must be **the same entities**, or the join between them is
impossible. So the domains are their own modules, at the level `datom`'s domains
already occupy:

```
priv/lib/connector/schema.bl        T1 — the universal pack
priv/lib/msg.bl                     T2 — :msg/*, the :~msg/* relations
priv/lib/sched.bl                   T2 — :sched/*; interval algebra, free/busy
priv/lib/person.bl                  T2 — identities, shared by every domain
priv/lib/datom/file.bl              T2 — :file/*, joining its own DFile
priv/lib/connector/google/gmail.bl  T3 — the spec, and its few :gmail/* quirks
```

`connector` depends on the domains it can serve; a local importer depends on `msg`
without depending on `connector` at all. `datom.file` is both the precedent and the
proof: its docstring already tells you to *"look files up by a sibling `:file/sha`
string attribute"* — the file domain was always meant to exist.

---

### Three tiers: universal → domain → service

One entity carries three layers of attributes, and every rule below follows from
where an attribute is allowed to live:

```
T1  UNIVERSAL   :conn/*                                  every remote resource
T2  DOMAIN      :msg/*  :sched/*  :file/*  :person/*     what KIND of thing it is
T3  SERVICE     :gmail/*  :gcalendar/*  :gdrive/*  :graph/*   the quirks
```

**The placement test is one question, asked in order:**

| question | if yes |
|---|---|
| does **every** remote resource have it? | T1 |
| do **two unrelated providers of the same kind** have it? (Gmail ∧ Graph; Calendar ∧ CalDAV) | T2 |
| does **only one**? | T3 |
| must a query **survive a provider swap**? | it must be T1 or T2 — otherwise it is provider-coupled *by design*, and should say so |

**R1 — a one-way door.** A lower tier may *add*, never *redefine*. Two steps now.
`:msg/labels` is fine; a second `:gmail/title` means T1 is missing an attribute.

**R2 — absence is the null.** A T2 attribute is *optional by construction*: a
provider that cannot fill `:msg/in-reply-to` does not write it. datom has no NULL,
so "this provider does not expose it" and "it has no value" are the same honest
fact — and `:conn/raw` still holds whatever it *did* say.

**R3 — relations are T2, specs are T3, and `:as` is the adapter.** The load-bearing
one:

```clojure
;; T2 — msg.bl. The RELATION, and the SHAPE of its fill. No method is named.
:~msg/messages
{:arity 4
 :mirror {:entity :conn/key :cols [:conn/title :msg/from :conn/when]}
 :fill   {:on-miss :key :key :conn/key :fresh "PT5M" :max 1}
 :scan   {:page :page}}

;; T3 — connector/google/gmail.bl. The SPEC, binding a method onto that relation.
:gmail.messages.get  {:http [:get "/gmail/v1/users/{userId}/messages/{id}"]
                      :as   {:relation :~msg/messages :mode :bb}}
:gmail.messages.list {:as   {:relation :~msg/messages :mode :bf}}

;; T3 — connector/microsoft/graph.bl. A DIFFERENT provider, the SAME relation.
:graph.messages.get  {:as   {:relation :~msg/messages :mode :bb}}
```

Two things fall out, and both are the point:

- **A query never names a provider.** `[?m :~msg/messages ?subject ?from ?when]`
  returns Gmail *and* Graph messages, told apart by `:conn/service`. Swap providers
  and the query is unchanged — the last row of the placement test, satisfied
  structurally rather than by discipline.
- **The key is `:conn/key`, not `:conn/remote-id`.** Two providers' ids collide in
  a shared relation, so identity must be the composite. A `:bb` fill is then
  unambiguous **by construction**: the bound key already names the service, so the
  fill knows which provider to call, and a key from a service this connection does
  not have is a clean error rather than a guess.

**T2 must not live under `connector`** — and that is the whole reason the middle
tier exists. A message imported from a local mbox and a message synced from Gmail
must be **the same entities**, or the join between them is impossible. So the
domains are their own modules, at the level datom's own domains already occupy:

```
priv/lib/connector/schema.bl        T1 — the universal pack
priv/lib/msg.bl                     T2 — :msg/*, the :~msg/* relations
priv/lib/sched.bl                   T2 — :sched/*; interval algebra, free/busy
priv/lib/datom/file.bl              T2 — :file/*, joining its own DFile (already there)
priv/lib/person.bl                  T2 — identities, shared by all of the above
priv/lib/connector/google/gmail.bl  T3 — the spec, and its few :gmail/* quirks
```

`connector` depends on the domains it can serve; a local importer depends on `msg`
without depending on `connector` at all. `datom.file` is both the precedent and the
proof: its docstring already tells you to *"look files up by a sibling `:file/sha`
string attribute"* — the file domain was always meant to exist.

#### T1 — `connector/schema`

```clojure
(def schema
  "What EVERY mirrored remote resource has. This tier is not bookkeeping: it is the
   SHARED PROJECTION the cross-domain query reads, so it holds exactly the things
   every domain can project — and nothing that only one of them can."
  [{:db/ident :conn/service     :db/valueType :db.type/keyword :db/index true}
   {:db/ident :conn/aspect      :db/valueType :db.type/keyword :db/index true}
   {:db/ident :conn/remote-id   :db/valueType :db.type/string  :db/index true}
   ;; a remote id is unique PER SERVICE, so identity is composite. :db/tupleAttrs is
   ;; DERIVED by the writer from its components, so upserting the tuple IS the pair.
   {:db/ident :conn/key         :db/valueType :db.type/tuple
                                :db/tupleAttrs [:conn/service :conn/remote-id]
                                :db/unique :db.unique/identity}
   {:db/ident :conn/kind        :db/valueType :db.type/keyword :db/index true}
   {:db/ident :conn/title       :db/valueType :db.type/string  :db/index true}
   ;; ONE temporal extent for everything, so a cross-domain time query is one clause.
   ;; An event is a real span; a message is a one-second-resolution interval; a file
   ;; is its modified instant.
   {:db/ident :conn/when        :db/valueType :db.type/time    :db/index true}
   {:db/ident :conn/updated-at  :db/valueType :db.type/instant :db/index true}
   {:db/ident :conn/observed-at :db/valueType :db.type/instant :db/index true}
   {:db/ident :conn/content     :db/valueType :db.type/file}   ; when it IS bytes
   {:db/ident :conn/owner       :db/valueType :db.type/ref}    ; → :person/*
   {:db/ident :conn/url         :db/valueType :db.type/string}
   {:db/ident :conn/etag        :db/valueType :db.type/string}
   {:db/ident :conn/raw         :db/valueType :db.type/term}]) ; the whole response
```

`conn/title` rather than `:msg/subject` is deliberate: the universal tier is where
the shared *display* projection lives, so a message's subject, an event's summary
and a file's name are one attribute and one index. A domain adds what is *not*
shared. Where a domain carries a **second** time fact — a message's `Date` header
next to its `internalDate` — it is a domain attribute, and a law keeps them
consistent (`:msg/sent-at` must lie within `:conn/when`).

#### T2 — the domains

```clojure
;; msg.bl — a message is a message whether it came from Gmail, Graph or a maildir
;; :msg/rfc-id is the RFC Message-ID — the ONE identity Gmail, Graph and IMAP
;; all agree on, and therefore the only basis for cross-mailbox dedup. The same mail
;; in two mailboxes is two ENTITIES (two read states, two label sets) and must stay
;; that way; "show me this thread once" is a query over this attribute, not a merge.
[{:db/ident :msg/rfc-id      :db/valueType :db.type/string :db/index true}
 {:db/ident :msg/thread      :db/valueType :db.type/string}
 {:db/ident :msg/from        :db/valueType :db.type/ref}
 {:db/ident :msg/to          :db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
 {:db/ident :msg/cc          :db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
 {:db/ident :msg/in-reply-to :db/valueType :db.type/ref}
 {:db/ident :msg/labels      :db/valueType :db.type/keyword :db/cardinality :db.cardinality/many}
 {:db/ident :msg/sent-at     :db/valueType :db.type/instant}
 {:db/ident :msg/unread      :db/valueType :db.type/bool}
 {:db/ident :msg/snippet     :db/valueType :db.type/string}]

;; sched.bl — and this is where datom.time and datom.recur get cashed in
[{:db/ident :sched/all-day?     :db/valueType :db.type/bool}
 {:db/ident :sched/recurrence   :db/valueType :db.type/term}   ; a datom.recur rule
 {:db/ident :sched/recurring-of :db/valueType :db.type/ref}    ; instance → master
 {:db/ident :sched/status       :db/valueType :db.type/keyword}
 {:db/ident :sched/attendees    :db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
 {:db/ident :sched/organizer    :db/valueType :db.type/ref}
 {:db/ident :sched/location     :db/valueType :db.type/string}
 {:db/ident :sched/conference   :db/valueType :db.type/string}]

;; datom.file gains the entity-level half; the module already owns the value half
[{:db/ident :file/sha     :db/valueType :db.type/string :db/index true}
 {:db/ident :file/mime    :db/valueType :db.type/string}
 {:db/ident :file/size    :db/valueType :db.type/long}
 {:db/ident :file/parents :db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
 {:db/ident :file/trashed :db/valueType :db.type/bool}]
```

#### T3 — the quirks, and they should be *few*

```clojure
;; gmail.bl
[{:db/ident :gmail/label-ids  :db/valueType :db.type/string :db/cardinality :db.cardinality/many}
 {:db/ident :gmail/history-id :db/valueType :db.type/string}]
;; gcalendar.bl
[{:db/ident :gcalendar/extended-props :db/valueType :db.type/term}]
;; gdrive.bl
[{:db/ident :gdrive/md5          :db/valueType :db.type/string}
 {:db/ident :gdrive/app-props    :db/valueType :db.type/term}
 {:db/ident :gdrive/export-links :db/valueType :db.type/term}]
```

**An empty T3 pack is a compliment** — it means the domain model was already right,
and `:conn/raw` is holding the rest.

#### The tiers are enforced, not conventional

Two invariants, in the `datom.migrate` idiom — a `:check` where the *data* is the
judge, previewable against a production replica with `plan` and committed by
`apply!`:

1. **`:conn/kind` agrees with the domain.** Any entity carrying a `:sched/*`
   attribute has `:conn/kind :event`; any entity with `:conn/kind :event` has a
   `:conn/when`.
2. **Promotion is a migration, not a rename.** An attribute that turns out to be
   shared by two providers moves T3 → T2 as a schema delta plus a backfill, folded
   into ONE `transact!` after `plan` has shown it is safe against the real data. A
   tier is something you *earn*, through a gate — never something you assert.
---

## The tiers are enforced, not conventional

Two invariants, in the `datom.migrate` idiom — a `:check` where the *data* is the
judge, previewable against a production replica with `plan` and committed by
`apply!`:

1. **`:conn/kind` agrees with the domain.** Any entity carrying a `:sched/*`
   attribute has `:conn/kind :event`; any entity with `:conn/kind :event` has a
   `:conn/when`.
2. **Promotion is a migration, not a rename.** An attribute that turns out to be
   shared by two providers moves T3 → T2 as a schema delta plus a backfill, folded
   into ONE `transact!` after `plan` has shown it is safe against the real data. A
   tier is something you *earn*, through a gate — never something you assert.
   **If a promotion has no migration, the tier was never earned.**

The failure mode this prevents is quiet: an attribute parked in T2 that only one
provider fills buys portability you do not have, and every query that reads it looks
provider-agnostic while being anything but. The check is what makes that visible.

---

## What the tiers buy, in one query

Three services, three domains, one expression, and **not one provider named**:

```clojure
(datom/q '[:find ?kind ?what ?when
           :where [?m :~msg/messages ?subject ?_ ?when]
                  [(str-contains? ?subject "Q3 planning")]
                  [?e :~sched/events ?what ?when]
                  [?f :~file/files ?what ?when]
                  [(str-starts-with? ?what "Q3")]])
```

Point it at a Gmail + Calendar + Drive index or at a Graph + CalDAV + S3 one and
the `:where` clause is **unchanged**. That is the whole argument for the middle
tier, and it is the acceptance test: *if the join needs a line of glue **or a
provider name**, the model is wrong.*

See `an-api-is-a-relation.md` for the rest of the design — the spec, the cursor
fold, the fill, the transport, and the prototype.
