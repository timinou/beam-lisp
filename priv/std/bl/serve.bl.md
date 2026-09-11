# bl.serve — run a program that keeps a server alive

A program that starts a web server and returns leaves nothing holding the
process open: the BEAM stops as soon as its last working process finishes, and
the listener dies with it. `bl serve` supplies the missing half of such a
program — it runs the file, then parks the VM so the server keeps answering
until the operator stops it with Ctrl+C.

The file itself stays an ordinary program: it starts its server and returns.
The parking lives here, so the same file runs to completion under `bl run` and
stays up under `bl serve`.

The post-`--` arguments reach the program through `BeamLisp/argv`, exactly as
`bl run` delivers them, and the library roots and code paths are the ones
`bl.util` registers for every verb.

```beam-lisp
(ns bl.serve
  (:require [bl.util :as u]))
```

## The port

A program chooses its own port, and that literal is the default. `--port N`
moves it through one cooperative call: a program writes `(bl.serve/port 4043)`
where it would write the literal, and the flag makes that call answer `N`.
A program that keeps a bare literal simply ignores the flag — its port stays
what it says.

```beam-lisp
(def port-override
  "The port `--port` selected, or nil. The state behind `port`."
  (atom nil))

(defn port
  "The port `bl serve --port N` selected, else `default`. A program replaces a
   literal port with this call so the flag can move its server:
   `(web/serve {:port (bl.serve/port 4043) :plug router})`."
  [default]
  (or @port-override default))
```

## The command

`run` runs the file first, so the program's own startup output — including the
URL it prints — arrives before the message that says the VM is staying up. It
returns 1 when the program raises, so a broken file never looks like a running
server; a program that starts its server and returns parks here forever.

```beam-lisp
(defn run
  "`bl serve FILE [-- args...] [--port N]`. Run FILE, then park the VM so the
   server it started keeps answering. Returns 1 when the program raises."
  [args st]
  (if (empty? args)
    (u/usage-error "usage: bl serve FILE [-- args...] [--port N]")
    (let [target (first args)]
      (u/register-paths st)
      (reset! port-override (:port st))
      (try
        (BeamLisp/with_argv (u/to-list (or (:dd st) []))
          (fn [] (BeamLisp/run_file (u/resolve target))))
        (println (str "bl serve: " target " running — Ctrl+C to stop"))
        (Process/sleep :infinity)
        0
        (catch e
          (u/io-err (str "bl serve: " target ": " (ex-message e)))
          1)))))
```
