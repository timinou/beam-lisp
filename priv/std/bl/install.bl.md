# bl.install — beam-lisp, installed into your tools

`bl` already serves every tool the same way — `bl lsp serve` for editors,
`bl mcp` for agents — but *wiring a tool to those surfaces* was hand-work:
copy this file, edit that init, compile a grammar, register a server. This
verb makes the wiring a command. One target is one descriptor: how to find
the tool, what to write, and how to check the write worked.

```
bl install                 the targets and their status
bl install doom [DOOMDIR]  the Doom Emacs module + tree-sitter grammar + init.el
bl install mcp [DIR]       agent instructions + client registration (default: .)
bl install TARGET --check  verify an installation instead of making one
```

The design rule, from the corpus this repo keeps relearning: the knowledge
about how to install lives in ONE place (this namespace's payload and
target table), and each tool is a projection of it. When a new tool learns
to speak beam-lisp, it becomes a descriptor here — not a new README section
to drift.

```beam-lisp
(ns bl.install
  (:require [bl.util :as u] [datom]))
```

## Where things live

Two resolutions everything else builds on. The DOOM directory is where the
user's configuration lives; the beam-lisp ROOT is where this `bl` was born —
in a checkout, the directory above `priv/`. The payload (the elisp the
module is made of) ships with the source tree, so the root is how a command
running anywhere still finds it. `BL_ROOT` overrides, for the day the drop
carries the payload itself.

```beam-lisp
(defn home [] (System/get_env "HOME"))

(defn- dir-or-nil [p] (if (and (some? p) (File/dir? p)) p nil))

(defn doom-dir
  "The Doom user directory: the argument, $DOOMDIR, ~/.config/doom, ~/.doom.d."
  [arg]
  (or (dir-or-nil arg)
      (dir-or-nil (System/get_env "DOOMDIR"))
      (dir-or-nil (str (home) "/.config/doom"))
      (dir-or-nil (str (home) "/.doom.d"))))

(defn- real-dir
  "The directory `p` truly is: through a symlink (Mix links _build's priv
   to the checkout's), else itself."
  [p]
  (let [r (File/read_link p)]
    (if (and (tuple? r) (= :ok (erlang/element 1 r)))
      (let [target (erlang/element 2 r)]
        (if (starts-with? target "/")
          target
          (u/resolve (str (Path/dirname p) "/" target))))
      p)))

(defn beam-root
  "The beam-lisp checkout this command runs from, or nil. Derived from the
   application's priv dir: in a checkout, _build/.../beam_lisp/priv is a
   symlink to <root>/priv, so the root is one dirname up from the real
   path. The presence of editors/emacs is the proof — a release priv dir
   has none, and answers nil instead of a wrong path."
  []
  (let [env (System/get_env "BL_ROOT")]
    (if (and (some? env) (not= env "") (File/dir? (str env "/editors/emacs")))
      env
      (let [r (code/priv_dir :beam_lisp)]
        (if (tuple? r)
          nil
          (let [priv (real-dir (if (string? r) r (erlang/list_to_binary r)))
                root (Path/dirname priv)]
            (if (File/dir? (str root "/editors/emacs")) root nil)))))))

(def payload-files
  "The files a Doom module is made of, relative to <root>/editors/emacs —
   the module source, vendored wholesale so the installed module survives
   the checkout moving."
  ["beamlisp-ts-mode.el"
   "beamlisp-doc.el"
   "ob-beamlisp.el"
   "doom/config.el"
   "doom/packages.el"
   "doom/doctor.el"
   "doom/README.org"])
```

## The tree-sitter grammar

The mode wants a compiled grammar; the repo ships a pre-generated
`parser.c`, so installing is one `cc` call into Emacs's grammar directory —
no tree-sitter CLI, no node. The grammar directory is Doom's local etc when
it exists, the classic `~/.emacs.d/tree-sitter` otherwise.

```beam-lisp
(defn- grammar-dir
  "Where this Emacs keeps tree-sitter grammars."
  []
  (or (dir-or-nil (str (home) "/.config/emacs/.local/etc/tree-sitter"))
      (dir-or-nil (str (home) "/.emacs.d/.local/etc/tree-sitter"))
      (dir-or-nil (str (home) "/.emacs.d/tree-sitter"))))

(defn- install-grammar
  "Compile parser.c into the grammar dir. Returns {:ok path} or {:error msg} —
   a missing cc or grammar dir is a report line, never a crash."
  [root]
  (let [parser-dir (str root "/editors/tree-sitter-beamlisp/src")
        parser (str parser-dir "/parser.c")]
    (cond
      (not (File/regular? parser))
      {:error (str "no parser.c at " (u/rel-path parser))}

      (nil? (System/find_executable "cc"))
      {:error "no cc on PATH — install a C compiler, then re-run"}

      :else
      (let [dir (grammar-dir)]
        (if (nil? dir)
          {:error "no Emacs tree-sitter grammar directory found"}
          (let [out (str dir "/libtree-sitter-beamlisp.so")
                r (System/cmd "cc" (u/to-list ["-shared" "-fPIC" "-O2"
                                                 "-I" parser-dir parser "-o" out]))
                status (erlang/element 2 r)]
            (if (= 0 status)
              {:ok out}
              {:error (str "cc failed: " (erlang/element 1 r))})))))))
```

## init.el: one line, exactly once

Doom enables a module by naming it in the `doom!` form. The wiring edits
`init.el` surgically: the line goes right under `:lang`, in the house style
of the hand-written modules around it, and a line that already mentions
beamlisp is left alone — installing twice changes nothing.

```beam-lisp
(def init-line
  "       (beamlisp +lsp +literate) ; NOTE: Custom module - beam-lisp")

(defn- wire-init
  "Add the beamlisp module to DOOMDIR/init.el, under :lang. Returns
   :already | {:wired path} | {:error msg}."
  [doomdir]
  (let [path (str doomdir "/init.el")]
    (if (not (File/regular? path))
      {:error (str "no init.el in " doomdir)}
      (let [content (File/read! path)]
        (if (includes? content "beamlisp")
          :already
          (let [lines (String/split content "\n")
                n (count lines)
                lang-i (loop [i 0]
                         (cond (>= i n) nil
                               (= ":lang" (String/trim (Enum/at lines i))) i
                               :else (recur (+ i 1))))]
            (if (nil? lang-i)
              {:error "no :lang section in init.el — add (beamlisp +lsp +literate) by hand"}
              (do (File/write! path
                    (join "\n"
                          (concat (Enum/take lines (+ lang-i 1))
                                  [init-line]
                                  (Enum/drop lines (+ lang-i 1)))))
                  {:wired path}))))))))
```

## The doom target

Install = vendor the module, compile the grammar, wire init.el. Every step
reports what it did; a step that cannot run says what to do instead. The
last word is always the same: `doom sync`, then restart Emacs.

```beam-lisp
(defn- step [name result]
  {:name name
   :ok (not (and (map? result) (contains? result :error)))
   :detail (cond
             (and (map? result) (contains? result :error)) (get result :error)
             (map? result) (or (get result :ok) (get result :wired) (pr-str result))
             (= result :already) "already wired"
             :else (str result))})

(defn- run-doom [arg]
  (let [doomdir (doom-dir arg)]
    (if (nil? doomdir)
      {:error "no Doom directory found (tried $DOOMDIR, ~/.config/doom, ~/.doom.d)"}
      (let [root (beam-root)]
        (if (nil? root)
          {:error "beam-lisp checkout not found — set BL_ROOT, or run from a checkout"}
          (let [mod-dir (str doomdir "/modules/lang/beamlisp")]
            (File/mkdir_p mod-dir)
            (u/each
             (fn [rel]
               (File/write! (str mod-dir "/" (Path/basename rel))
                            (File/read! (str root "/editors/emacs/" rel))))
             payload-files)
            [(step "module" {:ok (str mod-dir " (" (count payload-files) " files)" )})
             (step "grammar" (install-grammar root))
             (step "init.el" (wire-init doomdir))
             {:name "next" :ok true
              :detail "doom sync, then restart Emacs (or doom sync && doom/reload)"}]))))))
```

## The mcp target

Agents don't need files copied into a home directory — they need the server
registered and crisp instructions. The instructions are the corpus itself,
assembled from the fact database (mcp.instructions): onboarding for first
contact, usage for the day-to-day. The files this writes and the prompts the
server serves are projections of one corpus — they cannot drift.

```beam-lisp
(defn- assemble-prompts
  "Mount the codebase, assemble the three prompts. The live section comes
   from mcp.server, the same builder the served prompts/get uses."
  []
  (BeamLisp.Loader/ensure_loaded "mcp.tools")
  (BeamLisp.Loader/ensure_loaded "mcp.server")
  (BeamLisp.Loader/ensure_loaded "mcp.instructions")
  (let [conn (mcp.tools/conn)
        db (datom/db conn)
        live (mcp.server/live-usage-section {:conn conn})]
    {:onboarding (get (mcp.instructions/prompt "beam-lisp/onboarding" db live) :text)
     :usage (get (mcp.instructions/prompt "beam-lisp/usage" db live) :text)
     :protocol (get (mcp.instructions/prompt "beam-lisp/protocol" db live) :text)}))

(def registration
  "How a client registers the server — the header of every file we write."
  (join "\n"
        ["> Register the server with your MCP client:"
         ">"
         ">     claude mcp add beam-lisp -- bl mcp"
         ">"
         "> or in a mcpServers config:"
         ">"
         ">     {\"mcpServers\": {\"beam-lisp\": {\"command\": \"bl\", \"args\": [\"mcp\"]}}}"
         ">"
         "> The server serves these same instructions over prompts/list +"
         "> prompts/get (beam-lisp/onboarding, beam-lisp/usage,"
         "> beam-lisp/protocol) — one corpus, both projections."
         ""]))

(defn- run-mcp [dir-arg]
  (let [dir (u/resolve (or dir-arg "."))]
    (File/mkdir_p dir)
    (let [ps (assemble-prompts)
          onb (str dir "/beam-lisp-mcp.onboarding.md")
          usg (str dir "/beam-lisp-mcp.usage.md")]
      (File/write! onb (str (:onboarding ps) "\n\n---\n\n" registration "\n"
                            (:protocol ps) "\n"))
      (File/write! usg (str (:usage ps) "\n\n---\n\n" registration))
      [(step "onboarding" {:ok (u/rel-path onb)})
       (step "usage" {:ok (u/rel-path usg)})
       {:name "register" :ok true
        :detail "claude mcp add beam-lisp -- bl mcp"}])))
```

## The command

The target table is the one representation: a name, a summary, the runner.
`--check` re-runs the target's checks without writing — for doom, that the
module files, the grammar and the init line are all in place; for mcp, that
the corpus assembles.

```beam-lisp
(defn- check-doom [arg]
  (let [doomdir (doom-dir arg)]
    (if (nil? doomdir)
      [{:name "doom" :ok false :detail "no Doom directory found"}]
      (let [mod-dir (str doomdir "/modules/lang/beamlisp")
            init (str doomdir "/init.el")]
        [{:name "module" :ok (File/dir? mod-dir)
          :detail (if (File/dir? mod-dir) mod-dir "absent — run: bl install doom")}
         {:name "grammar"
          :ok (let [d (grammar-dir)]
                (and (some? d)
                     (File/regular? (str d "/libtree-sitter-beamlisp.so"))))
          :detail (let [d (grammar-dir)]
                    (if (and (some? d)
                             (File/regular? (str d "/libtree-sitter-beamlisp.so")))
                      (str d "/libtree-sitter-beamlisp.so")
                      "absent — run: bl install doom"))}
         {:name "init.el"
          :ok (and (File/regular? init)
                   (includes? (File/read! init) "beamlisp"))
          :detail (if (and (File/regular? init)
                           (includes? (File/read! init) "beamlisp"))
                    "beamlisp module enabled"
                    "not wired — run: bl install doom")}]))))

;; ── the gateway target ────────────────────────────────────────────────
;;
;; The gateway is HOST infrastructure, not a project's: one per user, holding
;; the one port a URL is allowed to leave out, answering every name every tree
;; registered. Installing it is the two things a project cannot do for itself —
;; a systemd USER unit (it starts at login; it outlives a shell) and, once, the
;; sysctl that lets a user bind port 80 at all.

(defn- unit-file []
  (let [cfg (or (System/get_env "XDG_CONFIG_HOME") (str (home) "/.config"))]
    (str cfg "/systemd/user/bl-gateway.service")))

(defn- unit-text [bin]
  (join "\n"
        ["[Unit]"
         "Description=beam-lisp gateway — answers the names beam-lisp projects declare"
         "After=network.target"
         ""
         "[Service]"
         "Type=simple"
         (str "ExecStart=" bin " gateway run")
         "Restart=on-failure"
         "RestartSec=2"
         ""
         "[Install]"
         "WantedBy=default.target"
         ""]))

(defn- port-80-verdict
  "Can an unprivileged process bind port 80 right now? Asked by binding it,
   which is the only answer that counts."
  []
  (let [r (gen_tcp/listen 80
                          (list :binary
                                (tuple :ip (erlang/list_to_tuple (list 127 0 0 1)))
                                (tuple :reuseaddr false)))]
    (if (tuple? r)
      (let [tag (erlang/element 1 r)]
        (if (= :ok tag)
          (do (gen_tcp/close (erlang/element 2 r)) :ok)
          (erlang/element 2 r)))
      :error)))

(defn- port-80-pointer
  "One line naming both ways a name gets answered on port 80, and the root
   step each takes. The exact sysctl string lives in the gateway module, so
   there is one spelling of it in the tree; this is a REPORT line, so it names
   the verbs a developer types."
  []
  (str "run: bl install redirect (loopback only, removable), or: "
       (BeamLisp.Daemon.Gateway/sysctl_command)))

(defn- answer-on-80
  "What is on port 80 right now: :ours, :other or :closed.

   Three answers, because the two ways of not being ours need different
   sentences. A closed port is nobody's and can be opened for us. A port another
   server holds is somebody's working service — and there the redirect does not
   open a free port, it takes loopback 80 away from that server, so the report
   has to say that before handing over the paste."
  []
  (BeamLisp.Daemon.Gateway/answer_on? 80))

(defn- port-80-step
  "The report line about port 80, from what the probe found. `mine` is what to
   say when the gateway answers there, which each verb words its own way; the
   other two states read the same wherever they are printed."
  [state mine]
  (cond
    (= state :ours)
    {:name "port 80" :ok true :detail mine}

    (= state :other)
    {:name "port 80" :ok false
     :detail (str "something else answers — not a beam-lisp gateway. The redirect would send ALL "
                  "loopback :80 traffic to the gateway, including requests to whatever is there now")}

    :else
    {:name "port 80" :ok false :detail (str "not answered — " (port-80-pointer))}))

(defn- run-gateway [_arg]
  (let [bin (BeamLisp.Daemon.Gateway/command)
        unit (unit-file)]
    (if (nil? bin)
      {:error "no `bl` on PATH — set BL_BIN to this build, then re-run"}
      (do
        (File/mkdir_p (Path/dirname unit))
        (File/write! unit (unit-text bin))
        (System/cmd "systemctl" (u/to-list ["--user" "daemon-reload"]) (u/kw [:stderr_to_stdout true]))
        (let [start (System/cmd "systemctl"
                                (u/to-list ["--user" "enable" "--now" "bl-gateway"])
                                (u/kw [:stderr_to_stdout true]))
              code (erlang/element 2 start)
              verdict (port-80-verdict)]
          [(step "unit" {:ok unit})
           (step "service" (if (= 0 code)
                              {:ok "enabled + started (systemctl --user)"}
                              {:error (str "systemctl --user enable --now failed: "
                                           (String/trim (erlang/element 1 start)))}))
           (step "port 80" (cond
                              (= :ok verdict) {:ok "bindable by a user here — the gateway takes it"}
                              (= :eacces verdict) {:error (port-80-pointer)}
                              :else {:error (str "not free (" (pr-str verdict)
                                                 ") — the gateway will use 7777 (" (port-80-pointer) ")")}))
           {:name "next" :ok true
            :detail "open what it routes: bl ports, then a name"}])))))

(defn- check-gateway [_arg]
  (let [unit (unit-file)
        verdict (port-80-verdict)
        answered (BeamLisp.Daemon.Gateway/ours_on? 80)
        up (BeamLisp.Daemon.Gateway/port)]
    [{:name "unit" :ok (File/regular? unit)
      :detail (if (File/regular? unit) unit "absent — run: bl install gateway")}
     {:name "gateway" :ok (not (nil? up))
      :detail (if (nil? up) "not running — bl gateway start" (str "on port " up))}
     ;; The question a developer actually has: can I leave the port out of the
     ;; URL? Not "could I bind 80" — whether something answers there. So the
     ;; check probes, and names the two ways to make it answer.
     {:name "port 80" :ok answered
      :detail (if answered
                "a name needs no port here"
                (str (pr-str verdict) " — " (port-80-pointer)))}]))
;; ── the redirect target ───────────────────────────────────────────────
;;
;; A name is worth having because a URL may omit the port, and exactly ONE port
;; may be omitted: 80. Binding it needs privilege or a machine-wide sysctl — a
;; lot to ask for "I want to type my dev server's name". The third way is the
;; smallest: leave the gateway where it stands and redirect port 80 to it, on
;; loopback only, in nftables tables of our own.
;;
;; What that buys, exactly: packets to 127.0.0.0/8:80 and [::1]:80 are NATed to
;; the gateway's port. Nothing on the LAN is touched (the rule sits in the
;; OUTPUT chain and matches loopback destinations), no policy is loosened (a
;; local process still cannot bind 1023), and the gateway's printed addresses
;; lose their port by themselves — they are derived from a probe of port 80
;; (BeamLisp.Daemon.Gateway/fronted_on?).
;;
;; Root is still needed for the rule. So the install is a SCRIPT: printed for
;; the user when this process has no password, run with `sudo -n` when it does.
;; A tool that stops to wait for a password in a pipe is worse than one that
;; hands over the line.

(def redirect-port
  "Where the redirect sends port 80: the gateway's fallback port. An unpinned
   gateway prefers 80 and settles on 7777, so this is the one that stays right
   across a gateway restart."
  7777)

(def redirect-rules-path "/etc/bl-gateway-redirect.nft")
(def redirect-unit-path "/etc/systemd/system/bl-gateway-redirect.service")

(defn redirect-rules
  "The ruleset, as text. Our OWN tables: an install never edits somebody else's
   rules, and a removal never has to guess which rule was ours."
  [port]
  (str "table ip bl_gateway_redirect {\n"
       "  chain output {\n"
       "    type nat hook output priority dstnat; policy accept;\n"
       "    ip daddr 127.0.0.0/8 tcp dport 80 redirect to :" port "\n"
       "  }\n"
       "}\n"
       "table ip6 bl_gateway_redirect {\n"
       "  chain output {\n"
       "    type nat hook output priority dstnat; policy accept;\n"
       "    ip6 daddr ::1 tcp dport 80 redirect to :" port "\n"
       "  }\n"
       "}\n"))

(defn redirect-unit-text
  "The boot half: nftables rules do not survive a reboot, and a SYSTEM unit is
   the smallest thing that reapplies them — no dependency on how a particular
   machine's /etc/nftables.conf happens to be written."
  [rules-path]
  (str "[Unit]\n"
       "Description=beam-lisp gateway redirect — port 80 for names beam-lisp projects declare\n"
       "After=network.target\n"
       "\n[Service]\n"
       "Type=oneshot\n"
       "RemainAfterExit=yes\n"
       "ExecStart=/usr/bin/nft -f " rules-path "\n"
       "\n[Install]\n"
       "WantedBy=multi-user.target\n"))

(defn install-script
  "Installing, as the script a human would paste. Dropping our own tables first
   is what makes a second install a no-op instead of an error."
  [stage]
  (str "set -e\n"
       "install -D -m644 " stage "/redirect.nft " redirect-rules-path "\n"
       "install -D -m644 " stage "/redirect.service " redirect-unit-path "\n"
       "nft delete table ip bl_gateway_redirect 2>/dev/null || true\n"
       "nft delete table ip6 bl_gateway_redirect 2>/dev/null || true\n"
       "nft -f " redirect-rules-path "\n"
       "systemctl daemon-reload\n"
       "systemctl enable --now bl-gateway-redirect.service\n"))

(defn remove-script
  "Removing: the same three things in reverse — and only ours."
  []
  (str "systemctl disable --now bl-gateway-redirect.service 2>/dev/null || true\n"
       "nft delete table ip bl_gateway_redirect 2>/dev/null || true\n"
       "nft delete table ip6 bl_gateway_redirect 2>/dev/null || true\n"
       "rm -f " redirect-rules-path " " redirect-unit-path "\n"
       "systemctl daemon-reload\n"))

(defn- state-dir
  "Where a staged install waits between being written (no root) and being
   copied into /etc (root)."
  []
  (str (or (System/get_env "XDG_STATE_HOME") (str (home) "/.local/state"))
       "/beam-lisp"))

(defn- sudo-ready?
  "Whether sudo runs a command without asking. Asked FIRST, because an install
   that stops to wait for a password in a pipe reads as a hung tool."
  []
  (= 0 (erlang/element 2 (System/cmd "sudo" (u/to-list ["-n" "true"])
                                     (u/kw [:stderr_to_stdout true])))))

(defn- write-stage
  "Write the two files the script installs. Writing them needs no root — only
   putting them in /etc does, which is what the script is for."
  [port]
  (let [dir (str (state-dir) "/redirect")]
    (File/mkdir_p dir)
    (File/write! (str dir "/redirect.nft") (redirect-rules port))
    (File/write! (str dir "/redirect.service") (redirect-unit-text redirect-rules-path))
    dir))

(defn- run-script
  "Run an install script as root, or hand it over. Returns {:ok detail} or
   {:error detail}; the script itself is PRINTED, because a sentence a
   developer can act on beats a stack trace about a permission."
  [script]
  (if (sudo-ready?)
    (let [r (System/cmd "sudo" (u/to-list ["sh" "-c" script]) (u/kw [:stderr_to_stdout true]))]
      (if (= 0 (erlang/element 2 r))
        {:ok "installed (nftables + the system unit)"}
        {:error (str "the script failed: " (String/trim (erlang/element 1 r)))}))
    (do (println "")
        (println "this one needs root — run it:")
        (println "")
        (println script)
        {:error "needs root — the script printed above"})))


(defn- run-redirect [_arg]
  (let [port (BeamLisp.Daemon.Gateway/port)]
    (cond
      (= :ours (answer-on-80))
      [(port-80-step :ours "already answered — nothing to install")]

      (nil? port)
      [{:name "gateway" :ok false
        :detail "not running — bl gateway start first (a redirect would have nothing to forward to)"}]

      :else
      (let [r (run-script (install-script (write-stage port)))]
        [{:name "ruleset" :ok (not (contains? r :error)) :detail (or (get r :ok) (get r :error))}
         (port-80-step (answer-on-80) "names answer here without a port")
         {:name "gateway port" :ok (= port redirect-port)
          :detail (if (= port redirect-port)
                    (str "on the fallback port " redirect-port " — the boot rule stays right")
                    (str "on " port ", not " redirect-port
                         " — the rule follows it now, but restart the gateway on the fallback"
                         " port so the boot rule keeps pointing at it"))}
         {:name "next" :ok true :detail "bl ports — the addresses printed there need no port"}]))))

(defn- remove-redirect [_arg]
  (let [r (run-script (remove-script))]
    [{:name "ruleset" :ok (not (contains? r :error)) :detail (or (get r :ok) (get r :error))}
     (port-80-step (answer-on-80)
                   "still answered — by the gateway itself, which holds 80")]))

(defn- check-redirect [_arg]
  (let [state (answer-on-80)
        enabled (String/trim (erlang/element 1 (System/cmd "systemctl"
                                                           (u/to-list ["is-enabled" "bl-gateway-redirect.service"])
                                                           (u/kw [:stderr_to_stdout true]))))]
    [(port-80-step state "a name needs no port here")
     {:name "ruleset file" :ok (File/regular? redirect-rules-path)
      :detail (if (File/regular? redirect-rules-path) redirect-rules-path
                (if (= state :ours)
                  "absent — port 80 is answered without it (the sysctl, or the gateway holds it)"
                  "absent — run: bl install redirect"))}
     {:name "unit" :ok (= enabled "enabled")
      :detail (if (= enabled "enabled") "enabled" (str enabled " — run: bl install redirect"))}]))

(defn- asset-fetch-steps
  "Run one pinned-asset fetcher and answer install STEPS.

   `bl install` is where the language says "put the thing on this machine where
   the language looks for it", and a pinned asset — the solver, the embedding
   weights — is exactly that. Each fetcher is its own namespace because the
   RULES (URL, sha256 pins, destination) are data about the artifact; the verb is
   the door. Before this existed the door was a Mix task, and the messages that
   tell a user what to run said `mix bl.z3.fetch` — in a toolchain whose whole
   point is that Mix is gone."
  [ns-name dir-name]
  (BeamLisp.Loader/ensure_loaded ns-name)
  (let [r (BeamLisp.RT/invoke (BeamLisp.Env/fetch! ns-name "fetch!")
                              (list {:bundle false :force false}))]
    (if (true? (:ok? r))
      (let [d (or (:dir r) dir-name)]
        (if (empty? (:files r))
          [{:name ns-name :ok true :detail (str "present — " d)}]
          (mapv (fn [f] {:name f :ok true :detail "verified (pinned sha256)"}) (:files r))))
      [{:name ns-name :ok false :detail (str (or (:why r) "failed") " — run: bl install " dir-name)}])))

(defn- embed-check-steps
  "The `--check` half for the embedding: present or not, WITHOUT downloading."
  [_arg]
  (BeamLisp.Loader/ensure_loaded "embed-asset")
  (let [dir (BeamLisp.RT/invoke (BeamLisp.Env/fetch! "embed-asset" "dest-for")
                                (list {:bundle false}))
        ok (BeamLisp.RT/invoke (BeamLisp.Env/fetch! "embed-asset" "fetched?")
                               (list dir))]
    [{:name "embedding" :ok (true? ok)
      :detail (if (true? ok) (str "present — " dir) (str "absent — run: bl install embed"))}]))

(defn- z3-check-steps
  "The `--check` half for the solver: the binary exists AND runs.

   Presence alone is not the property that matters — a half-extracted or
   wrong-architecture binary is present and useless — so the check is the smoke
   run `mix bl.z3.fetch` used to do at the end of a fetch."
  [_arg]
  (let [bin (Path/join (BeamLisp.Tiers/priv_root) "z3/bin/z3")]
    (if (not (File/exists? bin))
      [{:name "z3" :ok false :detail "absent — run: bl install z3"}]
      (let [r (try (System/cmd bin (list "--version")) (catch e [nil 1 (str e)]))]
        [{:name "z3" :ok (= 0 (second r))
          :detail (if (= 0 (second r))
                    (str (String/trim (first r)) " — " bin)
                    (str "present but does not run: " bin))}]))))

(def targets
  {"doom" {:summary "Doom Emacs: the beamlisp module, tree-sitter grammar, init.el wiring"
           :run run-doom
           :check check-doom}
   "z3"   {:summary "The pinned z3 solver, into priv/z3 (sha256-verified)"
           :run (fn [_] (asset-fetch-steps "z3-asset" "z3"))
           :check z3-check-steps}
   "embed" {:summary "The pinned embedding weights, into the model cache (sha256-verified)"
            :run (fn [_] (asset-fetch-steps "embed-asset" "embed"))
            :check embed-check-steps}
   "gateway" {:summary "The name gateway: one per user, holding the port a URL may leave out"
              :run run-gateway
              :check check-gateway}
   "redirect" {:summary "Port 80 without privilege: redirect it to the gateway (nftables + a system unit)"
               :run run-redirect
               :check check-redirect
               :remove remove-redirect}
   "mcp"  {:summary "MCP clients: agent instructions + server registration"
           :run run-mcp
           :check (fn [_] [{:name "mcp" :ok true
                            :detail "instructions are assembled, not installed — bl install mcp [DIR]"}])}})

(defn- render-report
  [target steps]
  (join "\n"
        (concat
         [(str "bl install " target) ""]
         (map (fn [s]
                (str "  " (if (:ok s) "ok" "--") "   " (:name s) "  " (:detail s)))
              steps))))

(defn- list-targets []
  (println "bl install — beam-lisp, installed into your tools")
  (println "")
  (u/each
   (fn [name]
     (println (str "  " name "  " (:summary (get targets name)))))
   (sort (keys targets)))
  (println "")
  (println "usage: bl install TARGET [DIR] [--check] [--remove] [--json]"))

(defn- all-ok? [steps]
  (empty? (filter (fn [s] (not (:ok s))) steps)))

(defn run
  "`bl install [TARGET [DIR]] [--check] [--remove] [--json]`. No target lists
   them. A target installs (or, with --check, verifies, and with --remove,
   undoes) and answers 0 when every step is ok, 1 when one failed, 2 on a bad
   invocation."
  [args st]
  (if (empty? args)
    (do (list-targets) 0)
    (let [name (first args)
          t (get targets name)]
      (if (nil? t)
        (u/usage-error (str "bl install: unknown target \"" name
                            "\" (" (join "|" (sort (keys targets))) ")"))
        (if (and (:remove st) (nil? (:remove t)))
          (u/usage-error (str "bl install: " name " has nothing to remove"))
          (let [arg (second args)
                steps (cond
                        (:check st) ((:check t) arg)
                        (:remove st) ((:remove t) arg)
                        :else (let [r ((:run t) arg)]
                                (if (and (map? r) (contains? r :error))
                                  [{:name name :ok false :detail (get r :error)}]
                                  r)))]
            (u/emit st {:target name :ok (all-ok? steps) :steps steps}
                    (fn [_] (render-report name steps)))
            (if (all-ok? steps) 0 1)))))))
```
