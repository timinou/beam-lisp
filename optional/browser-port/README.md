# Optional native browser external port

This package is **excluded from ordinary Beam Lisp production releases**.
It lives outside `priv/` (the release source tree) and `native/*` (the automatic
NIF build scan). No core namespace imports it. Cargo's default feature set is
empty: a default build resolves no browser dependencies and produces no browser
executable. The root Beam Lisp flake does not reference this runtime.

An application opts in by adding this package's `bl/` directory to its source
path, explicitly requiring `browser.port`, building the executable with the
`native-browser` feature, and packaging its chosen runtime separately. Merely
requiring the namespace does not spawn a process, install software or download a
browser. Applications that do not import it have no browser client, executable,
compositor, VNC server or Chromium closure to ship. Browser applications must
package the external executable/dependencies explicitly; imports do not silently
install system tools. This is an external port, not a NIF or core application.

```sh
# Run from this package directory; opt in deliberately.
cargo build --release --locked --features native-browser
nix build .#runtime-wayland             # optional pinned dependency environment
# Add -p /absolute/path/to/optional/browser-port/bl to your application's bl command.
```

Wayland is the default. The helper owns a private headless Sway compositor and
wayvnc stream, and runs regular headed Chromium with `--ozone-platform=wayland`.
Xwayland is disabled in the compositor config. It never attaches to or modifies
the user's compositor, display settings, sockets or environment. CPU rendering
(pixman) avoids depending on GPU access; the VNC rate is bounded at 30 fps and
captures damage rather than polling browser screenshots. This follows wayvnc's
[headless guidance](https://github.com/any1/wayvnc/blob/master/FAQ.md).

X11 is an explicit compatibility choice, with no silent fallback:

```sh
cargo build --release --locked --features native-browser,x11
nix build .#runtime-x11
# Supply displayBackend:"x11", xvfb and x11vnc paths when launching.
```

Neither runtime is a default Nix package. The development shell contains Rust
build tools only. Docker, Podman and NixOS are unnecessary. Set
`BL_BROWSER_ENABLED=0` to refuse new ports/launches before profile creation.
Existing browsers must still be stopped normally to save; the switch does not
kill processes or discard profiles. Disable the application import/package to
remove the entire feature from its production artifact.

## Protocol

Four-byte unsigned big-endian length followed by UTF-8 JSON; maximum 8 MiB.
Requests are serialized. Responses echo `id`, with `ok:true,result` or
`ok:false,error`. Malformed framing closes the helper; invalid JSON returns an
error. Diagnostics stay in private runtime files, not protocol stdout.

- `ping` reports protocol 1.
- `launch` takes absolute `profile`, `runtime`, `chromium` and `vnc` paths,
  bounded `width`/`height`, optional HTTP(S) `url`, and `displayBackend`.
  The default `wayland` requires `compositor` (Sway) and `vnc` (wayvnc).
  Explicit `x11` requires `xvfb` and `vnc` (x11vnc), plus the x11 build feature.
  Returns `pid`, loopback `cdp`, private `vncSocket`, `display`, `displayBackend`
  and `profile`. Consumers keep these capabilities private.
- `info` checks all owned processes.
- `cdp` takes Chromium's `method`, optional `params` and flattened `sessionId`.
  Unmatched events are consumed; this is not an event subscription API.
- `stop` requests `Browser.close`, waits for a successful browser exit, reaps
  display/stream process groups, and acknowledges `saved` only on clean closure.
- `forget` deletes only a marked managed profile after acquiring its writer lock;
  symlinks and arbitrary directories are refused.

One helper owns a profile via an OS writer lock. Chromium writes its normal
user-data directory. `.bl-saved` records acknowledged clean closure; normal EOF
also attempts a clean stop. Abrupt loss keeps the profile for recovery and never
acknowledges a new save. No live JS heap survives reopening.

Profile/runtime directories are mode 0700. Wayland sockets and VNC's Unix socket
stay inside the private runtime directory; no TCP VNC listener exists. Explicit
X11 uses a random MIT cookie in mode-0600 Xauthority files and disables TCP X11.
CDP binds a random host-loopback port and is reachable by processes that can
access host loopback. This is trusted-workstation supervision with Chromium's
sandbox enabled, not tenant isolation. The embedder supplies viewer capability,
origin checks and human/agent input policy. There is no password-storage API.

## Beam Lisp

```clojure
(require '[browser.port :as browser])
(def p (browser/open "/absolute/path/to/bl-browser-port"))
(browser/request p {"op" "ping"})
;; launch with explicit runtime paths, then issue CDP operations on the same port
(browser/close p)
```

Keep the port in one supervised owner and serialize calls. Timeout closes the
port to prevent late-response reuse; do not silently retry uncertain mutations.
`close` requests stop before closing; callers needing a save acknowledgement use
an explicit `stop` request and inspect its result. Owner death is abrupt recovery.

## Verification

```sh
python3 test/packaging_test.py           # no Chromium, Nix or BEAM required
cargo test --locked --features native-browser
cargo test --locked --features native-browser,x11
BL_BROWSER_PORT=/absolute/path/to/bl-browser-port \
  /path/to/bl test -p "$PWD/bl" test/port_test.bl test/off_test.bl
# Headed tests additionally need CHROMIUM, SWAY, WAYVNC. For compatibility tests
# set BROWSER_DISPLAY_BACKEND=x11, XVFB and X11VNC instead.
```

The packaging gate asserts exclusion from the core build/release trees and
proves a default Cargo build has no dependencies or executable. Rust tests cover
framing; BEAM tests drive the real executable, headed CDP and clean profile close.
The Omega consumer adds real Wayland/X11 framebuffer/input, profile recovery,
viewer authorization, input gating, off-mode lazy imports and editor proof.
1Password account approval remains a human acceptance check.

## Scenario runner integration seam

A native backend can implement `scenario/run-world`'s existing world map with
one supervised port owner per actor/browser. Use dedicated profiles and explicit
CDP target/session IDs. Feed `scenario.runner.adapt`'s existing run/evidence
contract and retain witnessed/refuted/unknown verdicts. Two-actor localhost
convergence, failure artifacts and cleanup are the first follow-up. Event
subscriptions, recording and editor presentation remain separate work.
