# Names instead of ports

A running thing has a NAME. The port it happens to be listening on is an
implementation detail of a socket — and it leaks into every URL a developer
types, pastes, bookmarks and debugs. Beam Lisp takes the number back out.

Declare your ports in `env.bl`:

```clojure
{:name "pulse"
 :ports {:web   4000          ; a preference: served here if it is free
         :admin {:port 0}}}   ; the OS chooses; nobody needs to know which
```

and `(bl.serve/port :web 4043)` answers the number — claimed in the session's
registry first, so the app you start is reachable at a name:

    http://web.pulse.test        the app
    http://pulse.test            the session's own page (and its /mcp)

Two verbs close the loop. `bl ports` lists what is claimed, name first. `bl open
web` prints the address and, with `--open`, hands it to your browser.

```beam-lisp {:id "require"}
(ns dev.names-doc
  (:require [bl.env :as env] [bl.util :as u]))
```

```bl-result cell0
:dev.names-doc
```

```beam-lisp {:silent? true}
(defn scratch
  "A temporary project directory that is removed when `f` returns."
  [f]
  (let [d (str (System/tmp_dir!) "/bl-names-doc-" (erlang/unique_integer (list :positive)))]
    (File/mkdir_p! d)
    (try (f d) (finally (File/rm_rf! d)))))
```

```bl-result scratch
&:"Elixir.BeamLisp.Ns.Dev.Names-doc".scratch/1
```

## The name a port answers to

A name is DERIVED, and the rule fits in one line:

    <port-name>.<base>.<suffix>          and, for the session's own :ui, <base>.<suffix>
    base = slug(project :name)  <>  "-" <> slug(:instance)   when there is one

The instance is what makes two checkouts of one project different names rather
than a collision: declare `:instance`, or let it come from the git branch when
that is not a default branch.

```beam-lisp {:id "derivation"}
(scratch
  (fn [d]
    (File/write! (str d "/env.bl")
                 "{:name \"Pulse App\" :instance \"PR 42\"}")
    (list (BeamLisp.Daemon.Names/base d)
          (BeamLisp.Daemon.Names/host d "web")
          (BeamLisp.Daemon.Names/host d "ui")
          (BeamLisp.Daemon.Names/hosts d "admin"))))
```

```bl-result cell2
("pulse-app-pr-42" "web.pulse-app-pr-42.test" "pulse-app-pr-42.test" ("admin.pulse-app-pr-42.test" "admin.pulse-app-pr-42.localhost"))
```

A name is a DNS label, so anything a human writes becomes one — downcased, runs
of anything else folded to a single `-`, and truncated rather than refused:

```beam-lisp {:id "slug"}
(map (fn [s] [s (BeamLisp.Daemon.Names/slug s)])
     (list "MiXeD" "feat/websockets" "My.App" "  ..  "))
```

```bl-result cell3
(["MiXeD" "mixed"] ["feat/websockets" "feat-websockets"] ["My.App" "my-app"] ["  ..  " ""])
```

## Two suffixes, no install

Every host is offered under `.test` and `.localhost`:

- `.localhost` needs no resolver at all — nss-myhostname answers it on a
  systemd host, and every browser resolves any name that ends in it.
- `.test` is the reserved testing TLD. One line in a dnsmasq drop-in
  (`address=/test/127.0.0.1`) points all of it at loopback.

Whichever spelling a machine resolves, the gateway answers the same route, so
nothing has to be installed before the first name works.

## Why a gateway exists

DNS maps a name to an ADDRESS. It never maps one to a port, and the port is the
thing we are trying not to think about. So one process reads the name off each
request and hands it to the port that registered it.

That process is the gateway: `BeamLisp.Daemon.Gateway`, one per USER, holding
port 80 — the one HTTP port a URL may leave out. It reads only the request head,
for the `Host:` line; everything after it is spliced straight through. That is
what makes a WebSocket, a Server-Sent-Event stream and a chunked upload work
without the gateway knowing what any of them are.

Its routing table is the port registry itself. A claim carries the hosts it
answers to, because the process holding the port is the one that knows its name:

```beam-lisp {:id "claim"}
(let [name "doc-names-probe"
      r (BeamLisp.Daemon.Ports/claim
          name 0
          (u/kw [:root "/tmp/names-doc"] [:hosts (u/to-list ["web.pulse.test"])]))]
  (try
    ;; projected, not printed raw: a port number and a pid are the two things
    ;; in a claim that change every run, and a stored result must not.
    (list (erlang/is_integer (erlang/element 2 r))
          (let [h (BeamLisp.Daemon.Ports/holder_of_host "web.pulse.test")]
            (list (:name h) (:hosts h) (= (erlang/element 2 r) (:port h))))
          (BeamLisp.Daemon.Ports/holder_of_host "nope.test"))
    (finally (BeamLisp.Daemon.Ports/release name))))
```

```bl-result cell4
(true ("doc-names-probe" ("web.pulse.test") true) nil)
```

## Running the gateway

    bl gateway            is it up, and which names does it answer?
    bl gateway start      start it now (the unit when installed, else detached)
    bl gateway stop       stop it
    bl gateway run        run it in the foreground — what the unit execs
    bl install gateway    a systemd user unit, plus the one root step for port 80

Port 80 is the only privileged piece. On a stock Linux a user cannot bind it;
one sysctl makes low ports unprivileged, and then it is the user's:

    printf 'net.ipv4.ip_unprivileged_port_start=80\n' | sudo tee /etc/sysctl.d/60-beam-lisp-gateway.conf
    sudo sysctl --system

Without it the gateway binds 7777 and says so, names still work with the port
in the URL, and nothing else changes. A port that was PINNED is never silently
moved — a pinned port that is taken is an error naming the owner.

## What is not here

- **TLS.** The gateway speaks plain HTTP. `https://` needs a certificate a
  browser trusts for a name nobody owns, which is a CA install, not a code path.
- **Reaching it from another machine.** The gateway listens on loopback only.
  A name is a developer's own, and binding every interface would hand a LAN
  neighbour every dev server on the laptop.
