# Native browser external port

`bl-browser-port` owns a headed Chromium process, a dedicated Xvfb display and
an x11vnc desktop stream. It speaks packet-4 JSON on stdin/stdout, directly
compatible with Erlang ports. Diagnostics go to private runtime files.

Build with `cargo build --release --locked`. The Rust binary requires Linux,
Chromium, Xvfb and x11vnc. Use installed executables or `nix develop` in this
directory for a pinned dependency environment. Docker and Podman are unnecessary.
Chromium retains its sandbox. The helper uses `--ozone-platform=x11` and removes
inherited Wayland settings only from its display children.

## Protocol

Each frame is a four-byte unsigned big-endian length followed by UTF-8 JSON.
The maximum frame size is 8 MiB. Requests and responses are serialized. The
response echoes `id` and contains either `ok: true, result` or `ok: false, error`.
A malformed frame closes the helper; a malformed JSON command returns an error.

- `{"op":"ping"}` reports protocol version 1.
- `launch` accepts absolute `profile`, `runtime`, `chromium`, `xvfb` and `vnc`
  paths, optional HTTP(S) `url`, and bounded `width`/`height`. It returns `pid`,
  loopback `cdp`, private `vncSocket`, `display` and `profile` paths.
- `info` checks every owned process and returns the current descriptor.
- `cdp` accepts Chromium's `method`, optional `params` and optional flattened
  `sessionId`. Events are consumed while waiting for the matching response;
  this is a request API, not a telemetry subscription.
- `stop` requests `Browser.close`, waits for Chromium, terminates remaining
  display/stream process groups and acknowledges `saved` only on a clean close.
- `forget` takes an absolute managed `profile` path and deletes it only after
  acquiring its writer lock. Unmarked directories and symlinks are refused.

Only one helper can own a profile: an OS file lock spans the browser lifetime.
Chromium writes its normal user-data directory; `.bl-saved` acknowledges a clean
close. Normal stdin EOF also closes and saves; the Beam Lisp `close` function explicitly
requests a stop before closing its port. An abrupt crash leaves the profile
for Chromium recovery; it does not acknowledge a new save. Consumers must never
turn uncertain closure into a successful save. No live JS heap survives restart.

All paths/capabilities in descriptors are private to the host. The VNC server
uses a Unix socket under a mode-0700 runtime directory and no TCP VNC listener.
CDP listens on a dynamically chosen loopback port. Xvfb disables TCP listening;
the local display requires a random MIT-MAGIC-COOKIE-1 stored in mode-0600
Xauthority files inside the private runtime directory. CDP is accessible to
processes that can reach host loopback. This is process
supervision with Chromium's sandbox, not a separate tenant or VM boundary.

The embedder supplies a viewer and enforces human/agent control on viewer input.
Passwords belong in the user's browser extension or credential manager, never
in protocol logs. The helper deliberately has no password-storage API.

## Beam Lisp

```clojure
(require '[browser.port :as browser])
(def p (browser/open "/absolute/path/to/bl-browser-port"))
(browser/request p {"op" "ping"})
;; launch once, then issue CDP operations through the same port
(browser/close p)
```

The calling process owns the port. Run it in a supervised worker and serialize
calls. A request timeout closes the port to prevent a late response being reused
as another request's answer. An external-port owner can crash without native
code corruption taking down BEAM.

## Verification

```sh
cargo test --locked
cargo build --release --locked
BL_BROWSER_PORT=/absolute/path/to/bl-browser-port \
  /path/to/beam-lisp/bin/bl test -p /path/to/beam-lisp/priv/lib test/port_test.bl
```

The Rust tests cover framing limits, truncation, Unicode and EOF. The Beam Lisp
test drives the actual executable over `erlang/open_port`, including an error
followed by a valid request. The Omega consumer's real native drive additionally
checks headed localhost browsing, Unix-socket desktop input, input denial during
agent control, exclusive writers, cookie/storage persistence, raw CDP, restart
and guarded deletion. 1Password account approval requires a separate human test.

## Scenario runner integration seam

A native scenario backend can implement the existing `scenario/run-world`
world map (`:open`, `:step!`, `:claim!`, `:observe`, `:liveness`, `:close!`) with
one supervised port owner per browser. Use dedicated actor profiles and explicit
CDP target/session IDs; never share a writable profile between concurrent owners.
Keep browser verdicts witnessed and preserve refuted/unknown outcomes.
`scenario.runner.adapt` already normalizes runs and validates browser evidence;
feed its descriptor/manifest/provenance contract rather than inventing another
runner result. The existing media slot accepts step/time marks for captures.
A two-actor localhost convergence scenario, failure artifacts and guaranteed
cleanup are the first follow-up. Event subscriptions, recording and editor
presentation are outside this request-only native port implementation.
