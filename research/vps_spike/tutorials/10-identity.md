# 10 — Identity: one token, minted to revoked

A single capability traverses its whole life — **mint → attenuate → authorize →
RLS → audit → revoke** — and every step is a pure function over a value you can
hold, with Ed25519 signing underneath.

## The claim

`docs/design/vps/devops.md` §*Identity, secrets, blast radius* says one
capability story carries the whole security surface: "ssh key → Biscuit token →
attenuation → capped env fork → RLS-scoped queries," and closes with the strong
sentence — "A leaked token attenuated to `{:svc "blog" :for 10m}` can do one
thing for ten minutes — and everything it did is in the audit datoms." Its
companion, `fleet.md` §*Blast radius in a fleet*, extends it across nodes: "A
compromised node can transact only what its token allows … every transact is
audited." This spike proves the load-bearing half of both claims on the real
`auth` stack: a token is **minted** carrying facts, **narrowed** by an appended
block that can only restrict, **authorized** by a pure datalog decision,
projected into **env capabilities**, used to **scope a query's rows**, every
**verdict recorded as a datom**, and finally **revoked** so it fails closed.

## The idea

A conventional permission system asks a gatekeeper at request time: the endpoint
exists, you call it, a middleware consults an ACL and returns 403. The authority
lives in a database, the decision lives in code, and the record of what happened
lives in a log — three systems, joined by hope.

Here authority is a **value you hold**. A root key mints a *Biscuit* token: a
signed, append-only chain of datalog facts and checks. Whoever holds it can
verify it offline against the root's public key — no callback to the issuer —
and can append a block, but an appended block can only add **checks** (which
fail closed), never grant a **right** the token did not already carry. So
narrowing is structural: there is no operation that widens.

```
issue      root signs facts (who, what rights)      → a token value
attenuate  bearer appends facts + checks             → only ever NARROWER
authorize  datalog: does op join a granted right?    → {:verdict :allow|:deny}
caps-for   :allow projects rights → env module caps   → fork with exactly these
RLS        one query, principal-scoped by clause injection → only their rows
audit      every verdict is a transacted datom        → the trail is queryable
revoke     id → oracle → :deny, forever               → fails closed
```

Two properties make this matter for devops. First, the **blast radius is a
value**: a leaked token is not "the credentials" — it is one written-down set of
facts, narrowed before it left the issuer. Second, **the decision is pure and
the trail is data**: `authorize` is a function of `(root-pub, token, context)`
with no I/O, so the same inputs always give the same verdict, and recording that
verdict costs one transaction into the same store that holds everything else. A
security review runs a query, not an archaeology dig.

This spike walks the entire story on real crypto, then asserts each step.

## Walkthrough

One file, read top to bottom. Each stage prints, and the last line is
`PASS`/`FAIL`.

```clojure
(ns vps.identity (:require [auth] [datom]))
```

`auth` is the facade: `(:require [auth])` and the whole surface — Biscuit
crypto, datalog authorizer, RLS, audit, revocation — is available. `datom` is
the store the audit and RLS stages use.

### Step 1 — a root authority, and a token for alice

```clojure
(def root (auth/keypair))
(def rootpub (auth/public root))

;; alice: may deploy "web", and (as a capped env) may call String only
(def alice-tok
  (auth/issue root [["user" "alice"]
                    ["right" "deploy" "web"]
                    ["right" "Elixir.String" "all"]]))
```

`auth/keypair` is a fresh Ed25519 keypair. `auth/public` pulls out the public
half. `auth/issue` mints the authority block: it encodes `facts` as datalog
predicates and signs them with the private key. The facts are ordinary tuples —
`["user" "alice"]` names the principal, and each `["right" …]` is a grant. There
is no schema, no role table: the token *is* the grant, as a signed value.

Note the two rights use the same predicate `right` with different arity of
meaning: `right("deploy","web")` is a domain grant (operation `deploy` on
resource `web`), while `right("Elixir.String","all")` is a *capability* grant
(the `String` module, op `all`). They are the same datalog shape — that is the
point; one decision engine serves both.

```clojure
(println "── issue ──")
(println "  verifies offline under root pubkey:" (auth/verify rootpub alice-tok))
(println "  principal:" (auth/principal rootpub alice-tok))
```

`auth/verify` checks the signature chain under the root public key — the
offline-verification property. `auth/principal` reads the argument of the first
`(user $p)` fact, but only *after* the signature verifies; a forged token yields
`nil`, never a fiction to scope a query by.

### Step 2 — authorize: the operation must join a granted right

The decision is datalog. The request asserts an `operation` fact; the token
carries `right` facts; a **check** must find a binding joining the two.

```clojure
(def right-check
  {:kind 0
   :queries [{:head {:name "q" :terms []}
              :body [{:name "operation" :terms [{:var 1} {:var 2}]}
                     {:name "right"     :terms [{:var 1} {:var 2}]}]
              :exprs [] :symbols []}]})
```

This is a raw Biscuit check value: `:kind 0` is "one" — the check passes if any
query matches. The single query says "there exist `?1,?2` with
`operation(?1,?2)` **and** `right(?1,?2)`". The request supplies one or more
`operation` facts; the token supplies the `right` facts; the join succeeds only
if the operation was actually granted. If it produces no binding, **the check
fails and the token is unauthorized** — checks fail closed.

```clojure
(defn decide [tok op res]
  (:verdict (auth/authorize rootpub tok
              (auth/context {:facts [["operation" op res]]
                             :checks [right-check]
                             :policies [(auth/allow [])]}))))

(println "── authorize (a pure decision) ──")
(def d-web (decide alice-tok "deploy" "web"))     ; granted
(def d-api (decide alice-tok "deploy" "api"))     ; never granted
(println "  deploy web:" d-web "   deploy api:" d-api)
```

`auth/context` assembles the request context — the `operation` fact, the check,
and a policy. `(auth/allow [])` is "allow if true" (an empty query body matches
unconditionally), so once all checks pass, the policy allows. `auth/authorize`
runs the real Biscuit decision procedure in order: **signature → revocation →
checks (all must pass) → policies (first match wins)**, and returns
`{:verdict :allow|:deny …}` with the reason when it denies.

`deploy web` joins `right("deploy","web")` → all checks pass → `:allow`.
`deploy api` has no matching `right` → the check produces no binding →
`{:verdict :deny :reason :failed-check}`. The decision is pure: identical inputs
give the identical verdict, forever.

### Step 3 — attenuate: append a block that can only narrow

```clojure
(def only-web-check
  {:kind 0
   :queries [{:head {:name "q" :terms []}
              :body [{:name "operation" :terms [{:var 1} "web"]}]
              :exprs [] :symbols []}]})
(def bot-tok (auth/attenuate alice-tok {:facts [["agent" "deploy-bot"]]
                                        :checks [only-web-check]}))
```

`auth/attenuate` **appends a block** to the token: extra facts (`agent =
deploy-bot`) and an extra check pinning the operation's second term to the
literal `"web"`. The bearer needs no secret beyond the token's own proof key,
and the issuer is never contacted.

The narrowing is structural, not a convention. Appended facts are invisible to
authority-origin queries, so an appended block cannot be *consumed* by the rules
that grant rights; appended checks, by contrast, run and can only fail closed.
There is no block content that grants a right the token did not already carry —
"attenuate" has no widen case to get wrong.

```clojure
(println "── attenuate (only narrows) ──")
(def b-web (decide bot-tok "deploy" "web"))       ; still ok
(def b-api (decide bot-tok "deploy" "api"))       ; now doubly denied
(println "  bot deploy web:" b-web "   bot deploy api:" b-api)
```

`bot deploy web` still allows — attenuation preserved the grant. `bot deploy
api` denies — and neither the original `right-check` (alice never held `deploy
api`) nor the appended `only-web-check` (operation is not `"web"`) would let it
through. The child holds no more than the parent, and less permission to use it.

### Step 4 — caps-for: the token projects to env modules

The same datalog the checks just consumed drives *environment* capabilities —
which host modules a forked env may name.

```clojure
(def caps (auth/caps-for rootpub alice-tok (auth/context {:policies [(auth/allow [])]})))
(println "── caps-for (token → env caps) ──")
(println "  granted modules:" (pr-str (:ok caps)))
```

`auth/caps-for` authorizes the token once; on `:allow` it projects the authority
block's `right($module,$op)` facts into the cap entries an `env/fork` consumes,
returning `{:ok entries}`. On `:deny` it returns `{:error verdict}` and the
caller must **not** fork.

Each entry is routed through `env/caps-entry`, whose module discipline interns
the name against **loaded modules** — a name no module owns drops out (fail
closed), so a token string can never grow the atom table. That discipline is
visible in the result: alice carries two rights, but `right("deploy","web")`
names no loaded module and drops, while `right("Elixir.String","all")` resolves
to the resolved `{Elixir.String :all}` tuple. So `:ok` holds exactly **one**
entry, and its op is `:all`. `caps-for` is the seam between *who may do what*
(the token) and *what the language will let the code say* (the env cap gate).

### Step 5 — RLS: one query, scoped per principal

The token's authority has a second enforcement point on the query side: row-level
security by **clause injection**, not post-filtering.

```clojure
(def conn (datom/connect [{:db/ident :svc/name :db/valueType :db.type/string}
                          {:db/ident :svc/owner :db/valueType :db.type/string}]))
(datom/transact! conn [{:db/id -1 :svc/name "web"  :svc/owner "alice"}
                       {:db/id -2 :svc/name "api"  :svc/owner "alice"}
                       {:db/id -3 :svc/name "billing" :svc/owner "bob"}])
(def all-svcs '[:find ?n :where [?s :svc/name ?n]])
(def alice-view (auth/guard all-svcs [(auth/owner-filter '?s :svc/owner "alice")]))
(def bob-view   (auth/guard all-svcs [(auth/owner-filter '?s :svc/owner "bob")]))
```

`datom/connect` installs a schema for service rows and `datom/transact!` writes
three: `web` and `api` owned by alice, `billing` owned by bob. `all-svcs` is the
one unguarded query. `auth/owner-filter` yields a single clause —
`[[?s :svc/owner "alice"]]` — and `auth/guard` *splices* it into the query's
`:where` (appending, so it can only ever remove rows, never add them). The app
writes one query, RLS-innocent; `auth` rewrites it per principal.

```clojure
(println "── RLS (one query, scoped per principal) ──")
(println "  raw sees:  " (pr-str (datom/q all-svcs (datom/db conn))))
(println "  alice sees:" (pr-str (datom/q alice-view (datom/db conn))))
(println "  bob sees:  " (pr-str (datom/q bob-view (datom/db conn))))
```

`datom/db` hands `datom/q` an immutable database value; the same three runs show
the raw query returning all three rows, alice's guarded query returning only her
two, and bob's only his one. Because the constraint is *in the query*, the store
never selects the forbidden rows at all — a hidden row is **absent**, not a
permission error that reveals what it cannot show.

### Step 6 — audit: the verdict is a datom

```clojure
(def audit (auth/audit-conn))
(auth/record! audit alice-tok
  (auth/authorize rootpub alice-tok
    (auth/context {:facts [["operation" "deploy" "web"]] :checks [right-check]
                   :policies [(auth/allow [])]})) {})
(def audit-rows (datom/q '[:find ?tok :where [?e :audit/token ?tok]] (datom/db audit)))
(println "── audit (verdicts are facts) ──")
(println "  audit records:" (count audit-rows))
```

`auth/audit-conn` is a datom connection with the `:audit/*` schema already
installed. `auth/record!` transacts a verdict as one entity: the token's stable
identity (hex of the authority signature), the verdict, and — when present — the
reason, the firing policy index, and the operation/resource the context named.
Recording the *same* authorize the spike has been running all along, then
querying `:audit/token` back, closes the loop: the decision left no side effect
in the decision function, but it is now a fact in the store, joinable against
everything else in it. (The real `record!` records denials too — "who was turned
away, and why" is the security review's actual query — the spike records one
allow.)

### Step 7 — revoke: the token fails closed

```clojure
(def oracle (auth/revocation-set (auth/revocation-ids alice-tok)))
(def d-revoked (:verdict (auth/authorize rootpub alice-tok
                 (auth/context {:facts [["operation" "deploy" "web"]]
                                :checks [right-check]
                                :policies [(auth/allow [])] :revocation oracle}))))
(println "── revoke ──")
(println "  same request, now revoked:" d-revoked)
```

Offline verification and revocation pull in opposite directions — revocation *is*
a callback — so `auth` makes the oracle a per-call choice: pass none (pure
offline, the token's own TTL is the whole story) or pass one. `auth/revocation-ids`
returns each block's revocation id (its signature **bytes**), and
`auth/revocation-set` builds an in-memory oracle over them.

`auth/authorize` consults the oracle *before any logic*: a revoked block turns an
otherwise-valid token into `{:verdict :deny :reason :revoked}`. The identical
request that passed in Step 2 now denies — the capability is gone, not
flagged. Because a revocation id belongs to a *block*, revoking the authority
block also revokes every attenuation derived from it (they share the block's
signature). Comparison is on raw bytes, never a re-encoded string, so no
non-canonical spelling can slip a revoked token through.

### Step 8 — the assertions and the verdict

```clojure
(def ok (and (auth/verify rootpub alice-tok)
             (= "alice" (auth/principal rootpub alice-tok))
             (= :allow d-web) (= :deny d-api)      ; authorize joins rights
             (= :allow b-web) (= :deny b-api)      ; attenuation preserved allow, kept deny
             (= 1 (count (:ok caps)))              ; caps map to env modules (a {Module op} tuple)
             (= :all (erlang/element 2 (first (:ok caps))))
             (= #{["web"] ["api"]} (set (datom/q alice-view (datom/db conn))))
             (= #{["billing"]} (set (datom/q bob-view (datom/db conn))))
             (>= (count audit-rows) 1)             ; the verdict is a fact
             (= :deny d-revoked)))                 ; revocation fails closed
(println "")
(println (str (if ok "PASS" "FAIL") " 10_identity  (one token: mint→attenuate→authz→RLS→audit→revoke)"))
```

Eleven conjuncts, one per claim in the chain: the token verifies offline and
speaks for `alice`; the granted operation allows and the ungranted one denies;
attenuation preserved the allow and kept the deny; `caps-for` produced exactly
the one resolvable env module with op `:all`; the guarded queries isolate rows
per principal; a verdict exists as a fact; and the revoked token denies. The
final line is the verdict over all of them.

## What's real vs modelled

This spike's honesty rests on the fact that **every step runs on the real
`auth` package** — only the *world around it* is trimmed.

**Real — exercised as-is:**

- `auth/keypair` / `auth/public` — a genuine Ed25519 keypair (`auth.biscuit.crypto`),
  not a stub.
- `auth/issue` — a real signed Biscuit authority block encoding the facts. The
  token is the actual wire structure.
- `auth/verify` — the real signature-chain check under the root public key, the
  offline verification the whole design leans on.
- `auth/principal` — reads the `(user $p)` fact **only after** verification
  (`auth.audit/verified-facts` returns `nil` on forgery).
- `auth/authorize` — the real authorizer implementing the Biscuit decision
  order: signature → revocation → checks (all must pass) → policies (first match
  wins). The datalog join of `operation` against `right` is a genuine join in the
  origin-scoped engine, and the `:reason` on a denial is the real cause
  (`:invalid-signature` / `:revoked` / `:failed-check` / `:no-matching-policy`).
- `auth/context` / `auth/allow` — real context assembly and a real allow policy
  value.
- `auth/attenuate` — a real appended block. The non-widening property is the
  real Biscuit origin-scoping rule, not a spike convention.
- `auth/caps-for` — the real authorize-then-project seam. It authorizes once and
  projects the authority block's `right($module,$op)` facts through
  `env/caps-entry`, whose module interning (`binary_to_existing_atom`) is the
  real atom discipline. The `{Elixir.String :all}` entry and the drop of the
  `deploy`/`web` right are true outputs of that code.
- `auth/guard` / `auth/owner-filter` — real RLS clause injection
  (`auth.rls/inject`), appending conjunctive `:where` clauses to the caller's
  query. The per-principal results are the real datom engine's.
- `auth/audit-conn` / `auth/record!` — a real datom connection with the real
  `:audit/*` schema, and a real transaction of the verdict; the readback query is
  a genuine query over recorded facts.
- `auth/revocation-set` / `auth/revocation-ids` — the real in-memory oracle over
  **signature bytes**, consulted by the real authorizer before any logic runs.
  The `:deny :reason :revoked` is the real fail-closed path.
- `datom/connect` / `transact!` / `db` / `q` — the real store, real commits,
  real immutable database values, real datalog.

**Modelled / simplified for the probe — state these plainly:**

- **The chain starts at the token, not the ssh key.** The design's story is "ssh
  key → Biscuit token → attenuation → capped env fork → RLS". This spike mints
  the token in-process from a fresh keypair; the ssh-key-establishment half of
  the chain, and the capped *env fork* itself, are proven in spikes 02 and 11,
  not here. There is no login, no password, no session — `auth/session-of`,
  `auth/hash-password`, the strategy registry, and `auth/seal` exist in the
  facade and are not exercised.
- **The request context is hand-written.** `["operation" "deploy" "web"]` and
  the strings `deploy` / `web` / `api` are illustrative; there is no HTTP
  request, no gateway, no service. The decide helper builds the context by hand
  each call.
- **The check values are raw maps, not the `auth/check` builders.**
  `right-check` and `only-web-check` are written directly as `{:kind 0 :queries
  [...]}` — precisely the shape `auth/check` / `auth/ttl-check` produce, but the
  spike never calls the builders. Consequently the design's
  `{:svc "blog" :for 10m}` **TTL is not demonstrated**: `auth/ttl-check` /
  `auth/expr-lt` exist and are unused.
- **Attenuation restates the narrowing rather than tightening a broad grant.**
  Alice's authority already pins `right("deploy","web")`, so the appended
  `only-web-check` does not remove a right she had — it re-pins what was already
  pinned. What the spike *does* prove is the structural property: an allow stays
  an allow (`b-web`) and a deny stays a deny (`b-api`), i.e. attenuation did not
  widen. A genuine "narrow a broad token" demo would mint a broader right first
  and then cut it.
- **`caps-for` stops at the projection — no fork.** The spike asserts the shape
  of `:ok` (one entry, op `:all`) but never calls `env/fork` with it, so the
  handoff into the compile gate is proven by *count and op*, not by an actual
  capped env that denies `System`/`File`. Spike 11 (and the note there) carries
  the resolved-tuple → env handoff, including the fail-safe
  over-restriction the stock `admit` path hits.
- **RLS is driven by literal principals, not by the token.** `auth/owner-filter`
  is called with the strings `"alice"` and `"bob"` directly; the token's verified
  principal is never threaded into the guard. The one-call tie-in
  (`auth/owner-scope` → `{:ok filters}` from a verified token) exists in the
  facade and is *not* used here. So the injection is real, but "one token narrows
  both the env's calls and the query's rows" is shown as two adjacent mechanisms,
  not yet as one call.
- **The audit records one allow.** `record!` writes allow *and* deny in the real
  code, but the spike records a single allow; the assertion is
  `(>= (count audit-rows) 1)`. The denial-as-audit-row story ("who was turned
  away, and why") is asserted nowhere — only described.
- **The revocation oracle is the in-memory set.** The datom-backed,
  temporally-queryable oracle (`auth/revocation-oracle`, a `fn-oracle` over a
  lookup) exists and is not used; revocation here is not queryable "as-of T".
- **No wire serialization.** `auth/encode-base64` / `decode-base64` (the `.bc`
  bytes a real Biscuit implementation would carry in a header) are never
  exercised — the token stays an in-process value throughout.

## Run it

```sh
./blx run research/vps_spike/10_identity.bl
```

Cold start costs ~10-15 s (JIT warmup); that is boot, not work. The body prints
each stage in order, then the verdict. The intermediate output looks like:

```
── issue ──
  verifies offline under root pubkey: true
  principal: alice
── authorize (a pure decision) ──
  deploy web: :allow    deploy api: :deny
── attenuate (only narrows) ──
  bot deploy web: :allow    bot deploy api: :deny
── caps-for (token → env caps) ──
  granted modules: [{Elixir.String :all}]
── RLS (one query, scoped per principal) ──
  raw sees:   [["web"] ["api"] ["billing"]]
  alice sees: [["web"] ["api"]]
  bob sees:   [["billing"]]
── audit (verdicts are facts) ──
  audit records: 1
── revoke ──
  same request, now revoked: :deny
```

and the run ends on the exact final line (two spaces before the parenthesis):

```
PASS 10_identity  (one token: mint→attenuate→authz→RLS→audit→revoke)
```

Run it from the worktree root so `blx` finds this checkout's stdlib on
`BEAM_LISP_PATH`.

## Exercises

All change only the spike file; re-run after each and predict the verdict before
you look.

1. **Mint a broader right, then actually narrow it.** Add a third right to
   alice's issuance — say `["right" "deploy" "api"]` — and predict the two
   `decide` lines and the `b-api` assertion. → `d-api` flips from `:deny` to
   `:allow` (the operation now joins), and `b-api` *stays* `:deny` because
   `only-web-check` pins the operation to `"web"`. The assertion still passes,
   but for a new reason: attenuation is now doing real work, cutting a right the
   parent genuinely held. The lesson: with the original token the narrowing was
   entangled with an already-narrow grant; this separates them.

2. **Remove the revocation oracle.** Delete `:revocation oracle` from the final
   `auth/context` and predict `d-revoked`. → It becomes `:allow`: the same token,
   same request, now passes, because with **no** oracle the authorizer takes the
   pure-offline stance and never checks revocation. The assertion
   `(= :deny d-revoked)` then fails → `FAIL`. The lesson: revocation is a
   *per-call choice*, not a property of the token — the deployment has to decide
   to consult an oracle.

3. **Scope RLS to the wrong principal.** Change bob's filter to
   `(auth/owner-filter '?s :svc/owner "alice")` and predict `bob-view`. → bob now
   sees `[["web"] ["api"]]`, so `(= #{["billing"]} …bob-view…)` fails → `FAIL`.
   The lesson: the guard is only as correct as the principal handed to it — the
   spike supplies that principal literally, and a wrong one silently shows the
   wrong rows (no error, because a hidden row is *absent*, not forbidden).

4. **Make the caps projection give up.** Change the issued capability right from
   `["right" "Elixir.String" "all"]` to `["right" "NotALoadedModule" "all"]` and
   predict `:ok` and the assertions. → `env/caps-entry` interns module names
   against *loaded* modules, so the bogus name drops out and `:ok` becomes `[]`;
   `(= 1 (count (:ok caps)))` fails → `FAIL`. The lesson: the projection fails
   **closed** — a right naming no real module yields no capability, and a token
   string can never grow the atom table.
