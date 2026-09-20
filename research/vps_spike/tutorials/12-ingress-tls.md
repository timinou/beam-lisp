# 12 — Ingress TLS: one listener, a per-name leaf from the node's own CA

A node mints its own root, then a leaf per service name on demand, and a single
`:ssl` listener picks the right leaf from each handshake's SNI — so a new HTTPS
name is a routing decision, not a certbot episode.

## The claim

From `docs/design/vps/devops.md §Ingress, TLS, naming`:

> `vm/gateway.bl` holds :80/:443 as its own small OS process, routes by `Host:`,
> and serves per-name leaf certs from the node's own CA (`vm/ca.bl`).

And from the same section: *"a new public name is one attribute in desired state;
route, claim, and cert appear together"*, with renewal a `proc/sched` job — "no
certbot cron, no reload dance". The spike proves the load-bearing half: **the
node's own CA** (`vm.ca`, exercised as-is) mints a distinct leaf per name, **one
`:ssl` listener** serves every name via `sni_fun`, and a real TLS handshake
returns the backend that owns the name. The `Host:`-to-claim routing and the
separate gateway process are modelled (see "Real vs modelled").

## The idea

A browser accepts `https://web.svc.localhost/` only if it can verify the cert,
and no public CA vouches for `web.svc.localhost`. The usual answer is a
cert-manager + ACME + renewal-cron + reload dance, all of it procedure you must
remember to run. bl answers differently: **the node is its own CA.** It mints one
root (the thing a client trusts, served at `/bl-ca.crt`) and a leaf *per name*
the instant that name is needed — no x509 library, no openssl, no mkcert, just
the BEAM's own `:crypto` and `:public_key`.

The second half is the interesting one for a reverse proxy. You do not want a
listener (and a port, and a process) per name. You want **one** listener that
looks at the SNI the client sent and presents *that name's* certificate. That is
exactly Erlang's `:sni_fun`: a callback the `:ssl` handshake invokes with the
server name, returning the cert/key options to use. So "add a name" is not
"provision a cert"; it is "the next handshake for that name mints a leaf and the
same listener serves it". Route, cert, and name all fall out of one lookup.

This is ingress as a *data* problem: a name maps to a leaf (minted on demand and
cached) and to a backend (routed). Nothing to renew by hand, nothing to restart
to add a name.

## Walkthrough

### 1. Boot the real TLS stack

```clojure
(ns vps.ingress-tls (:require [vm.ca :as ca]))

(erlang/apply :application :ensure_all_started (list :ssl))
```

The namespace pulls in `vm.ca` — the node's CA, in pure beam-lisp. Then it starts
OTP's real `:ssl` application (which brings up `:crypto` and `:public_key` under
it). Everything below is genuine TLS; there is no simulator.

### 2. The node's CA: one root, trusted by clients

```clojure
(def root-pem (ca/root-pem))
(println "── the node's CA ──")
(println "  root cert:" (subs root-pem 0 27) "…")
```

`ca/root-pem` calls `ca/ensure-started`: if no root is cached, it generates an
RSA-2048 key with `:crypto`, builds an `OTPTBSCertificate` whose subject is the
node's own identity, signs it with `:public_key/pkix_sign`, caches it in
`:persistent_term` **and** on disk (the key written `0600`), and returns the
cert. `root-pem` PEM-encodes it for a client to trust. The `subs … 0 27` just
shows the header: `-----BEGIN CERTIFICATE-----`. This is the certificate a
browser installs once as `/bl-ca.crt`; every name's leaf chains to it.

### 3. The route table

```clojure
(def routes {"web.svc.localhost" "web-backend-v3"
             "api.svc.localhost" "api-backend-v2"})
(defn backend-for [host] (get routes host))
```

Name → backend answer. This is the modelled stand-in for `vm.gateway`'s routing
table: the real gateway derives its routes from `vm.ports` claims on disk (a
claim carries the hosts it answers to, keyed by `Host:`), and proxies the
connection to the claiming port. Here it is a plain map with a plain string
answer — enough to prove the SNI-selected leaf and the name-selected backend
agree, without an HTTP layer.

### 4. One listener, per-name leaf via `sni_fun`

```clojure
(def sni (ca/sni-fun))
(def lopts (list (tuple :sni_fun sni) (tuple :reuseaddr true) :binary (tuple :active false)))
(def ls (elem (erlang/apply :ssl :listen (list 0 lopts)) 1))
(def portnum (elem (elem (erlang/apply :ssl :sockname (list ls)) 1) 1))
(println "── one TLS listener on :" portnum " serving every name ──")
```

`ca/sni-fun` returns a closure that, for any server name, calls `ca/ssl-opts name`
— which mints (or fetches from `:persistent_term`) that name's **leaf**: a fresh
key, an `OTPTBSCertificate` with the name as subject and a **SAN dNSName** for the
name (plus `localhost`, since `.localhost` names are given both spellings),
signed by the *root's* key. The listener options pass that closure as
`:sni_fun`; note there is **no default `:cert`/`:key`** in `lopts` — every
certificate this listener serves comes from the SNI callback, which is precisely
how the gateway installs it. `:ssl :listen 0` binds an OS-chosen ephemeral port
(`0`), and `:sockname` reads it back — so the spike never collides with anything.
One listener, every name.

### 5. The acceptor: read the SNI, answer with its backend

```clojure
(defn serve-one []
  (erlang/spawn
    (fn []
      (let [r (erlang/apply :ssl :transport_accept (list ls 5000))]
        (when (= :ok (elem r 0))
          (let [h (erlang/apply :ssl :handshake (list (elem r 1) 5000))]
            (when (= :ok (elem h 0))
              (let [sock (elem h 1)
                    sni-name (let [ci (erlang/apply :ssl :connection_information
                                        (list sock (list :sni_hostname)))]
                               (if (= :ok (elem ci 0))
                                 (let [v (get (into {} (map (fn [t] [(elem t 0) (elem t 1)]) (elem ci 1))) :sni_hostname)]
                                   (if (list? v) (erlang/list_to_binary v) v))
                                 nil))
                    host (if (list? sni-name) (erlang/list_to_binary sni-name) sni-name)
                    backend (backend-for host)]
                (erlang/apply :ssl :send (list sock (erlang/iolist_to_binary
                                                      (list (or backend "no-route")))))))))))))
```

Each call spawns one acceptor process. `:ssl :transport_accept` blocks for a
connection; `:ssl :handshake` performs the TLS handshake — invoking `sni_fun`
behind the scenes so the right leaf is presented. Then `:ssl
:connection_information` with `[:sni_hostname]` reads back **the name the client
actually asked for**, and that name is looked up in `routes`. The answer (or
`"no-route"` when the name is unknown) is sent as the reply. So the handshake is
what selected the certificate; the same SNI is what selects the backend — one
name, one lookup, both sides agree.

### 6. A client per name: read the backend and the presented leaf

```clojure
(defn hit [host]
  (serve-one)
  (Process/sleep 100)
  (let [c (erlang/apply :ssl :connect
            (list (erlang/binary_to_list "127.0.0.1") portnum
                  (list :binary (tuple :active false) (tuple :verify :verify_none)
                        (tuple :server_name_indication (erlang/binary_to_list host))) 5000))]
    (if (= :ok (elem c 0))
      (let [sock (elem c 1)
            cert-r (erlang/apply :ssl :peercert (list sock))
            got (elem (erlang/apply :ssl :recv (list sock 0 3000)) 1)]
        {:backend got :got-cert (= :ok (elem cert-r 0))})
      {:error (elem c 1)})))
```

`hit` starts an acceptor, then connects to `127.0.0.1` on the ephemeral port,
**sending `host` as the SNI** via `:server_name_indication`. The handshake uses
the leaf that name's SNI selects. `:ssl :peercert` fetches the leaf the server
presented; `:ssl :recv` reads the backend string. The result is
`{:backend got :got-cert (= :ok cert-r)}` — did the name route to the expected
backend, and did the handshake present *a* leaf at all. Two names, two calls:

```clojure
(def web (hit "web.svc.localhost"))
(def api (hit "api.svc.localhost"))
(println "── routed by name, each with its own leaf ──")
(println "  web.svc.localhost →" (pr-str web))
(println "  api.svc.localhost →" (pr-str api))
```

### 7. Assertions

```clojure
(def ok (and (= "web-backend-v3" (:backend web))     ; SNI web → web backend
             (= "api-backend-v2" (:backend api))     ; SNI api → api backend
             (:got-cert web) (:got-cert api)         ; each handshake presented a leaf
             (clojure.string/starts-with? root-pem "-----BEGIN CERTIFICATE")))
(println (str (if ok "PASS" "FAIL") " 12_ingress_tls  (one listener, per-name leaf, routed by SNI)"))
```

Three things must hold: each name routed to its own backend over TLS, each
handshake presented a leaf, and the CA root really is a PEM certificate. Note
what the assertion does *not* check: it never verifies the leaf chains to the
root, nor that the two names receive *different* leaves — see below.

## What's real vs modelled

**Exercised as-is (the real organs):**

- **`vm.ca`** — the whole CA is real and in-repo (`priv/std/vm/ca.bl`):
  `ca/root-pem` mints or loads the root; `ca/sni-fun` calls `ca/ssl-opts name`,
  which mints a real per-name **leaf** (RSA-2048 key from `:crypto`;
  `OTPTBSCertificate` assembled by hand; `:public_key/pkix_sign`; a SAN dNSName
  extension for the name — plus `localhost`), cached in `:persistent_term` and on
  disk. No openssl, no mkcert, no x509 library — the authority is pure beam-lisp
  over the BEAM's own BIFs. The root is persisted with its key `0600` and a
  `root.pem` for clients.
- **A real Erlang `:ssl` listener and handshake.** `:application
  ensure_all_started :ssl`, `:ssl :listen` with an `:sni_fun`, `:ssl
  :transport_accept`, `:ssl :handshake`, `:ssl :connect`, `:ssl :send`/`:recv`,
  `:ssl :connection_information … :sni_hostname`, `:ssl :peercert` — the actual
  OTP TLS stack, on a real loopback socket (`127.0.0.1:<ephemeral>`). The SNI is
  genuinely sent by the client (`:server_name_indication`) and genuinely read
  back by the server.
- **`erlang/apply`** — the real BIF-invocation path; `:crypto`, `:public_key`,
  `:persistent_term`, `:calendar` are the real OTP modules.
- The root is a **real PEM** (`-----BEGIN CERTIFICATE-----`), the certificate a
  client would install as `/bl-ca.crt`.

**Modelled in miniature / simplified for the probe:**

- **The route table is a plain map.** `{"web.svc.localhost" "web-backend-v3",
  "api.svc.localhost" "api-backend-v2"}` is an in-process literal. The real
  `vm/gateway.bl` holds routes as `vm.ports` **claims on disk** (one file per
  claim, carrying `:hosts`), resolves the `Host:` header with
  `ports/holder-of-host`, and *proxies the connection* to the claiming port —
  with host normalization, live-claim sweeping (a claim whose pid is gone is
  swept), and a `[]`-vs-pinned port-number discipline. None of that is exercised;
  `backend-for` is a `get` on a map.
- **No HTTP layer, and only SNI — not `Host:`.** The gateway parses an HTTP/1.1
  request, reads `Host:`, and splices to the backend. This spike speaks no HTTP:
  the client sends no request line, and the server replies with a bare string
  after reading the TLS **SNI**. So "routed by SNI/Host" is proven only for the
  SNI half; the `Host:`-header routing path is not run.
- **No gateway process, no `:80`/`:443`, no draining.** The listener is created
  *inside* the spike VM on an ephemeral loopback port; it is not the separate
  OS process holding the privileged ports that `devops.md §ingress` and
  `zero-downtime.md` describe. The whole "gateway keeps answering while the node
  under it is swapped" property is out of scope here (that is spike 09's
  territory, and even there via socat).
- **The chain is never actually verified.** The client connects with `:verify
  :verify_none` and the assertion's `:got-cert` is only `(= :ok (:peercert …))` —
  i.e. "a leaf was presented", not "the leaf chains to `ca/root-pem`". Leave
  `verify` alone and a self-signed leaf from any CA would pass. The leaf-signs-
  under-root property is a property of `vm.ca`'s recipe (its own header notes
  `pkix_path_validation` confirms it), but this probe does not re-check it.
- **Per-name *distinctness* of leaves is implicit.** The mechanism is real
  (`sni_fun` → `ssl-opts name` → a leaf minted per name), but the probe fetches
  `peercert` and throws it away down to a boolean; it would still pass if both
  names were served the same leaf.
- **One-shot acceptor, no accept loop.** `serve-one` spawns a single process that
  accepts exactly one connection, and `hit` spawns a fresh one before each client
  (with a 100 ms sleep to let it reach `transport_accept`). The socket is not
  `:ssl :close`d after the reply, and there is no supervised acceptor pool,
  re-listen, or connection draining — a real gateway runs a persistent accept
  loop.
- **Names are SNI-only; DNS is not exercised.** The client always connects to
  `127.0.0.1` and sets the SNI explicitly; nothing resolves `web.svc.localhost`,
  and the SAN carries the name but no resolvable record exists (the design's
  "internal-only names resolve only on the cluster interface" is not modelled).
- **No renewal job.** The daily `proc/sched` cert renewal from `devops.md` is
  absent: the leaf is minted once on demand and cached; nothing rotates it, and
  there is no reload to observe because there is nothing to reload.

## Run it

```bash
./blx run research/vps_spike/12_ingress_tls.bl
```

Nothing else is needed — no Garage, no podman, no root; the only dependency is
OTP's `:ssl` app, which ships with the BEAM. Expected output (the port is
OS-chosen, so it varies):

```
── the node's CA ──
  root cert: -----BEGIN CERTIFICATE----- …
── one TLS listener on :<port>  serving every name ──
── routed by name, each with its own leaf ──
  web.svc.localhost → {:backend "web-backend-v3", :got-cert true}
  api.svc.localhost → {:backend "api-backend-v2", :got-cert true}

PASS 12_ingress_tls  (one listener, per-name leaf, routed by SNI)
```

Expected final line, verbatim:

```
PASS 12_ingress_tls  (one listener, per-name leaf, routed by SNI)
```

Cold start costs ~10–15 s (JIT warmup) — that is boot, not the TLS work.

## Exercises

1. **Add a third name.** Add `"metrics.svc.localhost" "metrics-backend-v1"` to
   `routes`, then `(def m (hit "metrics.svc.localhost"))` and print it. Predict:
   the SNI mints a *third* leaf on demand (a new `ssl-opts` call), the backend
   comes back `"metrics-backend-v1"`, and the spike still PASSes. The leaf count
   in `:persistent_term` grew by one — proof that "add a name" mints, not
   provisions.

2. **Black-hole a name.** Change the value for `"api.svc.localhost"` to `nil` (or
   delete the key). Predict: `backend-for` returns `nil`, the `(or backend
   "no-route")` fallback sends `"no-route"`, and `(= "api-backend-v2" (:backend
   api))` fails → `FAIL 12_ingress_tls …`. The handshake still succeeds (a leaf
   still exists); only the route is missing — the two concerns are
   independently testable.

3. **Drop the SNI.** Remove `(tuple :server_name_indication …)` from the client's
   connect options. Predict: the server's `connection_information … :sni_hostname`
   yields no name → `host` is `nil` → `backend-for` returns `"no-route"`, so both
   hits fail the route assertion; and since `sni_fun` returns `:undefined` for a
   missing name with **no default `:cert` in `lopts`**, the handshake itself may
   fail outright. Either way `:got-cert`/route assertions break — showing the SNI
   is what selects both leaf and route.

4. **Make the client verify.** Add `(tuple :verify :verify_peer)` and
   `(tuple :cacerts (list (ca/root-der)))` to the connect options (dropping
   `:verify_none`). Predict: the handshake still succeeds, because each leaf is
   signed by the root whose DER you just trusted — a genuine chain check this
   time. Then omit the `:cacerts` line: predict the handshake fails with
   `unknown_ca`, proving the leaf is an independent certificate that chains only
   to the node's own root.
