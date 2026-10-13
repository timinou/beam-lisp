# Window lifecycle regression

On a **private** display, run `bin/bl run native/wry_webview/test/closed.bl`.
It verifies live evaluation, closed eval/resize exceptions and repeated close.
With `WRY_CLOSE_BY_WM=1`, close its “Wry lifecycle regression” window through
that private window manager after `WRY_READY`. It must print `WRY_CLOSED_OK`
within ten seconds. This also checks GTK's OS-close path, which can retain the
proxy's channel receiver after the native event-loop thread finishes.

`Error::Term` returns a value from Rustler; `Error::RaiseTerm` raises. The Wry
API promises exceptions on failure. A proxy accepting a send does not prove a
live window: eval and resize also check the thread's completion without waiting
on its join mutex. Closing takes the join exactly once and remains idempotent.

Omega's `spikes/home/test/browser.py` drives an actual native root launcher
under private headless Sway, closes it through the WM, and checks that its CLI
returns while the canonical host remains available. It additionally checks
that explicit host stop closes the listening port without terminating the VM.
Keep foreign GUI processes outside a canonical host VM: WebKit can inherit OS
listening descriptors, whose lifetime is independent of actor supervision.
