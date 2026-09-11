# bl.monitor — the live reload image, repainted as it changes

`bl watch` prints one line per committed save. `bl monitor` paints instead: it
watches a directory, commits every save through the coherent reload loop, and
re-renders the whole live image on each commit — the namespaces in the running
system, their vars, and the reload journal. Editing a file changes the picture;
a bad edit appears with the reason it was held while the old code keeps
serving.

Clearing the screen before each frame is what makes it a dashboard rather than
a log: the image replaces itself, and a held edit is shown together with the
namespaces it did not change. The read-model is `reload/inspect`, the same one
the web monitor renders, so the terminal and the browser never disagree about
what the running system is doing.

```beam-lisp
(ns bl.monitor
  (:require [bl.util :as u]))
```

## The frame

A frame is the terminal's whole picture: clear, home the cursor, name what is
watched, then the rendered image. It is rendered by evaluating
`reload.monitor/render-text` at paint time, so the reload namespaces resolve in
the process doing the painting.

```beam-lisp
(defn frame
  "One repaint of the live image, ready for a terminal: clear the screen, home
   the cursor, name the watched directory, and print the current image."
  [dir]
  (str (IO.ANSI/clear) (IO.ANSI/home)
       "beam-lisp reload monitor — watching " dir "  (Ctrl-C to stop)\n\n"
       (BeamLisp/eval "(reload.monitor/render-text (reload/inspect))")))
```

## A watcher that cannot start

The live-reload engine needs the `:file_system` dependency, which ships in dev
and test only. Its absence inside the watcher's `init` arrives as an EXIT
signal to this linked process — a signal `try` cannot catch — so `run` traps
exits and the failure comes back as a value. The report says what is missing
and returns the CLI's failure code; it never halts, because the daemon runs
this same function.

```beam-lisp
(defn- why
  "A caught value as one line: an exception's message, else its printed form."
  [r]
  (try (ex-message r) (catch _ (pr-str r))))

(defn- watch-error [r]
  (u/io-err (str "bl monitor: cannot start the watcher: " (why r)))
  (u/io-err "  the live-reload engine needs the :file_system application; run `bl doctor`.")
  1)
```

## The command

`run` starts the watcher with the repaint as its result callback, paints the
first frame, and parks. The watcher runs in its own process and drives every
later frame.

```beam-lisp
(defn run
  "`bl monitor DIR`. Watch DIR through the coherent reload loop and repaint the
   live image after every commit. DIR is required and must exist. Parks until
   interrupted; returns the watcher's failure code when it cannot start."
  [args st]
  (if (empty? args)
    (u/usage-error "usage: bl monitor DIR")
    (let [dir (u/resolve (first args))]
      (if (not (File/dir? dir))
        (u/usage-error (str "bl monitor: not a directory: " (first args)))
        (do (u/register-paths st)
            (BeamLisp.Loader/ensure_loaded "reload")
            (BeamLisp.Loader/ensure_loaded "reload.monitor")
            (Process/flag :trap_exit true)
            (try
              (let [[tag detail]
                    (BeamLisp.ReloadWatcher/start_link
                      (u/kw [:dirs (u/to-list [dir])]
                            [:auto_commit true]
                            [:on_result (fn [_status] (println (frame dir)))]))]
                (if (= :ok tag)
                  (do (println (frame dir))
                      (Process/sleep :infinity)
                      0)
                  (watch-error detail)))
              (catch e (watch-error e))))))))
```
