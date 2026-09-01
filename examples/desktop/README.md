# examples/desktop — native apps as a loom view over live state

Two desktop programs built on `loom.desktop`, the grammar that makes a **native
window a pure projection of state** — the same one-commit / re-render loop the
`live` web stack uses, but the viewer is a real OS window (wry → WebKitGTK) and
the transport is the wry `eval` channel instead of a WebSocket.

Both run in the same BEAM node they render: no browser, no server, no build
step.

## The grammar

```clojure
(require '[loom.desktop :as d])

(d/app
  {:title "Counter" :width 360 :height 220
   :state 0                                       ; any value
   :view  (fn [n] (ui/button {:on-click [:inc]} (str "count: " n)))
   :on-event (fn [n ev] (if (= (first ev) :inc) (+ n 1) n))})
```

- **`:view`** — a pure function `state → loom hiccup`. Use any loom component
  (`loom.ui`, `loom.box`, `loom.token`); they render here unchanged.
- **`:on-event`** — a pure reducer `(state, event) → new-state`. The `event` is
  exactly the term you wrote in the view (`[:inc]`, `[:assign …]`), parsed back
  to beam-lisp data.
- **live re-render** — when the reducer returns a *different* state, the view
  re-renders and one `eval` swaps the page body (and stylesheet). One process
  owns the state, so there is no shared cell and no race.
- **`:tick {:every-ms N :event term}`** — fold `term` every N ms, so a clock or
  a vitals frame advances with no user input.

### Events are loom's ordinary vocabulary

A loom button already carries `:on-click [:term …]`, and `live/hiccup` already
renders that to a `data-ev-click` marker. A tiny client hook (in
`loom.desktop`) binds those markers to `bl.send` via event delegation — so
**every loom component is live in a native window with zero extra wiring**. The
same view drives a web page over a socket or a window over `eval`; only the
mount differs.

### Window shape is a point in an option space

`d/app` is a decorated, resizable window. `d/bar` is the *same loop* at a
different point: a **wlr-layer-shell** surface — frameless, docked to a screen
edge, above tiled windows, spanning the edge. Nothing about the view or the
reducer changes. (Layer-shell is what a wlroots/tiling compositor — niri, sway,
hyprland — actually obeys; X11 `always-on-top` is ignored there.)

### Dropdowns that preserve spacing

A bar is a fixed-height strip, so a naive panel rendered below a pill would be
clipped, and inlining extra content would *widen* the bar. `d/dropdown` solves
both:

```clojure
(d/dropdown {:open? (:menu-open state) :on-click [:menu] :align :right :width 240}
  (d/menu-item [:pick 1] "one")
  (d/menu-item [:pick 2] "two"))
```

* The panel is `position:absolute` — **out of flow**, so the bar row's spacing
  never changes whether the menu is open or shut.
* The surface **auto-grows** to show the open panel and shrinks back on close:
  after every render the page measures its own content height and reports it
  (`[:__loom-height h]`); the driver resizes the surface to fit. No view ever
  computes a pixel height.
* The reserved zone (`:exclusive`) stays **pinned to the bar height**, so the
  grown surface *overlays* the windows below (it is on the `:top` layer) rather
  than shoving them down. Open a menu, nothing reflows; close it, the surface
  shrinks back.

It is pure one-way data flow: `dropdown` reads `:open?` from your state and
fires a toggle event; your reducer flips the flag. Same contract as every other
loom component.

## The programs

### `hello-app.bl` — the whole loop on one screen

```
mix beam_lisp.run --path priv examples/desktop/hello-app.bl
```

A counter with a name field, built from real loom components (card, heading,
badge, field, buttons). Click `+1 / −1 / reset`, type your name — each folds an
event and the window converges. `quit` halts the node.

### `statusbar.bl` — a top-bar that watches the VM it runs in

```
mix beam_lisp.run --path priv examples/desktop/statusbar.bl
```

A frameless layer-shell strip docked to the top of the screen, glassmorphic
(transparent window + translucent, blurred pills). Every second (`:tick`) it
re-reads the live BEAM — clock and process count on the bar; memory, heap,
run-queue depth, and scheduler count tucked into a **dropdown**. A heartbeat dot
pulses each frame. It observes the runtime it runs in: the vitals are read as
plain data (`erlang/memory`, `erlang/system_info`) and painted by loom.

Click **`vitals ▾`** to open the dropdown: the extra stats appear in a panel
that overlays the windows below — the bar keeps its exact footprint, and tiled
windows don't move. That is the "dropdowns that preserve spacing" mechanism
above, in the flesh.

> The bar spans the full width automatically (anchored left+right via
> layer-shell) — no monitor width to configure. Adjust `:height` or `:edge`
> (`:top`/`:bottom`) to taste.

## Notes

- **Wayland**: wry uses WebKitGTK via GTK, which works on Wayland and X11
  alike; no `QT_QPA_PLATFORM` dance is needed (that is only for the Android
  emulator on this host).
- **Availability**: both programs check `(d/available?)` and exit cleanly if the
  native backend or a display is absent, rather than crashing.
- **Lifetime**: each program `(Process/sleep …)`s to keep the node alive while
  the window is open. Close the window (or `quit` / Ctrl-C) to exit.
