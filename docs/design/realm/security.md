# Security

A page that can stop processes is a remote-control surface. Loopback is not a
trust boundary: **any web page you visit can ask your browser to call
`127.0.0.1`.** This document says who may do what, and how each attack is
refused. Every claim marked ✔ is covered by a test that ran.

## The two attacks that matter

| attack | how it works | what stops it |
|---|---|---|
| **cross-site request** | a hostile page `POST`s `/api/vms/<id>/stop` to `127.0.0.1` | a token in a **custom header** (`x-bl-token`). A cross-origin caller cannot set one without a preflight, and the server never approves a preflight. ✔ |
| **DNS rebinding** | a hostile name resolves to `127.0.0.1`; the browser treats it as same-origin, *reads the page, and so reads the token* | a **Host check**: a rebound request arrives with the attacker's name in `Host`, which no legitimate caller sends. ✔ |

A token alone does not stop the second. A Host check alone does not stop the
first. Both are required.

## The Host guard

Every `/machine` and `/api/vms` request is refused (403) unless its `Host` is one
we would put in a link:

- a loopback address (`127.0.0.1`, `[::1]`),
- `localhost`,
- a name a **live claim** holds (so `blueprint.test` works through the gateway).

Verified: `evil.example.com`, `evil.example.com:4000`, `127.0.0.1.evil.example.com`,
an empty `Host`, and no `Host` are all refused. ✔ A refused page carries **no
token** and no data. ✔

## The token

The session token is 32 random bytes held in the VM's `0600` token file. The page
embeds it as lowercase hex (64 characters) and the guard compares it in constant
time. The raw bytes are not valid UTF-8, so they cannot be JSON-encoded as they
are — there is one encoding (`token-hex`), used by both the page and the check,
so they cannot drift.

Writes need the token. Reads of `/machine` need only the Host guard, because
they reveal nothing that `bl vm` does not.

## Who may stop what

| actor | may stop |
|---|---|
| you, at a shell | any VM you own (`bl vm stop`) — file permissions are the boundary |
| the page served by VM *A* | any VM **except A itself** |
| a hostile page | nothing |

Today the page is served by a session VM and holds **that VM's** token. Stopping
a VM goes through the inventory (control socket, then a signal after proving the
pid), which does not need the *target's* token — it reads the target's `0600`
token file as the same user. See the caveat on trust in
[`caveats.md`](caveats.md).

## What is refused, always

- **Stopping the VM the command runs in.** It would cut the answer off.
- **Signalling a pid that is not provably a bl node.** A record's start ticks must
  match, or (for an adopted row) the command line must say `beam.smp`. A reused
  pid is reported as *gone* and left alone. ✔
- **Guessing.** An ambiguous target stops nothing.
- **KILL without `--force`.** ✔

## Escaping

Every name that reaches HTML — ids, project names, paths, route names — is
escaped. A project directory named `<script>` renders as text. ✔

## What this does not protect against

- **Another local user.** The runtime dir is `0700` and records are `0600`; a
  process running as *you* can do anything you can. That is the model.
- **A compromised browser extension** with access to `127.0.0.1`. It can read the
  page and the token. Treat the console like a terminal you left open.
- **Remote access.** The server binds loopback. Exposing it needs a design of its
  own (TLS, real authentication); do not tunnel it as is.
