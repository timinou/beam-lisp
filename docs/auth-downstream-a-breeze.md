# auth downstream — making it a breeze

A design exploration of the *downstream* half of `auth`: how an app author
turns on real authentication, authorization, row-security, and SSO with a few
**shape declarations** — and why that surface must be co-designed with the
`shape <-> json <-> struct` system already taking form in this repo, not
bolted on afterward.

Companion to `auth-the-application-authorizes-itself.md` (the foundational
Biscuit + datom engine) and PLAN-041 (its build order). This document is
design-only: it argues the end-user syntax and the seams it rests on. Nothing
here is built. The point is to fix the *surface* before the foundation
hardens under it, because the surface is the part that cannot be changed later
without breaking every app that adopted it.

---

## 0. The trap to avoid: a fourth shape language

This repo already has **three** ways to declare the shape of data, and they
overlap:

| system | where | surface | purpose |
|---|---|---|---|
| datom schema | `priv/datom/schema.bl` | `{:db/ident :user/email :db/valueType :db.type/string :db/unique :db.unique/identity}` | how a fact is **stored, indexed, unique** |
| defcontract | `spell/src/spell/contract.bl` (PLAN-021) | `(assign @count :integer 0)` · `(push @flash {:message :string :kind :atom})` | the **seam** shape crossing server/client |
| defrecord | `examples/records.bl` | `(defrecord Point [x y])` | a **struct**-shaped value |

If `auth` invents a *fourth* shape language for "a user resource," it has
failed before it starts. The whole beam-lisp thesis is *one need, one
implementation*. An app author declaring a `User` should write the shape
**once** and have storage schema, auth facts, JSON encoding, and a struct
projection all fall out of that single declaration.

So the first design commitment is negative: **`auth` adds no shape vocabulary.**
It reuses the type tokens the contract system already uses (`:string`,
`:integer`, `:boolean`, `:keyword`, `:atom`, `:list`, `:map`, plus datom's
`:ref`/`:instant`) and the datom uniqueness/cardinality vocabulary. What
`auth` adds is *meaning attached to fields* — "this field is the identity,"
"this field is sensitive," "this relationship grants ownership" — as data on
the same shape.

---

## 1. The unifying idea: a resource is a shape with a policy

Ash's central object is a *resource*: a struct + a data layer + actions +
policies, assembled by a DSL macro. The beam-lisp inversion: a **resource is a
shape (data) carrying a policy (data)**. One value, introspectable, printable,
storable, generatable — never a macro expansion you recover through an `Info`
module.

```clojure
(defresource User
  {:store :datom}                         ; where facts live
  (field :email    :string :unique :identity)  ; datom :db/unique falls out
  (field :name     :string)
  (field :role     :keyword)
  (field :pw-hash  :string :sensitive)    ; :sensitive => never in json, never a fact
  (field :org      :ref    :to Org)       ; a relationship, datom :db.type/ref
  (timestamps))                           ; :created-at :updated-at :instant
```

From this **one** declaration, `auth` (with the shape system) derives:

- **datom schema** — `:user/email` is `:db.type/string`, `:db.unique/identity`;
  `:user/org` is `:db.type/ref`; etc. No second schema written by hand.
- **a struct projection** — `(->User {…})` / field accessors, the `defrecord`
  surface, so host code and tests hold a `User` value.
- **json codec** — `(json/encode user)` omits `:sensitive` fields by
  construction; `(json/decode User bytes)` validates against the shape and
  reads names as tagged binaries (atom-safe, per trust-boundary).
- **auth facts** — the identity field seeds `(user <email>)`; a `:ref` marked
  `:owner` seeds ownership facts; role fields seed `(role <id> <role>)`. These
  are the *authority facts* a token carries (foundational doc §9.1).

This is the load-bearing claim: **the shape the database stores, the struct
the code holds, the JSON the wire carries, and the facts the authorizer reads
are all projections of one declared value.** That is `the-application-is-a-value`
applied to a resource. The `shape <-> json <-> struct` work is not adjacent to
`auth` — it *is* the substrate `auth`'s ergonomics stand on.

### Why co-design is non-negotiable

If the shape system ships first with only json/struct in mind, its field
metadata will have no room for `:sensitive`, `:identity`, `:owner`,
`:to`. Retrofitting auth-meaning onto a frozen field grammar means either a
parallel annotation channel (the fourth language we just forbade) or a
breaking change to every shape. ∴ the field-metadata grammar must be designed
with auth's needs present from the start — even if auth's *implementation*
lands later. This document exists to put those needs on the table now.

---

## 2. Turning auth on: `defauth`

A resource declares *shape + field meaning*. A separate, small declaration
turns on *authentication strategies* and *token policy* — the Ash
`authentication do` block, as data:

```clojure
(defauth MyApp
  {:resource User
   :root     (env :AUTH_ROOT_KEY)}        ; the Biscuit root secret

  (strategy :password
    {:identity :email :password-hash :pw-hash})

  (strategy :magic-link
    {:identity :email :sender MyApp.email/send-magic})

  (strategy :api-key
    {:prefix "myapp" :hash :key-hash})

  (strategy :github                        ; claims -> capability; req_llm did the dance
    {:claims->facts (fn [c] [`[(user ~(:sub c))] `[(email ~(:email c))]])})

  (tokens
    {:ttl (minutes 30) :revocation :datom}))  ; offline TTL + online oracle both on
```

Every `strategy` is the same shape: a name + a config map, resolving to a
**function** `params -> authority-facts` (foundational doc §9.6). `:password`
and `:api-key` have built-in resolvers keyed off the resource's field meaning
(it already knows which field is `:identity`, which is the hash). `:github`
supplies its own `claims->facts` because the provider dance is out of scope
(`req_llm` owns it) — `auth` starts at verified claims.

The output of `defauth` is, again, **a value**: a map you can print, diff in
review, or store. `AshAuthentication.Info.strategy!/2` becomes `(get-in myapp
[:strategies :password])`.

---

## 3. Policies at three grains, all data

Ash distinguishes resource policies (row filters), field policies (column
hiding), and action policies. In `auth` these are one mechanism — datalog data
— at three scopes on the resource shape:

```clojure
(defpolicy User
  {:order :deny-overrides}

  ;; ROW scope: which User rows may the bearer see? (RLS)
  (rows
    (allow if (owner $user $row))                 ; your own
    (allow if (role $user :admin)))               ; admins see all

  ;; FIELD scope: which fields, once a row is visible?
  (fields
    (deny :pw-hash always)                        ; nobody, ever (also :sensitive)
    (allow :email if (or (owner $user $row)
                         (role $user :admin))))   ; email only to self/admin

  ;; ACTION scope: which operations?
  (actions
    (allow :read   if (member $user))
    (allow :update if (owner $user $row))
    (deny  :delete if (not (role $user :admin)))))
```

- **rows** -> RLS clause injection (`rls.bl`, foundational §9.5): the residual
  becomes `:where` clauses spliced into the caller's query. Forbidden rows are
  *absent*, never an error (enumeration-safe).
- **fields** -> the json codec consults the decision per field; a denied field
  is omitted exactly as a `:sensitive` one is. This is where the `shape <->
  json` seam and the policy engine meet: **the encoder is policy-aware**.
- **actions** -> the `:verdict` half of `authorize` (foundational §6).

All three are the *same* datalog the token's `check if …` speaks. One engine,
three scopes. `:deny-overrides` vs `:allow-overrides` is the app's call,
declared, not baked in.

---

## 4. The shape<->json<->struct seam, made policy-aware

This is the crux of the co-design, and the part most easily gotten wrong.

A field declaration must carry enough metadata that **one encoder** can serve
storage, wire, and struct while honoring policy:

```clojure
(field :email :string
  :unique   :identity     ; -> datom :db/unique, -> auth (user <email>) fact
  :json     "email"       ; wire key (default: kebab of field name)
  :sensitive false)       ; -> may appear in json subject to field policy
```

The metadata keys fall into three buckets, and the grammar must reserve room
for all three from day one:

| bucket | keys | consumer |
|---|---|---|
| **storage** | `:unique`, `:cardinality`, `:index`, `:to` | datom schema |
| **wire** | `:json`, `:sensitive`, `:optional`, `:default` | json codec |
| **auth** | `:identity`, `:owner`, `:role`, `:sensitive` | facts + policy |

`:sensitive` sits in two buckets deliberately — it is the one place wire and
auth *must* agree, and having it be one key (not two that can drift) is the
whole point. A `:sensitive` field is never encoded and never becomes a fact,
regardless of policy; policy can only *further* restrict a non-sensitive field.
That ordering (sensitive is absolute, policy is additive-restriction) is the
field-level echo of attenuation's monotonic weakening.

**Design decision to make in the shape system, now:** field metadata is an
*open map*, not a fixed positional grammar. `(field :email :string :unique
:identity)` is sugar; the canonical form is `(field :email :string {:unique
:identity :json "email"})`. Openness is what lets `auth` add `:owner`/`:role`
without a shape-grammar version bump — the same reason datom schema is a map of
`:db/*` keys rather than positional args. If the shape system freezes fields as
positional, auth's meaning has nowhere to live.

---

## 5. SAML / SSO — simple config over the same sink

`auth` is the **sink** for federated identity: it turns verified claims into a
capability. It is not a SAML transport (that is a protocol library's job, like
`req_llm` for OAuth). So SSO config is small — it names the trust and maps
claims to facts:

```clojure
(defsso MyApp
  (provider :okta
    {:kind     :saml
     :metadata (env :OKTA_METADATA_URL)      ; IdP trust anchor
     :attrs    {:sub "nameID"                ; SAML attr -> our fact field
                :email "email"
                :groups "memberOf"}
     :claims->facts
       (fn [c]
         (into [`[(user ~(:sub c))] `[(email ~(:email c))]]
               (map (fn [g] `[(group ~(:sub c) ~g)]) (:groups c))))})

  (provider :entra
    {:kind :oidc
     :discovery (env :ENTRA_DISCOVERY_URL)
     :attrs {:sub "sub" :email "email" :roles "roles"}}))
```

The pattern is identical across SAML, OIDC, and social OAuth: **a provider is a
trust anchor + an attribute map + a `claims->facts` function.** The transport
differences (SAML POST binding, OIDC discovery, OAuth code exchange) live in
the transport library; `auth` sees only the verified claim map. So "add
Okta SSO" is one `provider` form, and the groups Okta asserts become `(group
<user> <g>)` facts that `defpolicy` can read directly:

```clojure
(rows (allow if (group $user "engineering")))   ; Okta group -> row access, no glue
```

That is the payoff of the whole design: an enterprise SSO group and a
hand-written ACL rule meet in the *same fact space*, because everything —
storage, tokens, SSO claims, policies — was reduced to datalog facts about who
is asking.

---

## 6. The whole downstream app, one screen

```clojure
(ns my.app (:require [auth] [datom] [json]))

;; 1. shape + meaning, declared once
(defresource User
  {:store :datom}
  (field :email :string :unique :identity)
  (field :name  :string)
  (field :role  :keyword)
  (field :pw-hash :string :sensitive)
  (field :org   :ref :to Org :owner)
  (timestamps))

;; 2. turn auth on
(defauth MyApp
  {:resource User :root (env :AUTH_ROOT_KEY)}
  (strategy :password {:identity :email :password-hash :pw-hash})
  (strategy :github   {:claims->facts github/claims})
  (tokens {:ttl (minutes 30) :revocation :datom}))

;; 3. SSO, if you need it
(defsso MyApp
  (provider :okta {:kind :saml :metadata (env :OKTA_METADATA) :attrs {…}}))

;; 4. policy, three grains, one language
(defpolicy User
  {:order :deny-overrides}
  (rows   (allow if (owner $user $row))
          (allow if (role $user :admin)))
  (fields (allow :email if (owner $user $row)))
  (actions (allow :read if (member $user))))

;; 5. that is it. handlers get filtered views for free:
(defn handle [token req]
  (let [db (datom/db conn)]
    (-> (auth/guarded-q MyApp token (:query req) db req)   ; RLS applied
        (json/encode-with-policy MyApp token db))))         ; field policy applied
```

Five declarations, all values. Compare Ash: a resource module, an
`attributes do` block, an `identities do` block, an `authentication do` block,
a `policies do` block, a `field_policies do` block, generated actions, a
`UserIdentity` resource for OAuth, an `Info` module to introspect it all, and a
Postgres data layer to make filters real. `auth` collapses those into *shape +
meaning + policy*, because they were always the same thing said five times.

---

## 7. What must be true in the shape system for this to work

These are requirements this document places on the `shape <-> json <-> struct`
work, so they are designed in rather than retrofitted:

1. **Field metadata is an open map**, not positional args (§4). Auth meaning
   (`:identity`, `:owner`, `:role`, `:sensitive`) must attach without a grammar
   version bump.
2. **`:sensitive` is a first-class field key** understood by the json encoder
   as "never encode," independent of any policy layer. Absolute, not additive.
3. **The json codec is derivable-and-overridable per field** (`:json "wire-key"`),
   and — crucially — **can be made policy-aware**: an encoder that takes an
   optional `(policy, token, db)` and omits fields a field-policy denies (§3).
4. **Type tokens are shared** with the contract system (`:string :integer
   :boolean :keyword :atom :list :map`) plus datom's `:ref :instant`. One
   vocabulary, not two.
5. **A resource shape projects to a datom schema** without a hand-written second
   copy — the `:unique`/`:cardinality`/`:to`/`:index` field keys map onto
   `:db/*`.
6. **Decode reads names as tagged binaries** (trust-boundary), interning at
   bounded sites only — because a resource decoded from untrusted JSON is the
   same atom-exhaustion hazard a token is.

If the shape system honors these six, `auth`'s downstream surface is a thin
derivation over it. If it does not, `auth` is forced to fork the shape system,
and the "one need, one implementation" thesis breaks at exactly the seam that
matters most.

---

## 8. Open questions (for the co-design conversation)

- **`defresource` vs `defcontract` relationship.** A contract (PLAN-021)
  declares a server/client seam; a resource declares a stored entity. Do they
  share a `field`/`assign` core, with `defresource` adding storage+auth meaning
  and `defcontract` adding seam meaning? Likely yes — that would make the shape
  system the shared root both grow from. Worth settling before either freezes.
- **Where does the json codec live?** It is needed by the shape system
  (struct<->json), by `auth` (policy-aware encode), and by any wire boundary.
  It should be its own small stdlib package (`json`?) that the shape system and
  `auth` both consume — not owned by either.
- **Field policy vs sensitive overlap.** §4 says `:sensitive` is absolute and
  policy is additive-restriction. Confirm no use case needs a `:sensitive`
  field revealed by policy (if one does, `:sensitive` becomes a policy default,
  not an absolute — a meaningfully different design).
- **Does `defpolicy` attach to the resource or stand alone?** Ash attaches
  policies to the resource module. Keeping `defpolicy` a separate value (that
  *names* its resource) preserves "policy is data you can generate," but means
  a resource and its policy can drift. Tradeoff to weigh.
- **Multi-resource tokens.** A capability may span resources (a `User` and the
  `Org` they own). The fact space is shared, so this works in principle — but
  the `defauth {:resource User}` single-resource framing needs to generalize to
  a set. Design the plural from the start.

The through-line: `auth`'s downstream ease is *entirely* a function of whether
the shape system carries auth's meaning natively. Get the field-metadata
grammar right — open, shared type tokens, `:sensitive` first-class,
policy-aware encoding — and turning on real ACL + RLS + IAM + SSO is five
declarations of data. That is the target, and it is why this surface must be
designed alongside the shape work, not after it.
