# beam-lisp on Android

A beam-lisp Android app is an ordinary Android app with a BEAM inside it. The
BEAM runs your namespaces; the phone's APIs are values you call from them; the
desk reaches the phone over Erlang distribution. There is no Mix and no Elixir
to write.

```
 desk (bl)                                 phone (one process)
 ─────────                                 ───────────────────
 bl android build ─ zig + gradle ─▶ APK    lib<app>.so = erts + mob launcher + bl_android_nif
 bl android push  ─ adb ──────────▶ files/ BEAM
 bl android up / eval ─ distribution ─▶      ├─ beam-lisp (compiler + runtime)
                                             ├─ your namespaces (compiled on the desk)
                                             ├─ mob: screens, renderer
                                             └─ android.* : app · screen · ui · events
                                                            jvm · notify · reader · overlay
                                           JVM
                                             ├─ Compose UI (mob's MobBridge)
                                             ├─ BlBridge   reflection over any Java API
                                             ├─ BlNotificationListener   every notification
                                             ├─ BlReader   accessibility: read any screen
                                             └─ BlOverlay  draw over any screen
```

## mob underneath

[mob](https://hex.pm/packages/mob) puts OTP on the phone: a cross-compiled
runtime per ABI, a launcher that starts the BEAM inside the app's own process,
a Compose renderer fed by plain maps, and distribution to the desk. beam-lisp
takes it from hex like any library and adds three things:

1. **Every Android API, without writing Kotlin.** `android.jvm` reaches the
   whole platform by reflection. Java objects stay in the JVM; beam-lisp holds
   small maps naming them.
2. **The three capabilities that need a system service**: every notification
   on the phone (`android.notify`), the text of any app's screen
   (`android.reader`), cards drawn over any app (`android.overlay`).
3. **Tooling in beam-lisp.** `bl android …` renders mob's own templates, links
   with zig, packages with gradle, installs, pushes, and evaluates forms on the
   phone.

## A namespace is a screen

mob drives a screen by calling functions on a module — `mount`, `render`,
`handle_info` and seven more. A beam-lisp namespace compiles to a module that
exports its `defn`s under their own names, so a namespace *is* a screen.
`(defscreen)` supplies all ten with defaults; you write the ones you need. The
UI is plain data built by `android.ui`, so `render` is a function you can call
on the desk.

The app is a namespace too: `navigation` says which screens exist, `on-start`
mounts the first one. `android.app/start!` boots mob with that namespace as the
app module.

## The boundary, in one sentence

The BEAM never blocks the UI thread and the JVM never calls into BEAM code:
the BEAM calls the JVM through a NIF (a JSON request on a dirty scheduler,
answered synchronously), and the JVM talks to the BEAM only by **sending
messages** to the process registered as `android_events`.

Four rules keep that seam honest:

- **UTF-8 bytes cross JNI, not Java strings.** JNI strings are modified
  UTF-8, which mangles emoji.
- **Nothing calls into ERTS before the NIF has loaded.** Services start before
  the BEAM; their events wait in `BlBridge` until the router starts and flushes
  them.
- **A re-entrant emit uses its caller's env.** When JVM code that runs inside
  `bl_android_nif:call` emits, the NIF passes the dirty scheduler's env along.
- **Classes resolve through the app's class loader**, never the
  Application's own class, which the boot loader owns.

## Where things live

| path | what |
|---|---|
| `priv/lib/android/*.bl` | the `android.*` namespaces (compiled onto the phone by `push`) |
| `priv/android/kotlin/` | `BlBridge.kt`, `BlServices.kt` (copied into the app by `build`) |
| `priv/android/jni/bl_android_nif.c` | the NIF, linked into `lib<app>.so` |
| `priv/android/erl/bl_android_nif.erl` | its Erlang stubs (answer `not_on_android` on the desk) |
| `priv/android/manifest.xml`, `res/` | the permissions, services and strings merged into the app |
| `priv/std/bl/android.bl.md` | the `bl android` verbs |

Next: [01-getting-started](01-getting-started.md) builds an app;
[02-namespaces](02-namespaces.md) is the reference.
