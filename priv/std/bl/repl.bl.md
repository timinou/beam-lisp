# bl.repl — a read-eval-print loop for beam-lisp

A REPL reads a form, evaluates it, prints the value, and repeats. The work is
in "reads a form": a form spans lines, so the loop cannot hand each line to
the evaluator. It reads a line, counts the parentheses, and keeps reading
until the form is complete. A `(` inside a string or a `;` comment is text,
not structure, and counting it would make the loop wait for a closer that
never comes — so the counter is a small scanner, not a character count.

The loop is written in beam-lisp because `bl` is the one interface to the
language. It never halts a process: it returns 0 at end of input, errors print
and the loop continues, and the daemon can serve a session inside a warm VM.

```beam-lisp
(ns bl.repl
  (:require [bl.util :as u] [bl.ports] [wry] [vm.osenv :as osenv]))
```

## Is the form complete?

`balanced?` walks the text once. A `"` opens a string, where brackets and
semicolons are ordinary characters; `\` escapes the next character inside it.
A `;` opens a comment that ends at the newline. Every opener pushes the closer
it needs; every closer must match the top of the stack. The text is complete
when the stack is empty and no string is open. An unterminated string is
incomplete on purpose: the user is still typing it, and the next line may
close it.

```beam-lisp
(defn balanced?
  "True when `src` holds only complete forms: every opener has its matching
   closer and no closer is unmatched. Strings and `;` comments are skipped, so
   a bracket inside either is ordinary text. An unterminated string is
   incomplete, so the repl reads another line."
  [src]
  (let [gs (vec (String/graphemes src))]
    (loop [i 0 stack [] str? false esc? false comment? false]
      (if (>= i (count gs))
        (and (empty? stack) (not str?))
        (let [ch (get gs i)
              n (inc i)]
          (cond
            comment? (recur n stack str? esc? (not= ch "\n"))
            esc?     (recur n stack str? false false)
            str?     (if (= ch "\\")
                       (recur n stack true true false)
                       (recur n stack (not= ch "\"") false false))
            (= ch "\"") (recur n stack true false false)
            (= ch ";")  (recur n stack false false true)
            (= ch "(")  (recur n (cons ")" stack) false false false)
            (= ch "[")  (recur n (cons "]" stack) false false false)
            (= ch "{")  (recur n (cons "}" stack) false false false)
            (or (= ch ")") (= ch "]") (= ch "}"))
            (if (= ch (first stack))
              (recur n (rest stack) false false false)
              false)
            :else (recur n stack false false false)))))))
```

## The loop

The prompt names the current namespace, so the user can see where a form will
land. A continuation line uses a short prompt; a form that is still open is
not a new form.

The last three results stay reachable the way a Clojure session expects: `*1`
is the last value, `*2` the one before it, and `*e` the last error. They are
interned in `user`, the namespace a prompt reads and writes by default.

```beam-lisp
(defn- last-value [name]
  (try (BeamLisp.Env/fetch! "user" name) (catch _ nil)))

(defn- record! [v]
  (BeamLisp.Env/intern "user" "*2" (last-value "*1"))
  (BeamLisp.Env/intern "user" "*1" v))

(defn- show
  "Evaluate one complete form, print its value, and keep the session's last
   values current. An error prints `error: msg` and the loop continues — an
   error is one form's outcome, not the session's."
  [src]
  (if (= "" (String/trim src))
    nil
    (try
      (let [v (BeamLisp/eval src)]
        (record! v)
        (println (BeamLisp.RT/print_str v)))
      (catch e
        (BeamLisp.Env/intern "user" "*e" e)
        (println (str "error: " (ex-message e)))))))

(defn- read-form
  "Read one complete form: prompt, read a line, and keep reading while the
   accumulated text is incomplete. Blank lines read as nothing. Returns the
   source, or `:eof` when input ends before a form starts."
  []
  (loop [acc ""]
    (let [line (IO/gets (if (= acc "") (str (BeamLisp.Env/current_ns) "=> ") "   "))]
      (cond
        (or (= line :eof) (nil? line)) (if (= acc "") :eof acc)
        (and (= acc "") (= "" (String/trim line))) (recur "")
        :else (let [acc (str acc line)]
                (if (balanced? acc) acc (recur acc)))))))
```

## The session, and how it is shown

The terminal loop is one presentation of a session; the browser page is another;
so is a native window. They are not three REPLs — they are three views, and the
default picks the best one the host can actually show. Two facts decide that:
is there a session to look at, and can this host draw a window.

The session comes first, because a window needs an address. When the tree
already has a session, its `/repl` page IS the thing to open — the page is
server-rendered from that session, so the window and the browser tab show the
SAME session (defs, namespace, history) rather than a second one. When there is
none, the session is booted here, in this process: the window is the session's
view, so the process that shows it is the process that serves it. That is the
`vm.session/start` composition the daemon uses, loaded on first need so a
terminal session never pays for the daemon's namespace.

A closed window is the interesting case. The crate's event loop exits when the
window closes, but it does NOT tell the BEAM (the NIF has no close
notification), so the only honest signal is that talking to the window starts
to fail. The loop polls exactly that: a closed window makes the interpreter
exit with it, which is how the command knows to end. One no-op eval every half
second costs nothing and gives the right behaviour — close the window, the
command ends — without a second async mechanism to keep in step.

```beam-lisp
(defn- terminal-session
  "The loop `bl repl` has always been: read a form, evaluate it, print it."
  []
  (BeamLisp.Env/in_ns "user")
  (println "beam-lisp on the BEAM — Ctrl+D to exit")
  (loop []
    (let [src (read-form)]
      (if (= src :eof)
        0
        (do (show src) (recur))))))

(defn- repl-url
  "The live session's REPL page, or nil when this tree has no session. A page
   URL is enough to open a window: `vm.http/repl-page` renders the token into
   the page, so nothing about the connection travels in the URL. Loopback, not
   the gateway name — see bl.ports/page-url."
  []
  (bl.ports/page-url "ui" "repl"))

(defn- ensure-session
  "The REPL page address, booting this tree's session in THIS process when it
   has none. Returns nil when the session came up without a ui port — an
   address to open is what the caller needs, and there is none."
  []
  (if-let [url (repl-url)]
    url
    (try
      (BeamLisp.Loader/ensure_loaded "vm.session")
      ((BeamLisp.Env/fetch! "vm.session" "start") (second (File/cwd)))
      (repl-url)
      (catch e
        (do (u/io-err (str "bl repl: the session did not start — " (ex-message e)))
            nil)))))

(defn- display?
  "Whether a display server is reachable. Both names are checked because a
   Wayland session still exports XWayland's DISPLAY, and either one lets GTK
   open a window."
  []
  (or (not (nil? (osenv/get "WAYLAND_DISPLAY")))
      (not (nil? (osenv/get "DISPLAY")))))

(defn- window-alive?
  "Whether the window's event loop is still there. Running any JavaScript in a
   closed window fails at the NIF (the message has no loop to land on), which
   is the only close signal available."
  [w]
  (try (do (wry/eval w "1") true) (catch _e false)))

(defn- window-session
  "Show `url` in a native window and stay alive as its session's server until
   the window closes (or the process is interrupted). The window is closed on
   the way out either way.

   There is deliberately no `:stop` receive clause: this process must not end
   because some unrelated part of the session sent it a message, and the
   window's own disappearance is the only signal that means 'the user is
   done'. Ctrl+C covers the human case."
  [url]
  (let [w (wry/open {:title "bl repl" :url url :width 1100 :height 780})]
    (println (str "bl repl — " url " (close the window to exit)"))
    (loop []
      (receive
        (after 500
          (if (window-alive? w)
            (recur)
            (do (try (wry/close w) (catch _e :ok)) 0)))))))
```

## The entry point

`run` is what the CLI calls. It decides presentation and nothing else, so the
modes cannot drift apart in behaviour — there is one session implementation and
three ways to look at it.

```beam-lisp
(defn run
  "The interactive session `bl repl` and a bare `bl` enter.

   Presentation only — the session is the same one either way, so a mode
   decides how it is SHOWN, never what it evaluates:
     default     a native window on the session's `/repl` page, when this host
                 can show one; otherwise the terminal loop, with the reason
     --web       that page in the desktop's browser
     --terminal  the terminal loop, always

   The window is a view of a running session, so the default mode attaches to
   the tree's session when there is one and boots one when there is not —
   exactly the composition `bl daemon start` uses. A host that cannot open a
   window (no native backend, no display) degrades to the terminal loop rather
   than failing: the REPL exists either way."
  [args st]
  (let [web? (or (:web st) (some (fn [a] (= a "--web")) args))
        term? (or (:terminal st) (some (fn [a] (= a "--terminal")) args))]
    (cond
      term? (terminal-session)

      web?
      (if-let [url (ensure-session)]
        (do (println url) (bl.ports/open-external url) 0)
        (do (u/io-err "bl repl --web: no session URL to open — is the tree's ui port bindable?")
            (terminal-session)))

      (not (wry/available?))
      (do (u/io-err "bl repl: no native webview backend here (priv/native/wry_webview.so) — terminal session")
          (terminal-session))

      (not (display?))
      (do (u/io-err "bl repl: no display (WAYLAND_DISPLAY and DISPLAY are both unset) — terminal session")
          (terminal-session))

      :else
      (if-let [url (ensure-session)]
        (window-session url)
        (do (u/io-err "bl repl: a session is up but holds no ui port — terminal session")
            (terminal-session))))))
```
