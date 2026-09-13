# bl.gateway — the listener that answers names

A name has to reach a port somehow, and DNS cannot do it: DNS maps a name to an
ADDRESS, never to a port. So something has to read the name off each request and
hand it to the port that registered it. That something is the gateway — one
process per USER, because it holds the one port a URL is allowed to leave out.

```
bl gateway            is it up, and which names does it answer?
bl gateway start      start it (the systemd unit when installed, detached otherwise)
bl gateway stop       stop the running one
bl gateway run        run it in the foreground — what the unit execs
bl install gateway    the systemd unit, and the one sysctl that frees port 80
```

The gateway itself is `BeamLisp.Daemon.Gateway`: it reads `Host:`, looks the
name up in the port registry (the claim carries its own hosts, so no project
file is read here), and splices the two sockets together. Everything after the
request head is forwarded untouched, which is what makes a WebSocket, an SSE
stream and a chunked upload work without this code knowing what any of them are.

```beam-lisp
(ns bl.gateway
  (:require [bl.util :as u]))
```

## Reading it

`endpoint` is the gateway's own file under the runtime dir: a pid and a port.
It is read, never trusted — a file whose process is gone is swept on sight, so
"not running" and "running" are the only two answers.

```beam-lisp
(def unit-name "bl-gateway")

(defn unit-path
  "The user unit `bl install gateway` writes, or nil when there is no systemd
   user config directory to write into."
  []
  (let [cfg (or (System/get_env "XDG_CONFIG_HOME") (str (System/get_env "HOME") "/.config"))]
    (str cfg "/systemd/user/" unit-name ".service")))

(defn endpoint
  "The live gateway's pid and port as a map, or nil. {:ok %{…}} | :error from
   the Elixir side, unwrapped here so a verb reads one shape."
  []
  (let [r (BeamLisp.Daemon.Gateway/endpoint)]
    (if (tuple? r) (erlang/element 2 r) nil)))

(defn running? [] (not (nil? (BeamLisp.Daemon.Gateway/port))))

(defn- port-of [] (BeamLisp.Daemon.Gateway/port))

(defn- routes [] (to-list (BeamLisp.Daemon.Gateway/routes)))

(defn- installed? [] (File/regular? (unit-path)))

(defn- systemctl? [] (not (nil? (System/find_executable "systemctl"))))
```

## The verbs

`status` answers with the port, the pid and every name it routes — the same
registry `bl ports` prints, seen from the other end.

```beam-lisp
(defn run-status
  "`bl gateway` — the running gateway and the names it answers. Exit 1 when none
   is running, because a question about a missing service is a failure to the
   shell that asked it."
  [_args _st]
  (if (not (running?))
    (do
      (println "bl gateway: not running")
      (println (if (installed?)
                 "  it is installed but stopped — bl gateway start"
                 "  bl gateway start       start it now (detached)"))

      (println "  bl install gateway     keep it running across logins")
      1)
    (let [ep (endpoint)
          rs (routes)]
      (println (str "bl gateway on 127.0.0.1:" (port-of)
                    " and [::1]:" (port-of) "   (pid " (:pid ep) ")"))
      (if (empty? rs)
        (println "  no names registered yet — a project registers them with :ports in env.bl")
        (u/each
         (fn [c]
           (println (str "  " (first (:hosts c))
                         "  → 127.0.0.1:" (:port c)
                         "  " (Path/basename (:root c)))))
         rs))
      0)))
```

`start` prefers the unit: if the developer installed the gateway, systemd owns
its lifecycle and this is a `systemctl` call. Otherwise it detaches the same
command the unit would run, so both paths start the same process.

```beam-lisp
(defn- wait-up
  "Poll until the gateway answers, up to ~60s. Returns true when it is up.

   A COLD drop boot is what sets the budget: starting `bl gateway run` pays for
   the whole substrate (AOT, the native tier, priv/), measured at ~20s on this
   machine the first time and ~1s warm. A five-second budget reported a healthy
   gateway as a failure — and the gateway then came up anyway, which is worse
   than a slow answer, because the caller believes the report."
  [tries]
  (cond
    (running?) true
    (<= tries 0) false
    :else (do (Process/sleep 500) (wait-up (- tries 1)))))

(defn- log-file
  "Where a detached gateway's output goes. A background process whose failures
   are reported as `did not come up` must leave the why somewhere readable."
  []
  (let [state (or (System/get_env "XDG_STATE_HOME")
                  (str (System/get_env "HOME") "/.local/state"))
        dir (str state "/beam-lisp")]
    (File/mkdir_p dir)
    (str dir "/gateway.log")))

(defn- detach
  "Start `bl gateway run` as an orphan of this process. `setsid` gives it its own
   session so no terminal teardown can reach it, stdin comes from nowhere, and
   its output goes to a log file rather than nowhere. The gateway's own endpoint
   file is still how it is found again — it needs no parent watching it."
  []
  (let [bin (BeamLisp.Daemon.Gateway/command)]
    (if (nil? bin)
      (do (u/io-err "bl gateway: no `bl` on PATH — run `bl gateway run` from a checkout, or set BL_BIN")
          nil)
      (System/cmd "sh"
                  (u/to-list ["-c" (str "setsid " bin " gateway run < /dev/null > " (log-file)
                                       " 2>&1 &")])))))

(defn run-start
  "`bl gateway start` — the unit when one is installed, else a detached run.
   Returns 0 once the gateway answers, 1 when it does not."
  [_args _st]
  (cond
    (running?)
    (do (println (str "bl gateway: already running on port " (port-of))) 0)

    (and (installed?) (systemctl?))
    (do
      (System/cmd "systemctl" (u/to-list ["--user" "start" unit-name]))
      (if (wait-up 120)
        (do (println (str "bl gateway: up on " (port-of) " (systemd)")) 0)
        (do (u/io-err "bl gateway: systemctl --user start did not bring it up (systemctl --user status bl-gateway)") 1)))

    :else
    (do
      (detach)
      (println "bl gateway: starting… (a cold start takes a few seconds)")
      (if (wait-up 120)
        (do (println (str "bl gateway: up on " (port-of))) 0)
        (do (u/io-err (str "bl gateway: did not come up — " (log-file) " says why")) 1)))))
```

`stop` asks systemd when systemd owns it, and signals the process otherwise.
Either way the endpoint file is gone when it returns, so `bl gateway` agrees
with reality immediately after.

```beam-lisp
(defn run-stop
  "`bl gateway stop` — stop the running gateway. Returns 0 when it is down,
   1 when none was running."
  [_args _st]
  (if (not (running?))
    (do (println "bl gateway: not running") 1)
    (do
      (if (and (installed?) (systemctl?))
        (System/cmd "systemctl" (u/to-list ["--user" "stop" unit-name]))
        (BeamLisp.Daemon.Gateway/stop))
      (println "bl gateway: stopped")
      0)))
```

`run` is the foreground form: it blocks until interrupted, which is exactly
what a systemd `Type=simple` service wants.

```beam-lisp
(defn- refusal
  "The sentence the gateway refused with: `{:error, {:gateway_failed, msg}}`,
   `{:error, msg}`, or anything else rendered as itself. A caller reads it."
  [r]
  (if (string? r)
    r
    (let [inner (try (erlang/element 2 r) (catch _ nil))]
      (cond
        (string? inner) inner
        (tuple? inner) (let [m (try (erlang/element 2 inner) (catch _ nil))]
                         (if (string? m) m (pr-str r)))
        :else (pr-str r)))))

(defn run-run
  "`bl gateway run [--port N]` — the gateway in the foreground. A pinned port
   that cannot be bound is an error, never a silent move."
  [_args st]
  (let [r (BeamLisp.Daemon.Gateway/run (u/kw [:port (:port st)]))]
    (u/io-err (str "bl gateway: " (refusal r)))
    1))
```

```beam-lisp
(defn run
  "`bl gateway [start|stop|status|run]` — the listener that answers names."
  [args st]
  (let [sub (or (first args) "status")]
    (cond
      (= sub "status") (run-status args st)
      (= sub "start") (run-start args st)
      (= sub "stop") (run-stop args st)
      (= sub "run") (run-run args st)
      :else (u/usage-error (str "bl gateway: unknown subcommand \"" sub "\" (start|stop|status|run)")))))
```
