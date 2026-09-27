# Your first beam-lisp app on a phone

Ten minutes, most of them gradle's.

## What you need

```
bl android doctor
```

checks for the Android SDK, NDK 27.2, JDK 21, the pinned zig, mob's OTP
runtime, and exactly one device (an emulator is fine). Each missing piece is a
line with the path it looked for. `ANDROID_HOME` and `BL_ANDROID_JAVA_HOME`
override the defaults.

## Make an app

```
bl android new hello
cd hello
```

That writes four files:

```
env.bl                 the app: its name, its deps, its :android block
src/hello/app.bl       the app namespace: which screens exist, which comes first
src/hello/home.bl      a screen with a counter
.gitignore             _build/
```

`env.bl` is where the phone app is declared:

```clojure
{:name "hello"
 :paths ["src"]
 :deps [{:name "mob" :vsn "~> 0.9.3"}]
 :android {:app "hello" :label "Hello"}}
```

`:android` also takes `:id` (the application id, default
`org.beamlisp.<app>`), `:ns` (the app namespace, default `<app>.app`) and
`:abi` (default `x86_64`, the emulator's).

## Bring in mob

```
bl deps lock      # resolve :deps against hex → bl.lock
bl deps fetch     # download what the lock names
bl deps compile   # compile it for this runtime
```

## Build, install, run

```
bl android build      # APK: mob's templates + beam-lisp's layer, zig, gradle
bl android install    # onto the device
bl android push       # OTP + beam-lisp + mob + your code → the app's files/
bl android up         # launch, and join the phone as a node
```

The screen shows a title, a count and a button. Tap it and the count moves.

## Talk to it

```
bl android eval '(+ 1 2)'                     ; → 3, computed on the phone
bl android eval '(android.jvm/sdk-int)'       ; → the phone's API level
bl android eval '(android.reader/screen-text)' ; after `grant reader`
```

`eval` is an Erlang RPC: the desk and the phone are two nodes, and anything
you can send between nodes, you can send between them.

## The loop

After changing a `.bl` file:

```
bl android push && bl android up
```

`push` recompiles your namespaces on the desk and replaces the phone's
`files/`; the APK only changes when mob, the Kotlin layer, or `:android`
changes.

## Grants

Three capabilities are grants a person makes in Settings. On a development
device the shell makes them for you:

```
bl android grant all        # or: listener · reader · overlay · notify
```

`up` restores the reader grant, which a restart revokes.

## Screens, logs, shots

```
bl android shot home.png    # what the screen shows now
bl android logs             # the app's log (the BEAM's output is tagged BEAMout)
bl android stop
```

## Testing

A screen's `render` is a function of its assigns, and `android.ui` builds
plain data, so most of an app is tested on the desk with `bl test`. For the
rest, a beam-lisp program can drive the phone: `bl.android/rpc` calls into it,
`bl.android/adb!` drives the device, and `android.reader` reads back what a
person would see. `phone/test/e2e.bl` in the `system` repository is a complete
example: it posts stub notifications and checks the screen, the model and the
overlay agree.
