# bl.android — a phone app, from a beam-lisp tree, with no Mix

`bl android` takes a tree whose `env.bl` names an Android app and turns it into
an app on a phone. The app runs on [mob](https://hex.pm/packages/mob): an
Android host built around a real BEAM, a JNI bridge, and a Compose renderer.
beam-lisp adds two things on top: its own language on the device, and a
reflection bridge that reaches every Android API.

```
bl android doctor           what this machine has, and what it lacks
bl android new NAME         a tree: env.bl, an app namespace, a first screen
bl android build [--standalone] [--release]  native lib + APK, optionally self-contained
bl android install          put the APK on the phone
bl android push             beams + runtime onto the phone (no reinstall)
bl android up               launch with distribution; ready for eval
bl android eval EXPR        run beam-lisp ON the phone, print the answer
bl android grant WHAT       listener | reader | overlay | notify | all
bl android shot [FILE]      a screenshot, as PNG
bl android logs             the app's log, filtered
bl android stop             stop the app
bl android devtools [PORT]  the WebView's pages over Chrome DevTools
```

`build` then `install`, `push`, `up` is the whole loop the first time. After a
change to beam-lisp code only `push` and `up` are needed: the APK carries the
native host, and the phone's `files/` carries everything the BEAM loads.

`bl android build --standalone --release` bundles those files inside the APK.
The launcher verifies and installs the bundle before starting BEAM. Bundle
upgrades replace `files/otp/` and preserve the app's other private data.
`--release` disables development distribution; sign the resulting release APK
with an Android signing key before distributing it. The standalone debug build
is available with `--standalone` alone.

The tree declares its app in `env.bl`:

```clojure
{:name "people"
 :paths ["src"]
 :deps [{:name "mob" :vsn "~> 0.9.3"}]
 :android {:app "people"             ; OTP app name, lowercase
           :ns "people.app"          ; the app namespace (navigation, on-start)
           :id "org.example.people"  ; the Android application id
           :label "People"}}         ; the launcher label
```

`bl deps lock` / `fetch` / `compile` bring mob in from hex like any library.

```beam-lisp
(ns bl.android
  (:require [bl.util :as u] [bl.env :as env]))
```

## Where things are

Every path the verbs touch is computed here, once. A host that keeps the SDK
somewhere else says so through the environment; nothing else is configurable,
because nothing else needs to be.

```beam-lisp
(def otp-hash "5c9c69fc")
(def zig-version "0.17.0-dev.269+ebff43698")
(def ndk-version "27.2.12479018")
(def dist-port 9100)
(def cookie "mob_secret")

(defn- home [] (System/user_home))
(defn- env-or [k default] (or (System/get_env k) default))

(defn priv
  "beam-lisp's own priv/, where the Android layer (Kotlin, NIF, manifest) ships."
  []
  (erlang/list_to_binary (code/priv_dir :beam_lisp)))

(defn sdk [] (env-or "ANDROID_HOME" (Path/join (home) "Android/Sdk")))
(defn ndk [] (Path/join (list (sdk) "ndk" ndk-version)))
(defn adb [] (Path/join (list (sdk) "platform-tools" "adb")))
(defn java-home [] (env-or "BL_ANDROID_JAVA_HOME" "/usr/lib/jvm/java-21-openjdk"))
(defn zig [] (Path/join (list (home) ".cache/beam_lisp/toolchains"
                              (str "zig-x86_64-linux-" zig-version) "zig")))
(defn otp-dir [abi]
  (Path/join (list (home) ".mob/cache"
                   (if (= abi "x86_64") (str "otp-android-x86_64-" otp-hash) (str "otp-android-" otp-hash)))))
(defn otp-url [abi]
  (str "https://github.com/GenericJam/mob/releases/download/otp-" otp-hash "/"
       (Path/basename (otp-dir abi)) ".tar.gz"))
```

## The target

`target` reads the tree's `env.bl` and answers everything a verb needs to know
about the app: names in every spelling the templates use, where its build
lives, which libraries it carries. A tree without `:android` is not an app, and
every verb says so the same way.

```beam-lisp
(defn- camel [s] (join "" (vec (map (fn [w] (str (upper-case (subs w 0 1)) (subs w 1)))
                                    (split s "_")))))

(defn target
  "The app this tree declares, or `{:error msg}`."
  [dir]
  (let [p (env/project dir)
        a (:android p)]
    (cond
      (nil? (:path p)) {:error (str "no env.bl at or above " dir)}
      (seq (:errors p)) {:error (str (:path p) ": " (join "; " (vec (:errors p))))}
      (nil? a) {:error (str (:path p) " declares no :android app")}
      :else
      (let [app (:app a)
            id (:id a)
            b (Path/join (:root p) "_build/android")]
        {:root (:root p)
         :paths (:paths p)
         :app app
         :ns (:ns a)
         :id id
         :label (or (:label a) (camel app))
         :abi (:abi a)
         :module (camel app)
         :jni (join "_" (vec (split (join "_1" (vec (split id "_"))) ".")))
         :build b
         :android (Path/join b "android")
         :stage (Path/join b "stage")}))))
```

`:android` is an `env.bl` key like `:deps` (see [env](env.bl.md)): its
defaults are applied there, so every reader of the tree agrees on them.

## Running things

Every external tool runs through `sh`, which answers data: the exit status,
the output, and the command line it ran. A build step that fails is a message
naming the step and the tail of its output — never a stack trace through here.

```beam-lisp
(defn sh
  "Run `cmd` with `args` (strings). `{:ok? :status :out :cmd}`. `opts`:
   `:cd` a directory, `:env` a map of extra environment."
  ([cmd args] (sh cmd args {}))
  ([cmd args opts]
   (let [o (concat (list (tuple :stderr_to_stdout true))
                   (if (:cd opts) (list (tuple :cd (:cd opts))) (list))
                   (if (:env opts)
                     (list (tuple :env (apply list (map (fn [[k v]] (tuple k v)) (:env opts)))))
                     (list)))
         r (System/cmd cmd (apply list args) (apply list o))]
     {:ok? (= 0 (erlang/element 2 r))
      :status (erlang/element 2 r)
      :out (erlang/element 1 r)
      :cmd (join " " (vec (cons cmd args)))})))

(defn- tail [s n]
  (let [ls (split (str s) "\n")]
    (join "\n" (vec (drop (max 0 (- (count ls) n)) ls)))))

(defn step!
  "Run one build step; throw a readable failure when it fails."
  [label cmd args opts]
  (println (str "  · " label))
  (let [r (sh cmd args opts)]
    (when-not (:ok? r)
      (throw (ex-info (str label " failed (" (:status r) ")\n  $ " (:cmd r) "\n" (tail (:out r) 25))
                      {:step label})))
    r))

(defn adb!
  "adb against the one device (or `ANDROID_SERIAL`)."
  [& args]
  (sh (adb) (vec args)))
```

## doctor

```beam-lisp
(defn- have [label ok? detail] {:name label :ok ok? :detail detail})

(defn checks []
  [(have "Android SDK" (File/dir? (sdk)) (sdk))
   (have (str "NDK " ndk-version) (File/dir? (ndk)) (ndk))
   (have "adb" (File/exists? (adb)) (adb))
   (have "JDK 21" (File/exists? (Path/join (java-home) "bin/java")) (java-home))
   (have (str "zig " zig-version) (File/exists? (zig)) (zig))
   (have "mob OTP runtime (x86_64)" (File/dir? (otp-dir "x86_64")) (otp-dir "x86_64"))
   (let [r (adb! "devices")
         n (count (filter (fn [l] (ends-with? l "\tdevice")) (split (str (:out r)) "\n")))]
     (have "a device" (= 1 n) (str n " attached")))])

(defn doctor [_t st]
  (let [cs (checks)]
    (u/emit st cs (fn [cs] (join "\n" (vec (map (fn [c] (str (if (:ok c) "  ok   " "  MISS ") (:name c) "  " (:detail c))) cs)))))
    (if (every? :ok cs) 0 1)))
```

## new

A new app is three files: the `env.bl` that declares it, an app namespace, and
one screen. Enough to build, install and see something the first time; small
enough to read in a minute.

```beam-lisp
(defn- app-source [app]
  (str "(ns " app ".app\n"
       "  \"The " app " app: what the phone boots.\"\n"
       "  (:require [android.app :as app]\n"
       "            [" app ".home]))\n\n"
       "(defn navigation [_platform] (app/stack :home '" app ".home))\n\n"
       "(defn on-start [] (app/start-root! '" app ".home))\n"))

(defn- home-source [app label]
  (str "(ns " app ".home\n"
       "  \"The first screen.\"\n"
       "  (:require [android.screen :refer [defscreen ok noreply]]\n"
       "            [android.app :as app]\n"
       "            [android.ui :as ui]))\n\n"
       "(defscreen)\n\n"
       "(defn mount [_params _session socket] (ok (app/assign socket :taps 0)))\n\n"
       "(defn render [a]\n"
       "  (ui/column {:padding 24 :gap 12 :background :paper}\n"
       "    (ui/text \"" label "\" {:size :xl :color :ink})\n"
       "    (ui/text (str \"taps: \" (:taps a)) {:color :ink-2})\n"
       "    (ui/button \"tap\" [(erlang/self) :tap] {:background :forest})))\n\n"
       "(defn handle_info [msg socket]\n"
       "  (if (= msg (tuple :tap :tap))\n"
       "    (noreply (app/assign socket :taps (+ 1 (:taps (app/assigns socket)))))\n"
       "    (noreply socket)))\n"))

(defn new-tree
  "Write a new app tree at `dir` named `app`."
  [dir app]
  (let [label (camel app)
        files {"env.bl" (str "{:name \"" app "\"\n"
                             " :paths [\"src\"]\n"
                             " :deps [{:name \"mob\" :vsn \"~> 0.9.3\"}]\n"
                             " :android {:app \"" app "\" :label \"" label "\"}}\n")
               (str "src/" app "/app.bl") (app-source app)
               (str "src/" app "/home.bl") (home-source app label)
               ".gitignore" "_build/\n"}]
    (doseq [[rel body] files]
      (let [p (Path/join dir rel)]
        (File/mkdir_p! (Path/dirname p))
        (if (File/exists? p)
          (println (str "  keep   " rel))
          (do (File/write! p body) (println (str "  write  " rel))))))
    (println (str "\nnext: cd " dir " && bl deps lock && bl deps fetch && bl deps compile && bl android build"))
    0))
```

## build

The Android project is GENERATED, every build, under `_build/android/android`:
mob's own templates (from the `mob_new` package on hex) rendered with EEx,
then beam-lisp's layer merged in — the reflection bridge, the services, the
manifest entries they need, the NIF in the driver table. Nothing is forked and
nothing is checked in: a new mob release is a new lock line.

### The libraries it needs

`mob_new` (templates) and `exqlite` (its C sources become the SQLite NIF the
host links) are build inputs, not runtime ones — the app never loads them. They
are fetched into the same store `bl deps` uses, pinned here by digest.

```beam-lisp
(def build-inputs
  [{:name "mob_new" :vsn "0.6.0" :sha "1e9f18b9d6603475b4a657f6997bb4c578fb2acada5f43c6cd9c3f75ccebac37" :source :hex}
   {:name "exqlite" :vsn "0.37.0" :sha "a44816dd0d234fba68c47a3609af61d306d24ef517a89bfaee4d6a811792d913" :source :hex}])

(defn- store-dir [e]
  (BeamLisp.Loader/ensure_loaded "store")
  ((BeamLisp.Env/fetch! "store" "dir-for") (:name e) (:vsn e) (:sha e)))

(defn- ensure-input! [e]
  (BeamLisp.Loader/ensure_loaded "hex")
  (BeamLisp.Loader/ensure_loaded "store")
  (when-not ((BeamLisp.Env/fetch! "store" "present?") (:name e) (:vsn e) (:sha e))
    (println (str "  · fetch " (:name e) " " (:vsn e)))
    (let [r ((BeamLisp.Env/fetch! "hex" "install!")
             ((BeamLisp.Env/fetch! "hex" "httpc-transport"))
             e (Path/join (System/tmp_dir) "bl-android-fetch"))]
      (when-not (:ok? r)
        (throw (ex-info (str "cannot fetch " (:name e) ": " (:why r)) {})))))
  (store-dir e))

(defn- locked-dir
  "The store directory of a library the tree's lock names (mob)."
  [t nm]
  (BeamLisp.Loader/ensure_loaded "deps")
  (let [e (first (filter (fn [e] (= nm (:name e))) (:deps ((BeamLisp.Env/fetch! "deps" "read-lock") (:root t)))))]
    (when (nil? e)
      (throw (ex-info (str nm " is not in " (:root t) "/bl.lock — add it to :deps and run bl deps lock") {})))
    (store-dir e)))
```

### The runtime

mob publishes the OTP it cross-compiled for Android as a release asset; it is
downloaded once into `~/.mob/cache` (where mob's own tooling looks too).

```beam-lisp
(defn ensure-otp! [abi]
  (let [dir (otp-dir abi)]
    (when-not (File/dir? (Path/join dir "releases"))
      (let [tgz (Path/join (System/tmp_dir) (str (Path/basename dir) ".tar.gz"))]
        (File/mkdir_p! dir)
        (step! (str "download OTP for " abi) "curl" ["-fL" "-o" tgz (otp-url abi)] {})
        (step! "unpack OTP" "tar" ["xzf" tgz "-C" dir "--strip-components=1"] {})))
    dir))
```

### Rendering mob's templates

The templates take a handful of names; `assigns` spells them the way mob_new
does. Only the Android half is rendered, and the Elixir project files are not:
this tree's code is beam-lisp.

```beam-lisp
(defn assigns [t]
  (list (tuple :app_name (:app t)) (tuple :module_name (:module t))
        (tuple :display_name (:label t)) (tuple :bundle_id (:id t))
        (tuple :java_package (:id t)) (tuple :jni_package (:jni t))
        (tuple :lib_name (join "" (vec (split (:app t) "_"))))
        (tuple :java_path (join "/" (vec (split (:id t) "."))))
        (tuple :ndk_version ndk-version) (tuple :python false) (tuple :blank true)
        (tuple :mob_dep "") (tuple :mob_dev_dep "") (tuple :mob_mishka_dep "")
        (tuple :mob_exs_mob_dir "") (tuple :mob_exs_elixir_lib "")))

(defn- dest-rel [rel t]
  (let [r (String/replace rel "app_name" (:app t))
        r (String/replace r "java/" (str "java/" (join "/" (vec (split (:id t) "."))) "/"))]
    (if (ends-with? r ".eex") (subs r 0 (- (count r) 4)) r)))

(defn- write! [p body]
  (File/mkdir_p! (Path/dirname p))
  (File/write! p body))

(defn render-templates! [t mob-new out]
  (let [troot (Path/join mob-new "priv/templates/mob.new")
        sroot (Path/join mob-new "priv/static/mob.new")
        a (assigns t)]
    (doseq [f (Path/wildcard (Path/join troot "android/**/*.eex") (list (tuple :match_dot true)))]
      (let [rel (Path/relative_to f troot)]
        (when-not (includes? rel "/androidTest/")
          (write! (Path/join out (dest-rel rel t)) (EEx/eval_file f a)))))
    (doseq [f (Path/wildcard (Path/join sroot "android/**/*") (list (tuple :match_dot true)))]
      (when-not (File/dir? f)
        (let [dest (Path/join out (Path/relative_to f sroot))]
          (File/mkdir_p! (Path/dirname dest))
          (File/cp! f dest))))
    (File/chmod! (Path/join out "android/gradlew") 493)))
```

### beam-lisp's layer

Everything mob_new's generator adds outside its templates (plugin stubs, the
launcher icon) and everything beam-lisp adds (bridge, services, NIF) goes in
here. Each edit asserts it landed: a template that moved on is a loud failure,
not an app that silently lacks its bridge.

```beam-lisp
(def plugin-stubs
  {"MobActivityAware.kt" "package io.mob.plugin\nimport android.app.Activity\ninterface MobActivityAware { fun setActivity(activity: Activity) }\n"
   "MobNotifyHub.kt" "package io.mob.plugin\nobject MobNotifyHub {\n    const val CHANNEL_ID = \"mob_notifications\"\n    @Volatile @JvmStatic var notifyPid: Long = 0\n    @Volatile @JvmStatic var pendingToken: String? = null\n}\n"
   "MobPermissionProvider.kt" "package io.mob.plugin\ninterface MobPermissionProvider { fun permissionsFor(cap: String): Array<String>? }\n"
   "MobPluginBootstrap.kt" "package io.mob.plugin\nimport android.app.Activity\nobject MobPluginBootstrap {\n    private val permissionProviders = mutableListOf<MobPermissionProvider>()\n    @JvmStatic fun registerAll(activity: Activity) {}\n    @JvmStatic fun permissionsFor(cap: String): Array<String>? {\n        for (p in permissionProviders) { val r = p.permissionsFor(cap); if (r != null) return r }\n        return null\n    }\n}\n"})

(def icon
  {"res/drawable/ic_launcher_fg.xml" "<vector xmlns:android=\"http://schemas.android.com/apk/res/android\" android:width=\"108dp\" android:height=\"108dp\" android:viewportWidth=\"108\" android:viewportHeight=\"108\">\n  <path android:fillColor=\"#1F2A24\" android:pathData=\"M54,30a24,24 0 1,0 0.1,0z\"/>\n</vector>\n"
   "res/mipmap-anydpi-v26/ic_launcher.xml" "<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">\n  <background android:drawable=\"@color/ic_launcher_bg\"/>\n  <foreground android:drawable=\"@drawable/ic_launcher_fg\"/>\n</adaptive-icon>\n"
   "res/mipmap-anydpi-v26/ic_launcher_round.xml" "<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">\n  <background android:drawable=\"@color/ic_launcher_bg\"/>\n  <foreground android:drawable=\"@drawable/ic_launcher_fg\"/>\n</adaptive-icon>\n"
   "res/values/ic_launcher_bg.xml" "<resources><color name=\"ic_launcher_bg\">#F4EFE6</color></resources>\n"})

(defn- edit!
  "Replace `from` with `to` in file `p`, once; fail when `from` is absent."
  [p from to]
  (let [s (File/read! p)]
    (when-not (includes? s to)
      (when-not (includes? s from)
        (throw (ex-info (str "android: expected text not found in " p ":\n  " from) {})))
      (File/write! p (String/replace s from to (list (tuple :global false)))))))

(defn- between [s a b]
  (let [i (+ (index-of s a) (count a))]
    (subs s i (index-of s b))))

(defn layer! [t out]
  (let [bl-android (Path/join (priv) "android")
        main (Path/join out "android/app/src/main")
        pkg (Path/join main "java/io/beamlisp/android")]
    (doseq [[f body] plugin-stubs] (write! (Path/join (list main "java/io/mob/plugin" f)) body))
    (doseq [[f body] icon] (write! (Path/join main f) body))
    (doseq [f (Path/wildcard (Path/join bl-android "kotlin/*.kt"))]
      (write! (Path/join pkg (Path/basename f)) (File/read! f)))
    (doseq [f (Path/wildcard (Path/join bl-android "res/**/*.xml"))]
      (write! (Path/join main (str "res/" (Path/relative_to f (Path/join bl-android "res")))) (File/read! f)))
    (let [frag (File/read! (Path/join bl-android "manifest.xml"))
          mf (Path/join main "AndroidManifest.xml")]
      (edit! mf "    <application" (str (between frag "<bl-permissions>" "</bl-permissions>") "    <application"))
      (edit! mf "    </application>" (str (between frag "<bl-components>" "</bl-components>") "    </application>")))
    (edit! (Path/join (list main "java" (join "/" (vec (split (:id t) "."))) "MainActivity.kt"))
           "        nativeSetActivity(this)\n"
           "        nativeSetActivity(this)\n        io.beamlisp.android.BlBridge.attach(this)\n")
    ; One ABI: the native lib is built for exactly one, and a filter naming
    ; others sends gradle's CMake step after libs that do not exist.
    (edit! (Path/join out "android/app/build.gradle")
           "ndk { abiFilters 'arm64-v8a', 'armeabi-v7a', 'x86_64' }"
           (str "ndk { abiFilters '" (:abi t) "' }"))
    (write! (Path/join out "android/local.properties")
            (str "sdk.dir=" (sdk) "\n"))))

(defn driver-tab!
  "mob's driver table, with bl_android_nif registered beside mob_nif."
  [mob out]
  (let [src (File/read! (Path/join mob "android/jni/driver_tab_android.zig"))
        dst (Path/join out "driver_tab_android.zig")
        decl "extern fn mob_nif_nif_init() callconv(.c) ?*anyopaque;"
        entry "    .{ .nif_init = mob_nif_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },"]
    (when-not (and (includes? src decl) (includes? src entry))
      (throw (ex-info "android: mob's driver table changed shape — cannot register bl_android_nif" {})))
    (write! dst (-> src
                    (String/replace decl (str decl "\nextern fn bl_android_nif_nif_init() callconv(.c) ?*anyopaque;"))
                    (String/replace entry (str entry "\n    .{ .nif_init = bl_android_nif_nif_init, .is_builtin = 0, .nif_mod = THE_NON_VALUE, .entry = null },"))))
    dst))
```

### Native and APK

```beam-lisp
(defn native! [t mob exqlite otp out]
  (let [jni (Path/join out "android/app/src/main/jni")
        dt (driver-tab! mob (:build t))]
    ; build.zig copies the linked libs INTO jniLibs/<abi>/ and does not make it.
    (File/mkdir_p! (Path/join (list out "android/app/src/main/jniLibs" (:abi t))))
    ; The BEAM execs three ERTS helpers. An app may only exec files the
    ; installer extracted from its APK, so they ride along as lib<name>.so and
    ; mob's launcher symlinks them into erts/bin at boot.
    (doseq [exe ["erl_child_setup" "inet_gethost" "epmd"]]
      (File/cp! (Path/join (list otp "erts-17.0/bin" exe))
                (Path/join (list out "android/app/src/main/jniLibs" (:abi t) (str "lib" exe ".so")))))
    (step! "native lib (zig)" (zig)
           ["build" "native-lib" "--build-file" (Path/join jni "build.zig")
            "--prefix" (Path/join out "android/app/build/zig-out")
            (str "-Dabi=" (:abi t)) (str "-Dotp_dir=" otp) "-Derts_vsn=erts-17.0"
            (str "-Dmob_dir=" mob) (str "-Ddriver_tab=" dt) (str "-Dproject_jni_dir=" jni)
            (str "-Dndk_sysroot=" (Path/join (ndk) "toolchains/llvm/prebuilt/linux-x86_64/sysroot"))
            (str "-Dapp_name=" (:app t)) (str "-Dproject_root=" out)
            (str "-Dexqlite_src=" (Path/join exqlite "c_src"))
            (str "-Dplugin_c_nifs=" (Path/join (priv) "android/jni/bl_android_nif.c"))]
           {:cd (Path/join out "android")})))

(declare stage!)

(defn bundle! [t out]
  (let [st (stage! t)
        assets (Path/join out "android/app/src/main/assets")
        archive (Path/join assets "bl-runtime.zip")]
    (File/mkdir_p! assets)
    (when (File/exists? archive) (File/rm! archive))
    (step! "bundle runtime" "zip" ["-q" "-r" archive "otp" "-x" "*.a" "*.o"
                                    "otp/erts-*/bin/beam.smp"] {:cd st})
    (let [sum (step! "runtime digest" "sha256sum" [archive] {})]
      (File/write! (Path/join assets "bl-runtime.sha256") (first (split (trim (:out sum)) " "))))
    (let [activity (Path/join (list out "android/app/src/main/java"
                         (join "/" (vec (split (:id t) "."))) "MainActivity.kt"))]
      (edit! activity "Thread({ nativeStartBeam() }, \"beam-main\").start()"
        (str "Thread({\n"
             "                try {\n"
             "                    val digest = assets.open(\"bl-runtime.sha256\").bufferedReader().use { it.readText().trim() }\n"
             "                    io.beamlisp.android.BlRuntime.install(filesDir, digest) { assets.open(\"bl-runtime.zip\") }\n"
             "                    nativeStartBeam()\n"
             "                } catch (e: Throwable) {\n"
             "                    android.util.Log.e(\"Beam Lisp\", \"Runtime startup failed\", e)\n"
             "                    runOnUiThread { android.app.AlertDialog.Builder(this)\n"
             "                        .setTitle(\"Could not start app\").setMessage(e.message ?: \"Runtime installation failed\")\n"
             "                        .setPositiveButton(\"Close\") { _, _ -> finish() }.show() }\n"
             "                }\n"
             "            }, \"beam-main\").start()")))))

(defn apk! [out release?]
  ; An absolute path: System.cmd looks a relative command up on PATH, not in :cd.
  (step! "APK (gradle)" (Path/join out "android/gradlew") [(if release? "assembleRelease" "assembleDebug") "--no-daemon" "-q"]
         {:cd (Path/join out "android") :env {"JAVA_HOME" (java-home)}})
  (Path/join out (if release? "android/app/build/outputs/apk/release/app-release-unsigned.apk"
                            "android/app/build/outputs/apk/debug/app-debug.apk")))

(defn build [t _st]
  (println (str "bl android build " (:app t) " (" (:id t) ", " (:abi t) ")"))
  (let [mob (locked-dir t "mob")
        mob-new (ensure-input! (first build-inputs))
        exqlite (ensure-input! (second build-inputs))
        otp (ensure-otp! (:abi t))
        out (:build t)]
    (File/rm_rf! (:android t))
    (println "  · project from mob_new templates")
    (render-templates! t mob-new out)
    (layer! t out)
    (when (:release? t)
      (edit! (Path/join (list out "android/app/src/main/java"
                            (join "/" (vec (split (:id t) "."))) "MainActivity.kt"))
             "        nativeSetActivity(this)\n"
             "        android.system.Os.setenv(\"MOB_RELEASE\", \"1\", true)\n        nativeSetActivity(this)\n"))
    (native! t mob exqlite otp out)
    (when (:standalone? t) (bundle! t out))
    (let [apk (apk! out (:release? t))]
      (println (str "  ✓ " apk))
      0)))
```

## push — what the BEAM on the phone loads

The APK carries the native host and nothing else the BEAM reads. Everything
the BEAM loads lives in the app's `files/otp/`, pushed there by `push`: the OTP
runtime, beam-lisp, the tree's libraries, and the tree's own code, compiled on
the desk. A push replaces all of it, so the phone never runs a mix of builds.

The staged beam-lisp `.app` names only applications the phone has: the desk's
names desk-only ones (a web server, a dataframe library) that the phone
neither ships nor needs, and OTP refuses to start an application whose
dependencies are missing.

```beam-lisp
(defn- lib-dir [app] (erlang/list_to_binary (code/lib_dir app)))

(defn- copy-tree!
  "Copy directory `from`'s contents into `to`, FOLLOWING symlinks: a checkout's
   beam-lisp ebin is a link to its build dir, and the phone needs the files."
  [from to]
  (File/mkdir_p! to)
  (step! (str "copy " (Path/basename from)) "cp" ["-rL" (str from "/.") to] {}))

(defn- app-name-of
  "`kernel-11.0` → \"kernel\"; `elixir` → \"elixir\" (mob ships some unversioned)."
  [dir-name]
  (let [i (index-of dir-name "-")] (if (nil? i) dir-name (subs dir-name 0 i))))

(defn- device-app-file!
  "beam-lisp's .app with `applications` cut to what `lib` holds."
  [src dst lib]
  (let [present (set (map app-name-of (File/ls! lib)))
        r (erlang/apply :file :consult (list (erlang/binary_to_list src)))
        term (erlang/hd (erlang/element 2 r))
        nm (erlang/element 2 term)
        props (erlang/element 3 term)
        keep (fn [k] (apply list (filter (fn [a] (contains? present (name a)))
                                         (proplists/get_value k props (list)))))
        rest- (filter (fn [p] (not (contains? #{:applications :optional_applications} (erlang/element 1 p))))
                      props)
        props (apply list (concat [(tuple :applications (keep :applications))
                                   (tuple :optional_applications (keep :optional_applications))]
                                  rest-))]
    (File/write! dst (erlang/iolist_to_binary (io_lib/format "~tp.~n" (list (tuple :application nm props)))))))

(defn- boot-module!
  "The Erlang entry mob's launcher runs (`-eval '<app>:start().'`)."
  [t dir]
  (let [src (Path/join dir (str (:app t) ".erl"))
        mod (str (BeamLisp.Emit/module_for (:ns t)))]
    (File/write! src
      (str "-module(" (:app t) ").\n-export([start/0]).\n"
           "%% Generated by bl android. The BEAM's first call: start OTP and\n"
           "%% beam-lisp, then hand over to the app namespace " (:ns t) ".\n"
           "start() ->\n"
           "    {ok, _} = application:ensure_all_started(beam_lisp),\n"
           "    ok = 'Elixir.BeamLisp':init(),\n"
           "    '" mod "':'__bl_init__'(),\n"
           "    'Elixir.BeamLisp.Ns.Android.App':'start!'('" (:ns t) "', " (:app t) "),\n"
           "    timer:sleep(infinity).\n"))
    (step! "boot module" "erlc" ["-o" dir src] {})
    (File/rm! src)))

(defn native-lazy-memo
  "beam-lisp's one required native, built for the phone's ABI. Cargo builds it
   with the NDK linker; see docs/android."
  [abi]
  (let [p (Path/join (list (env-or "CARGO_TARGET_DIR" (Path/join (home) ".cache/cargo-target"))
                           (str (if (= abi "arm64-v8a") "aarch64" abi) "-linux-android") "release/liblazy_memo.so"))]
    (when-not (File/exists? p)
      (throw (ex-info (str "no lazy_memo for " abi " at " p
                           " — cargo build --release --target " abi "-linux-android -p lazy_memo") {})))
    p))

(defn compile!
  "AOT-compile the `.bl` under `roots` on the desk into `out`. The phone carries
   no sources: a namespace it has no beam for is a namespace it cannot load."
  [label roots out]
  (println (str "  · compile " label))
  (BeamLisp.Loader/ensure_loaded "build")
  (let [sources (vec (mapcat u/expand-targets roots))
        r ((BeamLisp.Env/fetch! "build" "run") {:sources sources :out out :force? true})]
    (when (seq (:errors r))
      (throw (ex-info (str label ": compile failed: " (pr-str (first (:errors r)))) {})))
    out))

(defn compile-tree! [t out] (compile! "the tree" (:paths t) out))

(defn stage! [t]
  (let [st (:stage t)
        otp (Path/join st "otp")
        lib (Path/join otp "lib")
        appd (Path/join otp (:app t))
        bl (Path/join lib "beam_lisp-0.1.0")]
    (File/rm_rf! st)
    (println "  · runtime")
    (copy-tree! (ensure-otp! (:abi t)) otp)
    (println "  · beam-lisp")
    (copy-tree! (Path/join (lib-dir :beam_lisp) "ebin") (Path/join bl "ebin"))
    (File/mkdir_p! (Path/join bl "priv/native"))
    (File/cp! (native-lazy-memo (:abi t)) (Path/join bl "priv/native/lazy_memo.so"))
    ; android.* — the device library — compiled here, from the priv/ that also
    ; supplied the Kotlin and the NIF, so the three always come from one tree.
    ; Into a directory of its own, then merged: `build/run` OWNS its output
    ; directory and prunes what it did not build — pointed at beam-lisp's
    ; ebin, it deleted 765 of 865 beams (measured) and the phone booted without
    ; the runtime.
    (let [ad (Path/join (:build t) "android-lib")]
      (File/rm_rf! ad)
      (compile! "device runtime" [(Path/join (priv) "lib/android")
                                   (Path/join (priv) "std/proc/owner-registry.bl")] ad)
      (doseq [f (Path/wildcard (Path/join ad "*.beam"))]
        (File/cp! f (Path/join (list bl "ebin" (Path/basename f))))))
    (step! "bl_android_nif stub" "erlc" ["-o" (Path/join bl "ebin") (Path/join (priv) "android/erl/bl_android_nif.erl")] {})
    (println "  · libraries")
    (BeamLisp.Loader/ensure_loaded "deps-compile")
    (doseq [d ((BeamLisp.Env/fetch! "deps-compile" "search-paths"))]
      (let [app-dir (Path/dirname d)
            nm (first (split (Path/basename app-dir) "-"))
            vsn (second (split (Path/basename app-dir) "-"))]
        (when (contains? (set (map :name (:deps ((BeamLisp.Env/fetch! "deps" "read-lock") (:root t))))) nm)
          (copy-tree! d (Path/join lib (str nm "-" vsn "/ebin")))
          (when (File/dir? (Path/join app-dir "priv"))
            (copy-tree! (Path/join app-dir "priv") (Path/join lib (str nm "-" vsn "/priv")))))))
    (doseq [d (:deps ((BeamLisp.Env/fetch! "deps" "read-lock") (:root t)))]
      (when-not (File/dir? (Path/join lib (str (:name d) "-" (:vsn d) "/ebin")))
        (throw (ex-info (str "missing compiled dependency " (:name d) " — run bl deps compile") {}))))
    (device-app-file! (Path/join bl "ebin/beam_lisp.app") (Path/join bl "ebin/beam_lisp.app") lib)
    (println "  · this tree")
    (File/mkdir_p! appd)
    (compile-tree! t appd)
    (boot-module! t appd)
    st))
```

```beam-lisp
(defn- tar-to-phone! [t dir]
  (let [tarball (Path/join (:build t) "stage.tar")
        remote "/data/local/tmp/bl-stage.tar"]
    (step! "pack" "tar" ["cf" tarball "-C" dir "otp"] {})
    (step! "push" (adb) ["push" tarball remote] {})
    (step! "chmod" (adb) ["shell" "chmod" "644" remote] {})
    (step! "unpack on the phone" (adb)
           ["shell" "run-as" (:id t) "sh" "-c"
            (str "'mkdir -p files && cd files && rm -rf otp && tar xf " remote "'")] {})
    (File/rm! tarball)))

(defn push [t _st]
  (println (str "bl android push " (:app t)))
  ; `files/` exists only once the app has run: first launch makes it.
  (when-not (:ok? (adb! "shell" "run-as" (:id t) "ls" "files"))
    (adb! "shell" "monkey" "-p" (:id t) "1")
    (Process/sleep 4000)
    (adb! "shell" "am" "force-stop" (:id t)))
  (tar-to-phone! t (stage! t))
  (println "  ✓ pushed")
  0)
```

## up, eval — the phone as a node

`up` launches the app with distribution on: the phone's node reaches the desk's
EPMD through `adb reverse`, and the desk reaches the phone's node port through
`adb forward`. Then this VM joins as a node and `eval` is an RPC — the same BEAM
messages the app sends itself, across a cable.

```beam-lisp
(defn node-name [t] (keyword (str (:app t) "_android_emu@127.0.0.1")))

(defn connect!
  "Join distribution and connect to the phone's node. true when connected."
  [t]
  (when (= :nonode@nohost (erlang/node))
    (net_kernel/start (keyword (str "bl_android_" (System/pid) "@127.0.0.1")) {:name_domain :longnames}))
  (erlang/set_cookie (keyword cookie))
  (loop [n 20]
    (cond
      (= true (net_kernel/connect_node (node-name t))) true
      (zero? n) false
      :else (do (Process/sleep 500) (recur (dec n))))))

(defn rpc [t m f args]
  (rpc/call (node-name t) m f (apply list args) 120000))

(defn grants [t]
  (let [id (:id t) pkg "io.beamlisp.android."]
    {"notify"   [["shell" "pm" "grant" id "android.permission.POST_NOTIFICATIONS"]]
     "listener" [["shell" "cmd" "notification" "allow_listener" (str id "/" pkg "BlNotificationListener")]]
     "reader"   [["shell" "settings" "put" "secure" "enabled_accessibility_services" (str id "/" pkg "BlReader")]
                 ["shell" "settings" "put" "secure" "accessibility_enabled" "1"]]
     "overlay"  [["shell" "appops" "set" id "SYSTEM_ALERT_WINDOW" "allow"]]}))

(defn- up-launch! [t]
  (sh "epmd" ["-daemon"])
  (adb! "reverse" "tcp:4369" "tcp:4369")
  (adb! "forward" (str "tcp:" dist-port) (str "tcp:" dist-port))
  (adb! "shell" "am" "force-stop" (:id t))
  (step! "launch" (adb) ["shell" "am" "start" "-n" (str (:id t) "/.MainActivity")
                         "--ei" "mob_dist_port" (str dist-port) "--es" "mob_node_suffix" "emu"] {}))

(defn- granted-reader? [t]
  (includes? (str (:out (adb! "shell" "settings" "get" "secure" "enabled_accessibility_services")))
             (str (:id t) "/io.beamlisp.android.BlReader")))

(defn up [t _st]
  ; Force-stopping an app drops it from the enabled accessibility services
  ; (measured: the setting reads `null` afterwards), so a reader granted
  ; before the restart is granted again after it.
  (let [reader? (granted-reader? t)]
    (up-launch! t)
    (when reader? (doseq [c (get (grants t) "reader")] (apply adb! c))))
  (if (connect! t)
    (do (println (str "  ✓ " (node-name t) " — bl android eval EXPR")) 0)
    (do (u/io-err (str "bl android: " (node-name t) " never came up — bl android logs")) 1)))



(defn eval [t exprs st]
  (if (not (connect! t))
    (do (u/io-err (str "bl android: cannot reach " (node-name t) " — run bl android up")) 1)
    (let [r (rpc t :Elixir.BeamLisp :eval [(join " " (vec exprs))])]
      (if (and (erlang/is_tuple r) (= :badrpc (erlang/element 1 r)))
        (do (u/io-err (str "on the phone: " (pr-str (erlang/element 2 r)))) 1)
        (do (u/emit st r pr-str) 0)))))
```

## grant, shot, logs, stop

The three special permissions — notification access, accessibility, drawing
over apps — are grants a person makes in Settings. On a development device the
shell can make them directly, so a test never taps through Settings.

```beam-lisp
(defn grant [t whats _st]
  (let [g (grants t)
        ws (if (or (empty? whats) (= ["all"] (vec whats))) (sort (keys g)) whats)]
    (doseq [w ws]
      (if-let [cmds (get g w)]
        (do (doseq [c cmds] (apply adb! c)) (println (str "  ✓ " w)))
        (u/io-err (str "  ? " w " — one of " (join " " (vec (sort (keys g))))))))
    0))

(defn shot [t args _st]
  (let [out (u/resolve (or (first args) (str (:app t) "-" (erlang/system_time :second) ".png")))
        r (System/cmd (adb) (list "exec-out" "screencap" "-p"))]
    (File/write! out (erlang/element 1 r))
    (println out)
    0))

(defn logs [t _st]
  (let [pid (String/trim (:out (adb! "shell" "pidof" (:id t))))]
    (if (= "" pid)
      (do (u/io-err (str (:id t) " is not running")) 1)
      (do (print (:out (adb! "logcat" "-d" "-t" "400" (str "--pid=" pid)))) 0))))

(defn stop [t _st] (adb! "shell" "am" "force-stop" (:id t)) 0)
```

## devtools — the WebView's pages, from the desk

A debug build's WebView serves Chrome's DevTools protocol on an abstract
socket named for the app's pid. `devtools` forwards it to a desk port and
lists the pages there: open `chrome://inspect`, or point any CDP client
(puppeteer's `browserURL`) at `http://localhost:PORT`. A loom page's URL is its
whole first frame as `data:`, so it is shown cut short.

```beam-lisp
(def devtools-port 9222)

(defn devtools-pages
  "Forward the running app's DevTools socket to `port`; its pages as maps with
   string keys (id, title, url, webSocketDebuggerUrl)."
  [t port]
  (let [pid (String/trim (str (:out (adb! "shell" "pidof" (:id t)))))]
    (when (= "" pid) (throw (ex-info (str (:id t) " is not running — bl android up") {})))
    (step! "forward devtools" (adb) ["forward" (str "tcp:" port) (str "localabstract:webview_devtools_remote_" pid)] {})
    (let [r (sh "curl" ["-s" "--max-time" "5" (str "http://localhost:" port "/json")])]
      (if (:ok? r)
        (bl.json/decode (:out r) {:keys :string})
        (throw (ex-info (str "no DevTools answer on port " port " — is a WebView open in " (:id t) "?") {}))))))

(defn devtools [t args st]
  (let [port (if (seq args) (erlang/binary_to_integer (first args)) devtools-port)
        pages (devtools-pages t port)
        short (fn [u] (if (> (count u) 60) (str (subs u 0 60) "…") u))]
    (u/emit st pages
            (fn [ps] (str "http://localhost:" port "  (chrome://inspect, or a CDP client)\n"
                          (join "\n" (vec (map (fn [p] (str "  " (get p "title") "  " (short (str (get p "url")))
                                                           "\n    " (get p "webSocketDebuggerUrl")))
                                               ps))))))
    0))

(defn install [t _st]
  (let [apk (Path/join (:android t) "app/build/outputs/apk/debug/app-debug.apk")]
    (if (not (File/exists? apk))
      (do (u/io-err "no APK — bl android build") 1)
      (do (step! "install" (adb) ["install" "-r" apk] {}) (println "  ✓ installed") 0))))
```

## the verb

```beam-lisp
(def usage
  "usage: bl android doctor|new NAME|build|install|push|up|eval EXPR|grant [WHAT…]|shot [FILE]|logs|stop|devtools [PORT]")

(defn run [args st]
  (u/register-paths st)
  (let [sub (first args)
        more (vec (concat (rest args) (or (:dd st) [])))
        cwd (u/resolve ".")]
    (try
      (cond
        (= sub "doctor") (doctor nil st)
        (= sub "new") (if (empty? more)
                        (u/usage-error "usage: bl android new NAME")
                        (new-tree (u/resolve (first more)) (Path/basename (first more))))
        (nil? sub) (u/usage-error usage)
        :else
        (let [t (target cwd)]
          (if (:error t)
            (do (u/io-err (str "bl android: " (:error t))) 1)
            (cond
              (= sub "build") (if (every? #{"--standalone" "--release"} more)
                                (build (assoc t :standalone? (boolean (some #{"--standalone"} more))
                                                :release? (boolean (some #{"--release"} more))) st)
                                (u/usage-error "usage: bl android build [--standalone] [--release]"))
              (= sub "install") (install t st)
              (= sub "push") (push t st)
              (= sub "up") (up t st)
              (= sub "eval") (eval t more st)
              (= sub "grant") (grant t more st)
              (= sub "shot") (shot t more st)
              (= sub "logs") (logs t st)
              (= sub "stop") (stop t st)
              (= sub "devtools") (devtools t more st)
              :else (u/usage-error usage)))))
      (catch e
        (u/io-err (str "bl android: " (or (ex-message e) (pr-str e))))
        1))))
```
