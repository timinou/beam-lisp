# Accounts and credentials

Two questions decide most of the design here: **who is this row from?** and **where
does the right to read it come from?** They look like one question and they are not
— the first is about identity in the database, the second is about proof held
outside it. Keeping them apart is what lets one query span three mailboxes without
letting one mailbox's token reach another's data.

Read `three-tiers.md` first: the tiers decide *where* the account attributes live.

---

## 1 · An account is part of the identity, not an attribute on it

A remote id is unique **per service per account** — not per service. `"18c…"` is a
Gmail message id; the same string in the work mailbox is a different message. So the
account belongs in the identity tuple next to the service.

**And the account's identifier must be the provider's IMMUTABLE SUBJECT, never the
address.** A Workspace admin renaming `alice@corp.com` to `alice@newcorp.com` changes
every address-derived key at once, so the entire mirror misses and re-syncs into a
second copy of every entity — the old rows orphaned, the new rows duplicated. Google's
OIDC `sub` claim is the right value: *"an identifier for the user, unique among all
Google accounts and never reused."* The address is a **label** and moves
independently:

```clojure
;; :conn/account-id is the SUBJECT (immutable), not the address (a label)
{:db/ident :conn/account-id :db/valueType :db.type/string :db/index true}
{:db/ident :conn/key        :db/valueType :db.type/tuple
                            :db/tupleAttrs [:conn/service :conn/account-id :conn/remote-id]
                            :db/unique :db.unique/identity}
```

Get this wrong — key on service and remote-id alone — and the second account's copy
of a shared message **upserts onto the first**, silently merging two mailboxes. That
is the whole reason the account is in the tuple rather than beside it.

An account is then its own entity, with its own composite identity:

```clojure
{:db/ident :conn/account-key :db/valueType :db.type/tuple
                             :db/tupleAttrs [:conn/service :conn/account-id]
                             :db/unique :db.unique/identity}

;; the account entity — where the things that belong to a CONNECTION live
{:conn/account-key [:gmail "117…"]         ; ← the SUBJECT. Immutable, never reused.
 :account/label    "me@work.com"          ; ← the address. A label, and it MOVES.
 :conn/scopes      #{:gmail.readonly}     ; what the grant currently holds (§3)
 :conn/granted-at  #inst "…"
 :conn/expires-at  #inst "…"              ; a Testing-status grant: +7 days (§5)
 :conn/principal   #{"alice"}             ; CARDINALITY MANY — a shared team mailbox
                                          ; is authorized by more than one principal
 :conn/person      → :person/*}           ; the human behind it, when it is one

;; the cursor — per (account, aspect), so "where am I" is a query, not a file
{:conn/cursor-of    :~msg/messages
 :conn/cursor       "12345"
 :conn/committed-at #inst "…"}
```

**No ref is needed on the resource.** The composite key *is* the join:

```clojure
(defn account [db service account-id]
  (d/entity db [:conn/account-key [service account-id]]))
```

That is the same trick the resource key uses, applied one level up, and it keeps the
resource free of a back-pointer that would only ever be dereferenced once.

---

## 2 · Multi-account at the query level

Nothing new is needed, because `datom` already has both shapes this wants: a plain
variable, and a collection binding. `[?x ...]` *"takes MANY values — this is how you
write `IN (...)`"*.

```clojure
;; 1 · EVERY account. The default, and it costs nothing to write.
(d/q '[:find ?acct ?subject
       :where [?m :conn/account-id ?acct]
              [?m :~msg/messages ?subject ?_ ?_]] db)

;; 2 · ONE account — an ordinary bound value.
(d/q '[:find ?subject :in $ ?acct
       :where [?m :conn/account-id ?acct]
              [?m :~msg/messages ?subject ?_ ?_]] db "me@work.com")

;; 3 · A SET of accounts.
(d/q '[:find ?acct ?subject :in $ [?acct ...]
       :where [?m :conn/account-id ?acct]
              [?m :~msg/messages ?subject ?_ ?_]] db ["me@work.com" "me@home.net"])

;; 4 · The account ENTITY, when you want its cursor, scopes or person.
(:conn/scopes (account db :gmail sub))

;; 5 · Across accounts, by PERSON — when identity resolution earns its keep.
(d/q '[:find ?acct ?subject
       :where [?a :conn/person ?p] [?a :conn/account-id ?acct]
              [?m :conn/account-id ?acct] [?m :~msg/messages ?subject ?_ ?_]] db)
```

Three properties make this safe rather than merely possible:

- **A fill is account-scoped by construction.** Stored rows are visible to every
  query — one mirror, one index, which is the point. But a *fill* only ever calls
  the credential of the connection doing the fetching, because the credential is
  resolved from the **connection**, never from the query. So connection A cannot
  cause a request on connection B's token. There is no cross-account leakage path
  to get wrong.
- **`:bb` fills stay unambiguous.** `:conn/key` now names the account as well as
  the service, so a fully-bound key identifies a credential. A query that binds the
  id but *not* the account is a partial bind: it is answered from the mirror, and
  **does not fill** — because the provider would be ambiguous, and §3's rule is that
  an ambiguous fill is never guessed at.
- **`:conn/account-id` is not a secret.** It is the mailbox address, and it indexes
  like any other string. What is secret is the *grant*, and the grant is not in the
  mirror at all — it is behind the store port (§4).

### Does `auth` scope these automatically? Yes — and the connector owes it three things

`auth.rls` answers "which rows may they see?" by **clause injection**: the app writes
one query, innocent of who is asking, and `auth` rewrites its `:where` for this
principal before it runs. What makes it safe is monotonicity — *"adding a
conjunctive `:where` clause can only REMOVE rows from the answer, never add any"* —
and why it is injection rather than post-filtering is that a dropped-after-the-fact
row still leaks **work** and **existence**.

```clojure
(def all-mail '[:find ?subject :where [?m :~msg/messages ?subject ?_ ?_]])
(def mine     (auth/guard all-mail (account-filter '?m principal)))
```

So the answer is yes. But three things are the connector's to supply, and the third
corrects an earlier claim in this document.

**1 · A membership filter — because accounts are many.** `attribute-filter` binds ONE
constant (`[?row :row/tenant "acme"]`). Two accounts as two clauses would **AND**,
and against a cardinality-one attribute that is unsatisfiable:
`[?m :conn/account-id "a"] [?m :conn/account-id "b"]` matches nothing. The fix needs
no engine change — `inject` takes any clause vector, and `rls`'s own docstring names
*membership* as the generalisation (*"richer filters (membership, role, hierarchy) are
just more clauses"*):

```clojure
(defn account-filter
  "Clauses scoping `row-var` to the accounts `principal` may read. MEMBERSHIP, not
   equality — so it scales to N accounts with ONE join and no clause enumeration."
  [row-var principal]
  [['?a :conn/principal principal]     ; the accounts this principal holds
   ['?a :conn/account-id '?acct]
   [row-var :conn/account-id '?acct]])
```

**2 · Hygienic variables.** A filter that binds `?acct` will silently **join** to the
caller's `?acct` if the caller happened to write one. It can never widen the answer —
monotonicity holds — but it can *narrow the caller's own query*, which is a confusing
bug rather than a breach. So the filter builder parses the query, collects its
variables, and chooses names it does not use. Mechanical, and testable, which is the
point.

**3 · A fill is not scoped by RLS at all.** This is the correction. `auth.rls` injects
`:where` clauses; a fill is an **action**, and an injected clause cannot stop an
action — it can only remove rows that already exist. So:

> **RLS gates what you READ. An authorization check gates what you DO.**

`conn/ensure` therefore performs its own check, against the **env's principal** — the
`auth/sandbox-fork` doctrine, *"one token narrows both the env's calls and the query's
rows"* — rather than against the query text. The account is in the key, so the check
is unambiguous: `(auth/require! c :read (env/principal))`.

What the earlier claim got right and what it missed:

- **Right:** there is no *cross-connection* leakage. A fill resolves its credential
  from the **connection**, never from the query, so connection A can never cause a
  request on connection B's token.
- **Missed:** connection A's token can still be used *on behalf of* a principal who
  should not have it. Row filtering cannot prevent that, because **the row does not
  exist yet** — the fill is what creates it.

`conn/keep` is per-connection, so keeping is per-account; both connections write
into the same database and the composite key keeps them apart:

```clojure
(conn/keep work     :messages {:into db})
(conn/keep personal :messages {:into db})   ; same db, no collision, one query
```

---

## 3 · "Credentials" is two things, and they have different owners

### The client — the app's identity to the provider

One per deployment. This is what starts any flow, and it is **deployment config, not
data** — so it belongs in `data.config` / the environment, never in datom.

```clojure
;; THIS DEPLOYMENT (verified 2026-09-22) — a WEB application client.
;;
;; The redirect URI is PATH-BEARING, which is what settles the type: an
;; installed-app client cannot register a path, so this is a Web client and its
;; secret IS a real secret. (Google's "obviously not treated as a secret" remark
;; applies to installed apps only, and it does not apply here.)
;;
;; It is also the BETTER prototype shape than the installed-app one, because the
;; registered URI is already a loopback address — the security of loopback with a
;; Web client's config — so the redirect mechanism is exercised from day one and
;; FUP-120 shrinks to multi-session binding.
{:client-id     "…apps.googleusercontent.com"
 :client-secret (secret :env)                ; REAL. :sensitive from day one.
 :redirect      "http://localhost:8000/api/calendar/public/v1/callback"
 :flows         #{:code-pkce}}               ; PKCE is still right, and still used
```

;; INDUSTRIAL — a web application client. Now there IS a secret, and it is
;; :sensitive: never printed, never logged, never a datom.
{:client-id "5678.apps.googleusercontent.com"
 :client-secret (secret "GOOGLE_CLIENT_SECRET")   ; resolved from the deployment
 :redirect  "https://app.example.com/oauth/callback"
 :flows     #{:code-pkce}}
```

**What was actually verified, without a browser.** Four checks, each one
non-interactive, and together they prove the whole path except the human click:

| check | how | result |
|---|---|---|
| `client_id` + redirect are a valid pair | GET the auth URL with `prompt=none` | **302 back to OUR URI** with `interaction_required` — a mismatch would have said `redirect_uri_mismatch` |
| PKCE S256 is implemented correctly | RFC 7636 Appendix B vector | reproduced exactly (`test/bl/credential/oauth2_test.bl`) |
| **the secret authenticates** | POST the token endpoint with a bogus code | `invalid_grant: "Malformed auth code."` — a bad secret answers `invalid_client` instead |
| nothing else holds the port | listen check | `:8000` free |

The third is the one worth keeping: it is an end-to-end proof of the token exchange
that needs no consent, because the difference between "credentials are wrong" and
"code is wrong" is exactly the difference between `invalid_client` and `invalid_grant`.

**A note on the redirect path itself.** `/api/calendar/public/v1/callback` names a
*calendar public API v1* that is not this connector. Reusing a registered URI is
correct — an unregistered one cannot work — but the name couples the prototype to a
namespace that means something else. Worth a second client when the connector has a
name of its own.

### The grant — the user's or the tenant's proof

Per account, and this is the credential the rest of the design talks about:

```clojure
{:scheme     :oauth2
 :client-id  "1234.apps.googleusercontent.com"   ; a refresh token is BOUND to the
                                                 ; client that minted it — carry it
 :material   {:refresh "1//0g…" :access "ya29…"}  ; ≤512 and ≤2048 bytes (Google's
                                                 ; documented token size limits)
 :account-id "me@work.com"
 :scopes     #{:gmail.readonly}
 :expires-at #inst "…"
 :subject    nil}                                ; domain-wide delegation only
```

`:client-id` on the credential is not decoration. A refresh token is only valid
against the client that issued it, so a credential that cannot name its client
cannot be refreshed — and a deployment that rotates client ids needs the grant to
say which one it belongs to.

**Scopes are incremental.** Google's guidance is to *"request scopes incrementally,
at the time access is required, rather than up front"*. So a credential's `:scopes`
is a set that **grows**, and the account entity records what it currently holds. An
app that asks for Drive later re-consents for Drive and keeps its existing grant.

---

## 4 · The store is a port, and the connector never picks a tier

A grant has to live somewhere, and somewhere is a deployment decision — exactly the
shape of `datom.blob`. So the store is a protocol, and the connector asks it:

```clojure
(defprotocol Store
  (-get    [s service account-id])   ; → a credential, or nil
  (-put    [s service account-id c])
  (-delete [s service account-id])
  (-list   [s]))                     ; → [[service account-id] …]
```

Four implementations cover the whole space:

| store | for | note |
|---|---|---|
| `store-file` | the prototype, a personal install | `0600`, one file per account |
| `store-env` | CI, a container | read-only; a grant cannot be written back |
| `store-datom` | multi-tenant | **a refresh token in datom is plaintext unless the substrate encrypts it** — right where the store is encrypted at rest, wrong otherwise, and the port is what lets the deployment answer rather than the connector |
| `store-command` | a real secret manager | shells out to `op`/`vault`/`aws secretsmanager` |

**The connector must not choose.** `datom.blob` settled this: *"A store for which
local bytes would be WRONG … extends `DefaultBlobs` and throws from it, naming the
tier it needs. The refusal belongs to the store that knows; this function does not
guess."* The same discipline applies verbatim — a store for which plaintext is wrong
**refuses by name** rather than quietly storing a refresh token in the clear. The
config surface then carries no `:store` choice beyond naming which store you built,
which is how the connection config in `an-api-is-a-relation.md` §6 already reads.

---

## 5 · Sign-in belongs to `auth`; the connector only borrows it

The connector must not grow a session concept. `auth` already has one —
`auth/session-of` *"resolve[s] a verified session from a wire token"*, and login
carries a nonce/challenge. So the flow **carries** a session; it does not create
one. The join is OAuth's own `state` parameter:

```clojure
;; 1 · the app has a session already (auth). The flow binds to it, and stores the
;;     PKCE verifier WITH the state — never in the redirect, where it would be a
;;     verifier in plain sight.
(cred/authorize-url work {:state (auth/state-for session)})
;; → "https://accounts.google.com/o/oauth2/v2/auth?…&code_challenge=…&state=…"

;; 2 · the callback comes back to OUR route, not the connector's. `state` is verified
;;     against the store, so the grant lands on the right account.
(cred/complete! work {:code "4/0A…" :state (:state params)})

;; 3 · a NEW session was never minted. The grant was attached to the existing one.
```

That division is what keeps the two stances honest: a prototype has one session and
loops back to `127.0.0.1`; a SaaS has many sessions and redirects to its own domain.
The connector's half is identical in both.

---

## 6 · A credential is assumed mortal

This is not defensive programming. Google documents six distinct ways a refresh
token dies, and one of them will bite a prototype within a week:

| cause | consequence |
|---|---|
| **OAuth consent screen in "Testing" status, external user type, sensitive scopes** | the refresh token **expires in 7 days**. Google's exception is a grant whose only scopes are `userinfo.email` / `userinfo.profile` / `openid` — i.e. no Gmail, Calendar or Drive access at all |
| unused for six months | revoked |
| the user changed their password | revoked for grants holding **Gmail** scopes |
| **100 refresh tokens per Google Account per client id** | *"creating a new refresh token automatically invalidates the oldest refresh token without warning"* |
| an admin restricts a requested service | `invalid_grant`, `admin_policy_enforced` |
| GCP session control | `invalid_grant`, subtype `invalid_rapt` |

Two laws follow, and both are load-bearing:

1. **`invalid_grant` is NOT retryable.** It maps to `:reauth` — surface a consent
   URL — and never to the backoff ladder. An `invalid_grant` will not become valid
   by waiting, and a retry loop on it burns quota forever while looking busy.
2. **`authorize!` is idempotent.** It reuses an existing valid grant and mints a new
   refresh token **only when there is none**. The 100-token limit silently evicts
   the oldest, so a flow that re-runs on every start will, on the hundredth run,
   quietly log the developer out of their *other* tools — with no error anywhere.

The second is easy to miss and expensive to discover, which is why it is a law here
and not a footnote. And note what this says about the design generally: the 7-day
expiry is not a bug to work around, it is the *normal* condition, and the correct
behaviour is a clean re-consent prompt — which is why the taxonomy in
`an-api-is-a-relation.md` §1 already has `:authError/invalid_grant → :refresh-credential`
as a first-class disposition.

### The three ways out of the 7-day clock, in prototype order

1. **Accept it.** Re-consent weekly. Zero setup, and the failure is a prompt, not a
   crash — provided law 1 holds.
2. **Use an Internal user type.** A Workspace account's consent screen can be
   *Internal*, which is not subject to the Testing-status limit and needs no
   verification. This is the right prototype choice for anyone with a Workspace
   domain.
3. **Use a service account with domain-wide delegation.** No user consent, no
   refresh token, no 7-day clock at all — `:subject` in the credential carries the
   impersonation instead. This is the industrial stance, and it is also the fastest
   prototype *if* you have Workspace admin rights (see `FUP-117`).

---

## 7 · What the prototype builds

Small on purpose, and clean on purpose — the parts not built are stances, not
omissions:

```
priv/lib/credential/oauth2.bl   flow-code-pkce: the loopback flow, as a state
                                machine (start → redirect → exchange), with the
                                verifier and the state stored together
priv/lib/credential/store.bl    the Store protocol + store-file (0600)
priv/lib/credential.bl          the credential value, refresh at a 5-minute skew,
                                ONE refresh in flight per credential, authorize!
                                idempotent (§6 law 2)

(conn/open gmail/spec
  {:store (store-fjall/open {:path "~/.local/share/index"})
   :auth  {:client {:client-id "1234.apps.googleusercontent.com"
                    :redirect  "http://127.0.0.1:0/callback"
                    :flows     #{:code-pkce}}
           :store  (cred/store-file "~/.config/index")}})

(cred/authorize! c)     ; prints the consent URL, waits on the loopback redirect,
                        ; writes the grant, and does NOT mint a second one next time
```

Not built, and deliberately: the web redirect stance, the device flow, and
`store-datom` under `auth` RLS. Two of those are one flow each — the third needs the
policy question answered first, which is `FUP-117`'s job.
