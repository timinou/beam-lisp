# App-owned private worlds

An application may declare `:session-for (fn [verified-principal request] conn-or-nil)`.
The router resolves it once for SSR or a new WebSocket; the selected connection
becomes the view's session database. The app owns its lifetime, scope and expiry.
This permits private drafts to outlive a socket or a page refresh without
putting them in the shared business store. Existing apps default to no session.

An app socket observes its private connection automatically, alongside its shared
and explicitly observed connections. A private commit reprojects the sockets
which selected that connection. Transport reattach still checks the original
authenticated principal; editable locals cannot replace ambient app/identity.

Existing function intent entries retain their shared target. The optional
server-declared descriptor chooses a private writer:

```clojure
{:intents {:edit-draft {:target :session :perform edit-draft}
           :accept-order accept-order}}
```

The performer receives `(selected-conn payload principal)` and returns ordinary
transaction data, nil or a refusal. Authorization and truthful commit/refusal
outcomes retain the socket's normal path. Target selection belongs exclusively
to the registry; a payload `:target` field cannot change it. A missing private
connection refuses without writing the shared world.

The app value can also declare the existing request middleware shape as
`:around (fn [handler request] response)`. Explicit `serve` options take
precedence. This is useful for establishing opaque browser-session context
before selection and adding its cookie to the resulting HTTP response. It
introduces no browser event or business authorization shortcut.

Private world selection is application policy, like guarded `:worlds` and
`:shared-for`: verify ownership, tenant, session identity and expiry there.
Keep the selected connection owned by an app process rather than by an HTTP
request. Separate business acceptance still belongs in its shared writer.
