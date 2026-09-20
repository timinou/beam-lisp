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
  (:require [bl.env :as env] [bl.util :as u] [vm.names] [vm.ports]))
```

## The port

A program chooses its own port, and that literal is the default. `--port N`
moves it through one cooperative call: a program writes `(bl.serve/port 4043)`
where it would write the literal, and the flag makes that call answer `N`.
A program that keeps a bare literal simply ignores the flag — its port stays
what it says.

Every port a program serves on can also have a NAME. The name comes from the
project: `:ports {:web 4000}` in `env.bl` says this tree serves a web port, and
`(bl.serve/port :web 4043)` asks for it — claiming it in the session's registry
and registering the hosts that name answers to. The number never leaves this
file; what a developer opens is `http://web.<project>.test`.

```beam-lisp
(def port-override
  "The port `--port` selected, or nil. The state behind `port`."
  (atom nil))

(defn port
  "The port this program serves on, and the name it answers to.

   `(port 4043)` answers the literal, or `--port N` when the operator passed
   one: a program replaces its literal so the flag can move the server.

   `(port :web 4043)` answers the port the project declares for the name `web`
   — claimed in the session's registry, and registered with the hosts that name
   answers to, so the app is reachable at `http://web.<project>.test` and no
   human has to read a number. A port another live process holds is an ERROR
   naming the owner: two servers must never trade places in silence."
  ([default] (or @port-override default))
  ([name default]
   (let [n (name-str name)
         root (BeamLisp/cwd)
         want (or @port-override (declared n) default)
         r (vm.ports/claim
             n want
             {:root root :hosts (u/to-list (vm.names/hosts root n))})]
     (if (= :ok (erlang/element 1 r))
       (erlang/element 2 r)
       (throw (ex-info (str "bl.serve: cannot serve \"" n "\": "
                            (pr-str (erlang/element 2 r)))
                       {}))))))

(defn- name-str [n] (if (keyword? n) (name n) (str n)))

(defn declared
  "The port the project declares for `name` — `:ports {:web 4000}` in env.bl —
   or nil when the tree declares none. The number is a PREFERENCE: the registry
   is what decides whether it is this process's to take."
  [name]
  (get-in (env/project (BeamLisp/cwd)) [:ports (name-str name) :port]))
```

## The access log's shape

The access log is ON by default — one EDN record per request on stderr,
emitted by `web/serve` (the one place a response status is observable at all).
The SHAPE is what a program decides here: one line per request is what a
journal wants, one field per line is what a terminal wants. `--pretty-log`
and `--no-pretty-log` move it through the same cooperative call `--port` uses,
and a tree that declares the preference once in `env.bl` —
`:serve {:access-log {:pretty true}}` — reads it here instead of repeating it
in every server file.

Why the default is OFF (one line): production stderr goes to journald, which
gives every LINE its own record. An indented multi-line record is therefore a
foreground-server shape, not a log shape.

```beam-lisp
(def pretty-override
  "The log shape `--pretty-log` / `--no-pretty-log` selected, or nil. The
   state behind `pretty`."
  (atom nil))

(defn declared-pretty
  "The shape this tree declares in env.bl — `:serve {:access-log {:pretty
   bool}}` — or nil when it declares none. A declaration is a PREFERENCE: the
   flag and the program's own literal both outrank it."
  []
  (let [v (get-in (env/project (BeamLisp/cwd)) [:serve :access-log :pretty])]
    (if (or (= true v) (= false v)) v nil)))

(defn pretty
  "Whether this server's access log prints one field per line.

   `(pretty false)` in a server file means \"one line per request\" — what a
   journal wants; `(pretty true)` is the foreground-dev default. `--pretty-log`
   or `--no-pretty-log` overrides the literal, and a tree-level declaration in
   env.bl overrides it too. The three are consulted here in that order: FLAG,
   then env.bl, then the program's literal."
  [default]
  (if (some? @pretty-override)
    @pretty-override
    (let [d (declared-pretty)]
      (if (some? d) d default))))
```

## The command

`run` runs the file first, so the program's own startup output — including the
URL it prints — arrives before the message that says the VM is staying up. It
returns 1 when the program raises, so a broken file never looks like a running
server; a program that starts its server and returns parks here forever.

```beam-lisp
(defn run
  "`bl serve FILE [-- args...] [--port N] [--pretty-log]`. Run FILE, then park
   the VM so the server it started keeps answering. Returns 1 when the program
   raises."
  [args st]
  (if (empty? args)
    (u/usage-error "usage: bl serve FILE [-- args...] [--port N] [--pretty-log]")
    (let [target (first args)]
      (u/register-paths st)
      (reset! port-override (:port st))
      (reset! pretty-override (:pretty_log st))
      (try
        (BeamLisp/with_argv (u/to-list (or (:dd st) []))
          (fn [] (BeamLisp/run_file (u/resolve target))))
        (println (str "bl serve: " target " running — Ctrl+C to stop"))
        ;; where the access log goes, said out loud: a server that logs every
        ;; request must not leave you guessing where the log went (and in
        ;; production that is the journal, not a file this verb owns)
        (println (str "bl serve: access log → stderr, one EDN line per request"
                      " (--pretty-log: one field per line)"))
        (Process/sleep :infinity)
        0
        (catch e
          (u/io-err (str "bl serve: " target ": " (ex-message e)))
          1)))))
```
