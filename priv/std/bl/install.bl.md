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

(def targets
  {"doom" {:summary "Doom Emacs: the beamlisp module, tree-sitter grammar, init.el wiring"
           :run run-doom
           :check check-doom}
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
  (println "usage: bl install TARGET [DIR] [--check] [--json]"))

(defn- all-ok? [steps]
  (empty? (filter (fn [s] (not (:ok s))) steps)))

(defn run
  "`bl install [TARGET [DIR]] [--check] [--json]`. No target lists them.
   A target installs (or, with --check, verifies) and answers 0 when every
   step is ok, 1 when one failed, 2 on a bad invocation."
  [args st]
  (if (empty? args)
    (do (list-targets) 0)
    (let [name (first args)
          t (get targets name)]
      (if (nil? t)
        (u/usage-error (str "bl install: unknown target \"" name "\" (doom|mcp)"))
        (let [arg (second args)
              steps (if (:check st)
                      ((:check t) arg)
                      (let [r ((:run t) arg)]
                        (if (and (map? r) (contains? r :error))
                          [{:name name :ok false :detail (get r :error)}]
                          r)))]
          (u/emit st {:target name :ok (all-ok? steps) :steps steps}
                  (fn [_] (render-report name steps)))
          (if (all-ok? steps) 0 1))))))
```
