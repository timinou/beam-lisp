# The web-redirect OAuth flow — contract for app cutover

`priv/lib/credential/flow.bl` now carries two ways to run the same
authorization-code + PKCE dance:

| | who answers the callback | halves joined by |
|---|---|---|
| `begin!` / `finish!` | the dev **loopback** listener (RFC 8252) | a live process (`:lsock`) |
| `begin-web` / `finish-web!` | the app's **public redirect route** | a one-time, expiring `state` in a `credential.pending/Pending` store |

Both halves of both flows meet in `exchange-code`, so everything after the
exchange — `oauth/decode-token`, `oauth/decode-error`, `oauth/classify`,
`oauth/redact` — is shared. An app that swaps halves swaps nothing downstream.
The loopback path is unchanged and stays the dev default.

This is the production half of **P6** in
`docs/research/veritas-sync-investigation.md` ("credential web flow + sealed
store"). The grant store (`credential.store`) is a separate concern and is not
touched here.

## 1 · The two halves

### `credential.flow/begin-web cfg pending` → `{:ok …} | {:error …}`

Mints one attempt, keeps it in `pending`, and returns the consent URL. **It
makes no network call** — the whole reason to split the flow is that the URL can
be built and asserted offline.

```
cfg (all required unless marked):
  :client-id     the OAuth client id
  :client-secret the client secret        (held for the exchange, never stored)
  :redirect      the EXACT registered callback URI (absolute, with ://)
  :scopes        a vector of scope URIs
  :firm          the firm the attempt belongs to (session context)
  :principal     the principal the attempt belongs to (session context)
  :ttl-ms        optional; how long the attempt lives (default 600000)
  :login-hint    optional; passed through to the consent URL
  :prompt        optional; :consent (default) | :none | a string

pending:
  a credential.pending/Pending store (see §4)
```

```
{:ok {:url u :state s :expires-at ms :redirect u :firm f :principal p}}
{:error :missing-config :keys [k …]}   ; the missing keys, by name
{:error :invalid-redirect :redirect u} ; not an absolute URI
```

The `state` is minted here (`credential.oauth2/state`, 256 bits, base64url) and
is **never accepted from the caller**. The PKCE `verifier` is **not returned**:
it waits in the pending record and is read back at `finish-web!`. A verifier the
app holds is a verifier the app can copy into a log; the loopback flow can keep
it in a local map only because the same process serves both halves.

### `credential.flow/finish-web! cfg params pending [post!]` → `{:ok token} | {:error …}`

```
params : the callback's raw query string ("a=1&b=2"),
         or the already-parsed string-keyed map
post!  : injected token transport; defaults to flow/post-form!
         (a fake gives a fully offline test of every branch but the wire)
```

Returns `{:ok token}` — the *same* shape `finish!` returns, straight from
`oauth/decode-token` — or one of:

| error | meaning | token call? |
|---|---|---|
| `{:error :missing-config :keys [k …]}` | `cfg` lacks a required key | no |
| `{:error :missing-state}` | the callback carried no `state` | no |
| `{:error :unknown-state}` | wrong state, **or** an already-spent one | no |
| `{:error :state-expired :at :expires-at}` | the attempt outlived its TTL | no |
| `{:error :state-mismatch :attempt :session}` | different firm/principal than began it | no |
| `{:error :client-mismatch :attempt :config}` | the client changed since the URL was minted | no |
| `{:error :redirect-mismatch :attempt :config}` | the configured redirect changed | no |
| `{:error :declined :reason :description}` | the human said no (`error=access_denied`) | no |
| `{:error :provider-error :reason :description}` | any other `error=` from the provider | no |
| `{:error :missing-code}` | success redirect with no `code=` | no |
| `{:error :exchange-failed :body :request}` | the exchange itself failed (as `finish!`, `:request` redacted) | yes |

`:declined` and `:exchange-failed` are **return values, not raises**: "the human
said no" and "the wifi dropped" are normal outcomes of a sign-in, and a flow that
raises on either turns them into crash pages.

## 2 · The security properties, and where each is enforced

- **Unpredictable, single-use, expiring state.** Minted with
  `crypto:strong_rand_bytes/1`; consumed with `pending/-take` *before* any other
  decision, so a replay finds nothing. Expiry is checked at `finish-web!` against
  the wall clock. `:unknown-state` deliberately does not distinguish "wrong"
  from "replayed" — a distinct answer would require retaining every spent state.
- **Bound to firm/principal/client/redirect.** The record carries all four; the
  callback's session is compared to the record, and the client/redirect must
  still match the config. A state lifted from another firm's flow cannot finish
  it.
- **Exact configured callback; no untrusted `Host`.** The `redirect_uri` sent to
  the token endpoint is the one the attempt **recorded** at begin time. Nothing
  derives a redirect from the callback query or the request's `Host` header — a
  requester-supplied redirect would let the requester choose where the code goes.
- **PKCE.** The same `code_verifier` that minted the URL's `code_challenge`
  (`S256`) is presented at the exchange; the test asserts the S256 relation
  across the two requests.
- **No code or token leakage.** Failures carry the redacted request
  (`oauth/redact` turns `code`, `code_verifier`, `client_secret`, tokens into
  `<N bytes>`), never the code; `:declined`/`:provider-error` carry only the
  provider's own `error`/`error_description`.
- **No secret at rest.** The pending record holds the verifier and the session
  context but **not** the client secret; the secret is supplied again at finish
  from config.

## 3 · App cutover (Knowledger `google-connect`)

The app's `begin!` currently binds a loopback socket and parks the PKCE state in
`persistent_term`; that is the dev path and can stay for local use. For a
deployment that registers a web redirect:

1. Build one `Pending` store at app start (see §4) and keep it with the app
   state — one per VM/node is enough with `pending/mem-pending`.
2. `GET /connect/google` (a request with the resolved session `:firm` /
   `:principal`):
   ```clojure
   (flow/begin-web (assoc client-cfg :firm firm-id :principal by) pending)
   ```
   Send `:url` to the browser (302), or render it as a link. Do **not** persist
   `:state`/`:verifier` anywhere — the store holds the attempt.
3. `GET /connect/google/callback?code=…&state=…` (resolve the same session):
   ```clojure
   (flow/finish-web! (assoc client-cfg :firm firm-id :principal by) params pending)
   ```
   `params` is the callback's query string or parsed map. On `{:ok token}`, do
   exactly what the loopback worker does today after `finish!`: read `sub`/`email`
   from `oauth/id-claims`, put the grant in the firm's store, record the
   integration. On `{:error …}`, branch on the keyword above — `:declined` and
   `:unknown-state` are user-facing, `:redirect-mismatch`/`:client-mismatch`/
   `:missing-config` are config errors, `:exchange-failed` carries the
   disposition to act on.
4. The session context passed to `finish-web!` must be the **same** firm and
   principal that called `begin-web`; if the callback arrives without a session,
   do not call `finish-web!` at all (there is nothing to compare against).

`client-cfg` is the existing `google-connect/client` map plus `:firm`/`:principal`
at call time.

## 4 · The pending store

`credential.pending/Pending` is a port: `-put`, `-take`, `-sweep!`, `-where`.

- `pending/mem-pending [name]` is the reference tier — this VM's ETS, held by a
  `proc.table` owner so the table outlives the request that began the attempt
  (the callback is a different request; a table owned by the first caller would
  be gone by then). `:ets.take/2` makes `-take` a single atomic get-and-remove,
  so two concurrent callbacks for one state cannot both receive it. Each `-put`
  sweeps expired attempts, which bounds the store; `-sweep!` does it by hand.
  It is right for a single node.
- A multi-node/multi-tenant deployment supplies its own store. **`-take` must be
  atomic** across nodes (two concurrent callbacks for one state must not both
  receive the attempt); the reference store is atomic within one VM and says so.

Sweeping is why an attempt for a state nobody ever presents is eventually
answered `:unknown-state` rather than `:state-expired`: the row is gone before
the callback arrives, and `:unknown-state` — the same answer a replay gets — is
the safe side of the distinction.

## 5 · What is proved offline, and what still needs production

Proved by `test/bl/credential/flow_test.bl` with a fake `post!` and no network:
valid callback end-to-end (including the cross-request S256 relation), wrong /
missing / replayed / expired state, wrong firm and wrong principal, changed
client and changed redirect, provider refusal and provider error, a
callback-supplied `redirect_uri` being ignored, and no code/secret in any
returned failure.

**Not yet proved (needs a real registration and a real consent):**

- the provider accepts this redirect for this client. The redirect shape is
  config; only a live `redirect_uri_mismatch` (or its absence) settles it — the
  note at the top of `flow.bl` explains why a bogus-code probe cannot.
- the app's route wiring, session resolution at the callback, and the
  `finish-web!` failure branches in the UI — app-side, deliberately not edited.

The pending store's contract is proved by `test/bl/credential/pending_test.bl`:
20 concurrent `-take`s of one state yield exactly one record, 20 concurrent
puts of distinct states lose nothing, an attempt outlives the process that put
it, and repeated puts cannot accumulate expired state.  The sealed-at-rest file
store is `credential.store/store-sealed` (AES-256-GCM, key from config,
refusals on a missing/wrong key, a tamper, or an account substitution); its
contract and the one-time migration are §7 of `accounts-and-credentials.md`.
The multi-tenant `store-datom` tier is still not built.
