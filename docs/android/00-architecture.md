# beam-lisp on Android

A beam-lisp Android app is an ordinary Android app with a BEAM inside it. The
BEAM runs your namespaces; the phone's APIs are values you call from them; the
desk reaches the phone over Erlang distribution. There is no Mix and no Elixir
to write.

```
 desk (bl)                                phone (one process)
 ─────────                                ───────────────────
 bl android dev ──build/push──────────▶   lib<app>.so   = erts + mob launcher + bl NIF
 bl android eval '(…)' ──dist──────────▶  BEAM
 bl android repl                            ├─ beam-lisp runtime (BeamLisp.init)
                                            ├─ your namespaces (AOT beams)
                                            ├─ mob: screens, renderer, Compose
                                            └─ android.* : jvm · notify · reader · overlay
                                         JVM
                                            ├─ Compose UI (mob MobBridge)
                                            ├─ BlBridge   : reflection over ANY Java API
                                            ├─ BlNotificationListener (NotificationListenerService)
                                            ├─ BlReader   (AccessibilityService: read any screen)
                                            └─ BlOverlay  (SYSTEM_ALERT_WINDOW: draw over any screen)
```

## Why mob, and what beam-lisp adds

[mob](https://hexdocs.pm/mob) already puts OTP on the phone: prebuilt per-ABI
runtimes, a launcher that links erts into the app's own `.so`, a Compose renderer
fed by plain maps, and distribution to the desk. beam-lisp takes all of it —
from hex, compiled by `bl deps`, no fork — and adds three things mob does not
have:

1. **Every Android API, without writing Kotlin.** `android.jvm` is a reflection
   bridge: `(jvm/call obj "getSystemService" "notification")`,
   `(jvm/new "android.app.NotificationChannel" "id" "name" 3)`. Java objects live
   in a handle table on the JVM side and cross into the BEAM as small maps;
   callbacks come back as messages.
2. **The three capabilities that need a system service**: listening to every
   notification (`android.notify`), reading any app's screen through
   accessibility (`android.reader`), drawing over any app (`android.overlay`).
   They are Android `Service`s shipped with beam-lisp and declared into the
   manifest by the build.
3. **Tooling in beam-lisp.** `bl android …` replaces `mix mob.*`: it renders
   mob's own templates, runs zig and gradle, installs, pushes beams, connects
   distribution and evaluates forms on the phone.

## Why not wry

wry is a webview library. On Android it needs a Rust shell (cargo-mobile2) and
gives a WebView, not a BEAM: beam-lisp would still need its own embedded OTP,
its own JNI bridge and a renderer. The hard parts of *this* problem — OTP on the
device, a native bridge, packets to the desk — are the parts mob already solved.
A webview remains available inside a mob screen (`:webview` node) when a page is
the right surface.

## The boundary, in one sentence

The BEAM never blocks the UI thread and the JVM never calls into BEAM code: the
BEAM calls the JVM through NIFs (a JSON request on a dirty scheduler, answered
synchronously), and the JVM talks to the BEAM only by **sending messages** to a
registered process.
