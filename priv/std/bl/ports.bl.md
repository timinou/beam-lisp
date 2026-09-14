# bl.ports — the tree's named ports, and the names they answer to

A project declares the ports it serves on. `env.bl` names them:

```beam-lisp silent
{:name "pulse"
 :ports {:web 4000 :metrics {:port 0} :ui 7700}}
```

A number is a preference: if that port is taken, the session SAYS so rather
than quietly serving somewhere else. `{:port 0}` means the OS chooses, and
whoever asks gets the number it chose. The registry behind this is files under
the runtime dir (see `BeamLisp.Daemon.Ports`), which is what lets one tree's
session see what ANOTHER tree's session holds — the collision worth catching is
between trees, and an in-VM table cannot see across.

Who that collision is between depends on what kind of claim it is. A CHOSEN
number is a promise about a port, and the machine keeps that promise once: two
checkouts cannot both serve `:web 4000`. An EPHEMERAL port is nobody's promise —
the OS picked the number — so it belongs to the session that asked, and every
checkout can run its own `:ui` at the same time. Claim files are keyed to say
which: a chosen name stands alone, an ephemeral one carries its tree.

Every claim also carries the HOSTS its port answers to — `web.pulse.test` and
its `.localhost` twin (see `BeamLisp.Daemon.Names`). That is what makes a port
something a developer never reads: the gateway routes a name to the number, and
these verbs print the name.

```beam-lisp silent
(ns bl.ports
  (:require [bl.util :as u]))
```

## Reading

`list` is the registry as data, oldest name first. `port-of` is the one answer a
program needs: the number behind a name. Both read whatever is LIVE — a claim
whose owner is gone is swept as it is met, so a crashed session never blocks the
next one.

```beam-lisp silent
(defn list-ports
  "Every live claim: a list of maps with :name :port :pinned :hosts :root
   :tree_id :pid."
  []
  (to-list (BeamLisp.Daemon.Ports/list)))

(defn port-of
  "The port behind `name`, or nil when nothing live holds it."
  [name]
  (BeamLisp.Daemon.Ports/port_of (name-str name)))

(defn- name-str [n] (if (keyword? n) (name n) (str n)))

(defn claim-for
  "The live claim `name` refers to, or nil. The name is the one the project
   declared: `web`, `ui`.

   A PINNED name is machine-wide — it is a promise about a number — so there is
   one claim to find. An EPHEMERAL name belongs to the session that asked for
   it, so two trees may hold `ui` at once and the answer is THIS tree's claim:
   printed addresses must describe the session you are in, not the neighbour's."
  [name]
  (let [n (name-str name)
        here (second (File/cwd))
        live (filter (fn [c] (= n (:name c))) (list-ports))]
    (or (some (fn [c] (when (= here (:root c)) c)) live)
        (first live))))

(defn live
  "The two facts every printed address depends on, resolved ONCE: the gateway's
   port, and whether port 80 answers for it. `url-for` is then arithmetic on
   them, so printing a table of N addresses costs one lookup and one probe
   instead of N of each."
  []
  (let [p (BeamLisp.Daemon.Gateway/port)]
    {:port p :fronted (BeamLisp.Daemon.Gateway/fronted_on? p)}))

(defn url-for*
  "`url-for` with the live facts already in hand — the same rule, for a caller
   printing many addresses."
  [name facts]
  (let [c (claim-for name)]
    (if (nil? c)
      nil
      (let [hs (:hosts c)]
        (if (empty? hs)
          nil
          (BeamLisp.Daemon.Gateway/url (first hs) (:port facts) (:fronted facts)))))))

(defn url-for
  "The address `name` answers at — its first host, through the gateway, so a
   human opens the app by name. The PORT appears only when it has to: when port
  80 answers for the gateway the name stands alone, and otherwise the port is
   printed — an address that omits the port nothing is listening on looks
   clickable and answers `connection refused`. nil when nothing holds the name,
   or when its claim registered no host (a port claimed without a project to
   name it). Resolves the live facts for ONE address; a caller printing many
   should resolve once and use `url-for*`."
  [name]
  (url-for* name (live)))

(defn- loopback-url
  "The same listener with no name in it. Never depends on the gateway — this is
   the half of the address that is always true."
  [c]
  (str "http://127.0.0.1:" (:port c) "/"))
```

## The verbs

`run` is the verb entry the CLI loads on first use, so `bl ports` costs nothing
until someone asks for it. Each row shows the name first, because that is the
address a human keeps; the number is the implementation detail beside it.

```beam-lisp silent
(defn- pad [s] (String/pad_trailing (str s) 10))

(defn run
  "`bl ports` — name · the host it answers at · the port behind it · owner."
  [_args _st]
  (let [ps (list-ports)]
    (if (empty? ps)
      (println "bl ports: no session has claimed a port")
      (let [facts (live)]
        (u/each
          (fn [p]
            (println (str "  " (pad (:name p))
                          (or (url-for* (:name p) facts) (loopback-url p))
                          "  → " (:port p)
                          "  " (Path/basename (:root p)) " (pid " (:pid p) ")")))
          (sort-by (fn [p] (:name p)) ps))
        (let [named (filter (fn [p] (not (empty? (:hosts p)))) ps)]
          (when (and (not (empty? named))
                     (nil? (BeamLisp.Daemon.Gateway/port)))
            (println "")
            (println (str "  " (count named) " name(s) registered, but no gateway answers them:"))
            (println "      bl gateway start    (one per user; `bl install gateway` keeps it running)")))))
    0))
```

`bl open NAME` prints the address and, with `--open`, hands it to the desktop.
`bl ui` is the same call with the session's own name — one implementation of
"where is this thing", so the terminal and the dashboard cannot disagree about
it.

```beam-lisp silent
(defn open-url
  "Print `name`'s address — the name, and the loopback address it routes to —
   and hand the first one to the desktop opener with `--open`. Returns the exit
   code. The name is printed first: it is what a human keeps, and the loopback
   line is what still works when the gateway is not running."
  [name args]
  (let [c (claim-for name)]
    (if (nil? c)
      (do (u/io-err (str "bl: nothing holds the name \"" (name-str name)
                         "\" — is the session running?"))
          1)
      (let [named (url-for name)
            plain (loopback-url c)]
        (println (or named plain))
        (when (not (nil? named))
          (println (str "  → " plain)))
        (when (some (fn [a] (= a "--open")) args)
          (System/cmd (str "xdg-open " (or named plain))))
        0))))

(defn url
  "The session's own address, or nil when this tree has no live session."
  []
  (let [c (claim-for "ui")]
    (if (nil? c) nil (or (url-for "ui") (loopback-url c)))))

(defn run-ui
  "`bl ui [--open]` — the session's URL, printed; `--open` hands it to the
   desktop's opener. One address for the whole session: the page and /mcp.

   It also STARTS THE TREE'S INDEX if one is not built yet, in the background,
   and says so. Opening a session is the moment a developer is willing to wait
   — the work belongs there, not behind a surprise minute of silence on their
   first code question. The dashboard shows the same build's progress (its Index
   pane reads the same row), so `bl ui` is the door and the page is the room.

   Asking is idempotent and cheap: a tree already indexed hits the memo in
   milliseconds, and a build in flight is not started twice."
  [args _st]
  (let [c (claim-for "ui")]
    (if (nil? c)
      (do (u/io-err "bl ui: no session is running for this tree (bl daemon start)")
          1)
      (do (start-index!)
          (open-url "ui" args)))))

(defn- start-index!
  "Ask the running session to index this tree, and report what it found.

   The daemon owns the index (see `BeamLisp.Daemon.IndexWorker`), so this asks
   IT rather than building anything here — a conn built in this process would die
   with the command, which is the whole failure this change removes. A VM with no
   session (a cold command) has nothing to ask, and nothing to report."
  []
  (let [p (erlang/whereis :"Elixir.BeamLisp.Daemon.IndexWorker")]
    (if (= :undefined p)
      nil
      (do
        (BeamLisp.Daemon.IndexWorker/ensure_building)
        (let [s (BeamLisp.Daemon.IndexWorker/progress)]
          (u/io-err
            (str "bl ui: "
                 (case (:phase s)
                   :building (str "indexing this tree now — watch "
                                  "http://127.0.0.1:" (or (get (claim-for "ui") :port) "?") "/")
                   :ready (str "index ready (" (get-in s [:stats :files]) " files, "
                               (get-in s [:stats :functions]) " functions)")
                   :error (str "index failed: " (:message s))
                   (str "index: " (name (or (:phase s) :cold)))))))
        nil))))

(defn run-open
  "`bl open NAME [--open] [--port N]` — the address behind a port NAME (or a
   raw port number). The everyday verb: no name to remember, no port either."
  [args st]
  (let [a (first args)
        name (or a (if (:port st) (str (:port st)) nil))]
    (if (nil? name)
      (u/usage-error "usage: bl open NAME [--open]")
      (let [c (or (claim-for name)
                  (some (fn [p] (when (= (:port p) (:port st)) p)) (list-ports)))]
        (if (nil? c)
          (do (u/io-err (str "bl open: no live port named \"" name "\""))
              1)
          (open-url (:name c) args))))))
```
