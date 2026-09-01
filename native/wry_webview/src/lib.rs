//! `wry` — a native window with a WebView, as a beam-lisp capability.
//!
//! # What this is
//!
//! One `defnative` crate that turns "show a web UI" into three verbs a
//! beam-lisp program calls like any other function:
//!
//!     (def w (wry/open {:title "Hi" :html "<h1>hi</h1>"}))
//!     (wry/eval w "document.body.style.background='rebeccapurple'")
//!     (wry/close w)
//!
//! The window is a real OS window (`tao`) hosting a real browser engine
//! (`wry` → WebKitGTK on Linux). Everything above this file is ordinary
//! beam-lisp; the crate is the substrate, exactly as the datom store
//! backends are.
//!
//! # The one hard constraint, and how it is met
//!
//! A GUI toolkit owns a thread. Its event loop must run somewhere, gtk must
//! be initialised on the thread that touches it, and that loop blocks. A NIF,
//! by contrast, must return promptly to its BEAM scheduler — it may not sit in
//! a blocking `run` forever. So each `open` spawns ONE dedicated OS thread and
//! the whole windowing life happens there:
//!
//!   * `tao`'s `EventLoopBuilderExtUnix::with_any_thread(true)` lifts the
//!     "event loops live on the main thread only" assertion — legal here
//!     because this thread is the loop's sole owner for its whole life.
//!   * `EventLoopExtRunReturn::run_return` is used instead of `run`, because
//!     `run` calls `process::exit` when the last window closes — which would
//!     take the entire BEAM node down. `run_return` hands control back, the
//!     thread unwinds, and the node lives on.
//!   * The thread hands a `Send` `EventLoopProxy` back to the opening NIF
//!     through a channel; that proxy is what `eval` and `close` poke to drive
//!     the window from any BEAM process. It is the only thing that crosses the
//!     thread boundary after setup.
//!
//! # IPC: the WebView talks back
//!
//! `with_ipc_handler` fires for every `window.ipc.postMessage(s)` the page
//! runs. The handler is off-scheduler Rust, so it delivers the string to the
//! caller's mailbox with an `OwnedEnv` — the message arrives as
//! `{:wry-ipc, "the body"}`, and `priv/wry.bl` turns that into an
//! `:on-message` callback. An init script aliases `bl.send(x)` to
//! `window.ipc.postMessage`, so the page-side call is short too.
//!
//! # Scope (prototype #1)
//!
//! ONE window per `open`, driven robustly: open, eval, close, and IPC both
//! ways. Many concurrent windows is a real next step — gtk's global init is
//! per-thread and the second loop wants care — and is deliberately NOT claimed
//! working here.

use rustler::env::OwnedEnv;
use rustler::{Encoder, Env, Error, LocalPid, NifResult, Resource, ResourceArc, Term};
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread::JoinHandle;

use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tao::platform::run_return::EventLoopExtRunReturn;
use tao::platform::unix::{EventLoopBuilderExtUnix, WindowExtUnix};
use tao::window::WindowBuilder;
use wry::{WebViewBuilder, WebViewBuilderExtUnix};

// GTK bits for wlr-layer-shell docking and window transparency. gtk-layer-shell
// operates on the underlying gtk::ApplicationWindow (reached via WindowExtUnix
// ::gtk_window) and MUST be initialised before the window is first mapped.
use gtk::prelude::*;
use gtk_layer_shell::{Edge, Layer, LayerShell};

/// Messages driven INTO a window's event loop from the BEAM side.
enum UserEvent {
    /// Run this JavaScript in the page.
    Eval(String),
    /// Resize the surface to (width, height) logical px. Used for a layer-shell
    /// bar that grows to host a dropdown and shrinks when it closes. The
    /// exclusive zone is set separately (and stays pinned to the bar height),
    /// so growing the surface overlays windows below rather than reflowing them.
    Resize(f64, f64),
    /// Tear the window down and let the loop thread unwind.
    Close,
}

/// A live window handle held by beam-lisp as an opaque value.
///
/// It owns the way to talk to the window (`proxy`) and the way to wait for its
/// thread to finish (`join`, taken once at close). Both sit behind a `Mutex`
/// so the handle is `Sync` and so `close` can take the join handle exactly
/// once; the mutex is uncontended in practice (a window has one driver).
struct WebViewHandle {
    proxy: EventLoopProxy<UserEvent>,
    join: Mutex<Option<JoinHandle<()>>>,
}

// A NIF return crosses a `catch_unwind`, which demands `RefUnwindSafe`.
// `EventLoopProxy` only sends `UserEvent`s across the boundary and the join
// handle is `Option`-guarded, so there is no shared mutable state a panic
// could observe half-updated. The assertion is sound.
impl std::panic::RefUnwindSafe for WebViewHandle {}

#[rustler::resource_impl]
impl Resource for WebViewHandle {}

fn err(msg: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(format!("{}", msg)))
}

/// The page-side convenience: `bl.send(x)` posts `x` (stringified) back to
/// beam-lisp. Injected before any page script runs, so a page can rely on it.
const INIT_SCRIPT: &str = r#"
window.bl = window.bl || {};
window.bl.send = function (msg) {
  window.ipc.postMessage(typeof msg === 'string' ? msg : JSON.stringify(msg));
};
"#;


/// `webview_open(pid, title, html, url, width, height, opts…)` → a live handle.
///
/// Exactly one of `html` / `url` carries content; the other is an empty
/// string. `pid` is the beam-lisp process that receives IPC messages as
/// `{:wry-ipc, body}`. The trailing options shape the window itself:
///
/// - `decorations`   : false → a frameless window (a statusbar wants this)
/// - `always_on_top`  : true  → floats above other windows (a bar, an overlay)
/// - `resizable`      : whether the user may resize it
/// - `x`, `y`         : initial top-left position; `i64::MIN` means "unset",
///                      so the WM places it (a docked bar passes real coords)
///
/// The window runs on its own thread; this returns as soon as that thread has
/// built the window (or failed to), so `open` is synchronous and fails loudly.
#[rustler::nif(schedule = "DirtyCpu")]
fn webview_open(
    pid: LocalPid,
    title: String,
    html: String,
    url: String,
    width: f64,
    height: f64,
    decorations: bool,
    always_on_top: bool,
    resizable: bool,
    x: i64,
    y: i64,
    layer: i64,
    anchor_mask: i64,
    exclusive: i64,
    transparent: bool,
) -> NifResult<ResourceArc<WebViewHandle>>{
    let win = WindowOpts {
        title,
        html,
        url,
        width,
        height,
        decorations,
        always_on_top,
        resizable,
        pos: if x == i64::MIN || y == i64::MIN {
            None
        } else {
            Some((x as f64, y as f64))
        },
        layer,
        anchor_mask,
        exclusive,
        transparent,
    };

    // The thread reports the outcome of window construction back through this
    // channel: either the proxy (success) or an error string (failure). Making
    // `open` wait for it is what lets a bad build surface as a raised error at
    // the call site instead of a window that silently never appears.
    let (tx, rx) = mpsc::channel::<Result<EventLoopProxy<UserEvent>, String>>();

    let join = std::thread::spawn(move || {
        run_window(pid, win, tx);
    });

    match rx.recv() {
        Ok(Ok(proxy)) => Ok(ResourceArc::new(WebViewHandle {
            proxy,
            join: Mutex::new(Some(join)),
        })),
        Ok(Err(e)) => {
            let _ = join.join();
            Err(err(e))
        }
        // The thread died before reporting — the sender dropped. Join it to
        // surface nothing useful but avoid a leak, then report.
        Err(_) => {
            let _ = join.join();
            Err(err("window thread exited before the window was created"))
        }
    }
}

/// Everything `open` needs to build a window, moved to the loop thread in one
/// value so `run_window` keeps a short signature as options grow.
struct WindowOpts {
    title: String,
    html: String,
    url: String,
    width: f64,
    height: f64,
    decorations: bool,
    always_on_top: bool,
    resizable: bool,
    pos: Option<(f64, f64)>,
    /// wlr-layer-shell layer: 0 = none (an ordinary xdg_toplevel), 1 = top,
    /// 2 = overlay. A docked bar wants `top`; an overlay HUD wants `overlay`.
    layer: i64,
    /// Screen edges to anchor to, as a bitmask: 1=top 2=bottom 4=left 8=right.
    /// Anchoring two opposite edges stretches the surface along that axis — a
    /// top bar is top|left|right = 13.
    anchor_mask: i64,
    /// Exclusive zone in px (the strip the compositor reserves so other windows
    /// don't overlap the bar). `i64::MIN` = auto (reserve the window's own size
    /// along its anchored edge). Any other value is used literally; 0 disables.
    exclusive: i64,
    /// Whether the window + webview are transparent (for a glassmorphic bar the
    /// compositor shows through the translucent CSS blocks).
    transparent: bool,
}

/// The entire life of one window, running on its own OS thread.
fn run_window(
    pid: LocalPid,
    win: WindowOpts,
    tx: mpsc::Sender<Result<EventLoopProxy<UserEvent>, String>>,
){
    // Build the loop off the main thread (legal: this thread owns it for life).
    let mut event_loop = match std::panic::catch_unwind(|| {
        EventLoopBuilder::<UserEvent>::with_user_event()
            .with_any_thread(true)
            .build()
    }) {
        Ok(el) => el,
        Err(_) => {
            let _ = tx.send(Err("could not create the event loop (no display?)".into()));
            return;
        }
    };

    let mut wb = WindowBuilder::new()
        .with_title(&win.title)
        .with_inner_size(tao::dpi::LogicalSize::new(win.width, win.height))
        .with_decorations(win.decorations)
        .with_always_on_top(win.always_on_top)
        .with_resizable(win.resizable)
        // a transparent tao window sets up the rgba visual GTK needs so the
        // compositor can show through the translucent CSS (glassmorphism).
        .with_transparent(win.transparent)
        // Build HIDDEN so the window is not mapped yet: wlr-layer-shell must be
        // initialised BEFORE the surface maps (gtk_layer_init_for_window
        // asserts the widget is unmapped). We show it explicitly further down,
        // after layer-shell + the webview are set up. As a bonus this removes
        // the brief flash of an unstyled window.
        .with_visible(false);
    if let Some((px, py)) = win.pos {
        wb = wb.with_position(tao::dpi::LogicalPosition::new(px, py));
    }
    let window = match wb.build(&event_loop) {
        Ok(w) => w,
        Err(e) => {
            let _ = tx.send(Err(format!("could not create the window: {e}")));
            return;
        }
    };

    // ── wlr-layer-shell + transparency, on the underlying gtk window ──────
    //
    // This is the whole fix for "the bar floats instead of docking". A
    // scrollable-tiling / wlroots compositor (niri, sway, hyprland) ignores
    // X11-isms (always-on-top, absolute x/y) and makes a normal toplevel it
    // places itself. wlr-layer-shell is the protocol that actually pins a
    // surface to a screen edge, keeps it above tiled windows, and reserves its
    // strip. All of this MUST be set before the window maps, which is why it
    // happens here, right after build and before the webview/first paint.
    let gtk_win = window.gtk_window();

    if win.transparent {
        // Give the gtk window an rgba visual and let it paint its own (empty)
        // background, so the parts the CSS leaves translucent are genuinely
        // see-through rather than filled with the theme's window colour.
        gtk_win.set_app_paintable(true);
        if let Some(screen) = GtkWindowExt::screen(gtk_win) {
            if let Some(visual) = screen.rgba_visual() {
                gtk_win.set_visual(Some(&visual));
            }
        }
    }

    if win.layer != 0 {
        // only meaningful on a compositor that implements the protocol; on X11
        // or an unsupported compositor this is a graceful no-op.
        if gtk_layer_shell::is_supported() {
            gtk_win.init_layer_shell();
            gtk_win.set_layer(match win.layer {
                2 => Layer::Overlay,
                _ => Layer::Top,
            });
            let m = win.anchor_mask;
            gtk_win.set_anchor(Edge::Top, m & 1 != 0);
            gtk_win.set_anchor(Edge::Bottom, m & 2 != 0);
            gtk_win.set_anchor(Edge::Left, m & 4 != 0);
            gtk_win.set_anchor(Edge::Right, m & 8 != 0);
            // reserve the strip so tiled windows do not sit under the bar.
            if win.exclusive == i64::MIN {
                gtk_win.auto_exclusive_zone_enable();
            } else {
                gtk_win.set_exclusive_zone(win.exclusive as i32);
            }
            gtk_win.set_namespace("beam-lisp");
        }
    }

    // IPC: every window.ipc.postMessage lands here, on a wry-internal thread.
    // Deliver it to the beam-lisp receiver as {:wry-ipc, body}.
    let ipc_pid = pid;
    let ipc_handler = move |req: wry::http::Request<String>| {
        let body = req.into_body();
        let mut msg_env = OwnedEnv::new();
        let _ = msg_env.send_and_clear(&ipc_pid, |env| {
            (rustler::types::atom::Atom::from_str(env, "wry-ipc").unwrap(), body).encode(env)
        });
    };

    let mut builder = WebViewBuilder::new()
        .with_initialization_script(INIT_SCRIPT)
        .with_ipc_handler(ipc_handler)
        // a transparent webview lets the page's translucent CSS reveal the
        // gtk window (and thus the compositor) behind it.
        .with_transparent(win.transparent);

    builder = if !win.html.is_empty() {
        builder.with_html(&win.html)
    } else {
        builder.with_url(&win.url)
    };

    // build_gtk on the window's default gtk container is the Wayland-safe path
    // (a bare `build` supports X11 only). tao adds a vbox to every window; we
    // host the webview in it.
    let vbox = match window.default_vbox() {
        Some(v) => v,
        None => {
            let _ = tx.send(Err("window has no gtk container to host the webview".into()));
            return;
        }
    };

    let webview = match builder.build_gtk(vbox) {
        Ok(wv) => wv,
        Err(e) => {
            let _ = tx.send(Err(format!("could not create the webview: {e}")));
            return;
        }
    };

    // Everything (layer-shell anchors, rgba visual, the webview) is configured
    // on the still-unmapped window; NOW map it. show_all reveals the window and
    // its child webview in one shot, as a layer surface when so configured.
    gtk_win.show_all();

    // Handshake complete: hand the proxy back so `open` can return. From here
    // the thread only pumps the loop.
    if tx.send(Ok(event_loop.create_proxy())).is_err() {
        return; // opener gave up; nothing to drive.
    }

    // Keep the webview AND the window alive for the loop's lifetime. The window
    // must move into the closure so `Resize` can call set_inner_size on it.
    let _webview = webview;
    let _window = window;

    event_loop.run_return(move |event, _target, control_flow| {
        *control_flow = ControlFlow::Wait;
        match event {
            Event::UserEvent(UserEvent::Eval(js)) => {
                let _ = _webview.evaluate_script(&js);
            }
            Event::UserEvent(UserEvent::Resize(w, h)) => {
                // Grow/shrink the surface — how a bar hosts a dropdown. Two
                // regimes, because a wlr-layer-shell surface and a plain xdg
                // toplevel are sized differently:
                let gw = _window.gtk_window();
                if gw.is_layer_window() {
                    // A layer surface does NOT follow tao's set_inner_size (that
                    // drives the xdg toplevel, which this is not). Its height
                    // comes from the GTK window's size REQUEST. The header's
                    // incantation: set the request (width -1 — a left+right
                    // anchored bar's width is stretched by the anchors and its
                    // request along that axis ignored), then resize(1,1) to make
                    // the window adopt it. Some compositors (niri) only read a
                    // layer surface's size at MAP time, so hide+show re-commits
                    // it — the webview and its JS state survive the remap; only
                    // the surface re-commits, so there is no reload or flash.
                    gw.set_size_request(-1, h as i32);
                    gw.resize(1, 1);
                    gw.hide();
                    gw.show_all();
                } else {
                    // A plain window resizes the ordinary way.
                    _window.set_inner_size(tao::dpi::LogicalSize::new(w, h));
                }
            }
            Event::UserEvent(UserEvent::Close) => {
                *control_flow = ControlFlow::Exit;
            }
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                *control_flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
    // run_return has returned: the window is gone, the thread unwinds, the
    // BEAM node is untouched.
}

/// `webview_eval(handle, js)` → `true`. Runs `js` in the window's page.
///
/// Fire-and-forget: the event is queued on the window's loop and this returns
/// at once. A dead window (already closed) makes the send fail, which we
/// surface as an error rather than a silent no-op.
#[rustler::nif]
fn webview_eval(handle: ResourceArc<WebViewHandle>, js: String) -> NifResult<bool> {
    handle
        .proxy
        .send_event(UserEvent::Eval(js))
        .map_err(|_| err("window is closed"))?;
    Ok(true)
}
/// `webview_resize(handle, width, height)` → `true`. Resizes the surface.
///
/// For a layer-shell bar this is how a dropdown works: grow the surface tall
/// enough to hold the open panel, shrink it back on close. Fire-and-forget,
/// like `eval`.
#[rustler::nif]
fn webview_resize(
    handle: ResourceArc<WebViewHandle>,
    width: f64,
    height: f64,
) -> NifResult<bool> {
    handle
        .proxy
        .send_event(UserEvent::Resize(width, height))
        .map_err(|_| err("window is closed"))?;
    Ok(true)
}
/// `webview_close(handle)` → `true`. Closes the window and waits for its
/// thread to unwind, so a caller that closes then exits sees a clean teardown.
#[rustler::nif(schedule = "DirtyCpu")]
fn webview_close(handle: ResourceArc<WebViewHandle>) -> NifResult<bool> {
    // Best-effort: if the window already closed itself (user hit X), the send
    // fails and there is simply nothing to tear down.
    let _ = handle.proxy.send_event(UserEvent::Close);
    if let Ok(mut guard) = handle.join.lock() {
        if let Some(j) = guard.take() {
            let _ = j.join();
        }
    }
    Ok(true)
}

/// Marker the loader flips from stub to real once the NIF is in. Lets
/// `BeamLisp.Native.available?` tell a built backend from an absent one.
#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}

// Host module must match what `BeamLisp.Native.host_module("wry")` derives:
// `BeamLisp.Native.Wry`. The resource is registered in `load`.
fn load(env: Env, _info: Term) -> bool {
    env.register::<WebViewHandle>().is_ok()
}

rustler::init!("Elixir.BeamLisp.Native.Wry", load = load);
