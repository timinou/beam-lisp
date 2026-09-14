# bl.z3 — the oracle's own dashboard

The tree can already measure itself in three places, and none of them adds up.
`decide/cost` times one process's decisions. `Z3.Ledger` keeps a `:counters`
rollup of who answered. `z3corpus/corpus` walks a tree of `.bl` files and asks
`system.core/verify-process` about every machine it finds. What is missing is the
thing a developer actually runs: **one command that rolls those up and prints
the verdict of a whole corpus, with the price of it and the reason for every
refusal.**

`bl z3 stats` is that command. It walks the corpus once, then prints five
labelled sections — the corpus and its coverage, the cost, the tier and fragment
histogram, the undecided machines each with z3's own `:why`, and the failures —
and every number in them was measured by the run that prints it.

The BEAM shape matters to read the numbers correctly. The ledger is an Erlang
`:counters` array: a lock-free, ownerless, mutable integer array created at
module load, so it outlives the process that made it and any reader can read it.
The memo above the oracle is an ETS table owned by the keeper process. The cost
of a decision is a per-process trail in the process dictionary. None of that is
private: the report is a *view over VM state*, and the example that ships with
this verb reads the same state two ways to prove it.

```beam-lisp
(ns bl.z3
  (:require [bl.util :as u]
            [z3]
            [z3corpus :as cor]
            [system.decide :as decide]))
```

## The report is a VALUE first

The command is a printer. The data is `stats-report`, a map, so a test and a
future MCP tool consume it without parsing text. `--json` prints that same map
through `u/emit`, changing the printer and not the value.

The walk is **serial on purpose**. The ledger trail is the *process's*: two
machines verified at the same time would attribute each other's decisions, and a
per-machine cost would be a lie. One machine at a time is a correctness
condition, not an implementation detail. (The pool is still armed, because the
verifier leases a solver per conversation — the leases are serialized by the
walk, not by the pool.)

```beam-lisp
(def default-dirs
  "The directories walked when no --path is given: the shipped runtime and the
   runnable examples — the same pair `z3corpus` defaults to."
  ["priv" "examples"])

(def pool-size
  "How many z3 solvers the pool runs. The walk leases them one at a time; the
   size is the width a future concurrent caller would get."
  4)

(defn- worst-machine
  "The machine with the largest wall-clock `:us`, or nil over an empty walk."
  [ms]
  (when (seq ms)
    (reduce (fn [a m] (if (> (:us m) (:us a)) m a)) (first ms) ms)))

(defn- run-walk
  "Walk `dirs` once and return `z3corpus/corpus`'s report. Clears the ledger
   first, so every number the report prints belongs to THIS walk and never to a
   leftover decision from earlier in the VM."
  [dirs]
  (z3/pool! pool-size)
  (decide/reset-ledger!)
  (cor/corpus dirs))
```

`z3corpus/grep-bound` is the independent anti-zero guard: a raw-text count of the
files that *mention* the word `defserver`. It is deliberately a different
mechanism from the node walk, so a walker bug shows up as a failed comparison
instead of a cheerful zero. The coverage line compares the walker's **machine**
count against it, and it fails when the bound is zero as well — a vacuous `0 ≥ 0`
is exactly the silent green the guard exists to catch.

```beam-lisp
(defn- walk-report
  "The report of a completed walk: the corpus's own numbers, the coverage guard,
   the walk's decisions, and every undecided machine with the reasons z3 gave."
  [dirs c]
  (let [ms (vec (:machines c))
        led (:ledger c)
        machines (count ms)
        worst (worst-machine ms)
        bound (cor/grep-bound dirs "defserver")
        coverage {:bound bound :machines machines :files (:files c)
                  :pass (and (< 0 bound) (>= machines bound))}]
    {:mode :walk
     :dirs dirs
     :files (:files c)
     :machines machines
     :counts (:counts c)
     :coverage coverage
     :cost {:count (:count led) :total_us (:total_us led)
            :median_us (:median c) :worst_us (:worst c)
            :worst (when (some? worst)
                     {:file (:file worst) :name (:name worst) :us (:us worst)})}
     :tiers (decide/histogram)
     :undecided (vec (map (fn [m] {:file (:file m) :name (:name m) :why (:why m)})
                          (filter (fn [m] (= :undecided (:outcome m))) ms)))
     :examined machines
     :failures {:unreadable (vec (:unreadable c)) :reread (vec (:failures c))}
     :ok (:pass coverage)}))

(defn- ledger-report
  "The same map, with the walk skipped: only what the VM already knows. `:files`
   and `:machines` are zero and `:coverage` is nil — the report says nothing was
   walked rather than claiming an empty corpus."
  [dirs]
  (let [us (vec (map (fn [d] (or (:us d) 0)) (decide/here)))
        cost (decide/cost)]
    {:mode :ledger
     :dirs dirs
     :files 0
     :machines 0
     :counts {:proven 0 :refuted 0 :undecided 0 :declined 0 :error 0}
     :coverage nil
     :cost {:count (:count cost) :total_us (:total_us cost)
            :median_us (cor/median us) :worst_us (:max_us cost)
            :worst nil}
     :tiers (decide/histogram)
     :undecided []
     :examined 0
     :failures {:unreadable [] :reread []}
     :ok true}))

(defn stats-report
  "The whole rollup as a VALUE — the data `bl z3 stats` prints and a future MCP
   tool returns. `opts`:

     :dirs   the directories to walk (default `default-dirs`)
     :walk?  false to skip the corpus walk and report the ledger alone

   → {:mode :walk|:ledger :dirs [str …] :files n :machines n
      :counts {:proven n :refuted n :undecided n :declined n :error n}
      :coverage {:bound n :machines n :files n :pass bool} | nil
      :cost {:count :total_us :median_us :worst_us :worst {:file :name :us}|nil}
      :tiers {:total :fragments :tiers}
      :undecided [{:file :name :why [kw …]} …]
      :examined n
      :failures {:unreadable [path …] :reread [{:file :text :error} …]}
      :ok bool}"
  [opts]
  (let [dirs (vec (get opts :dirs default-dirs))]
    (if (get opts :walk? true)
      (walk-report dirs (run-walk dirs))
      (ledger-report dirs))))
```

## The five sections, as text

One section per concern, each a real number. The two cases the report must never
blur are stated explicitly rather than left to a zero:

- an **empty corpus** prints the file count it examined, says plainly that no
  machine was found, and fails the coverage line — a vacuous zero cannot exit
  green;
- an **empty ledger** distinguishes "no questions were asked in this process"
  from "we did not check", because the ledger is per-VM and starts empty.

Section 4 is the reason the corpus had to carry a machine's `:why` at all: an
undecided machine is neither proved nor refuted, and "the solver gave up" is a
fact a reader needs a reason for.

```beam-lisp
(defn- pass? [b] (if b "PASS" "FAIL"))

(defn- coverage-text
  "The coverage line, or a plain statement that nothing was walked. A bound of
   zero fails, so an empty corpus can never read as a pass."
  [cov]
  (if (nil? cov)
    "   coverage: (not run — ledger-only mode)" 
    (str "   coverage: machines " (:machines cov) " >= grep bound " (:bound cov)
         " -> " (pass? (:pass cov))
         (if (and (not (:pass cov)) (= 0 (:bound cov)))
           " — no file spells \"defserver\"; a vacuous zero cannot pass"
           ""))))

(defn- corpus-lines [r]
  (let [walk? (= :walk (:mode r))
        c (:counts r)]
    (concat
      [(str "1. corpus (" (if walk? "walk" "skipped — ledger-only") ")")
       (str "   dirs: " (pr-str (:dirs r)))]
      (if walk?
        [(str "   files walked: " (:files r))
         (str "   machines found: " (:machines r))
         (str "   outcomes:  proved " (:proven c)
              " | refuted " (:refuted c)
              " | undecided " (:undecided c)
              " | declined " (:declined c)
              " | error " (:error c))
         (coverage-text (:coverage r))]
        ["   files walked: 0 (the corpus was not examined)"
         (coverage-text nil)])
      (if (and walk? (= 0 (:machines r)))
        ["   NO MACHINE FOUND in the files above — nothing was verified"]
        []))))

(defn- cost-lines [r]
  (let [c (:cost r) w (:worst c)]
    (concat
      [(str "2. cost (" (if (= :walk (:mode r)) "from the corpus run"
                            "ledger only — no walk") ")")
       (str "   decisions: " (:count c) " | total: " (:total_us c) " us"
            " | median: " (:median_us c) " us | worst: " (:worst_us c) " us")]
      (if (some? w)
        [(str "   worst machine: " (:file w) " · " (:name w) " (" (:us w) " us)")]
        []))))

(defn- tier-lines [r]
  (let [t (:tiers r) ts (:tiers t) fr (:fragments t)]
    [(str "3. tiers (ledger histogram)")
     (str "   total " (:total t)
          " | :z3 " (get ts :z3)
          " | :memo " (get ts :memo)
          " | :native-witness " (get ts :native-witness)
          (if (= 0 (:total t))
            " (no questions were asked in this process — the ledger is per-VM and starts empty)"
            ""))
     (str "   fragments: :tag-lattice " (get fr :tag-lattice)
          " | :arith " (get fr :arith)
          " | :general " (get fr :general))]))

(defn- undecided-lines [r]
  (let [u (:undecided r) n (:examined r)
        head (str "4. undecided (" (count u) " of " n " machines examined)")]
    (if (empty? u)
      [head (str "   none — 0 of " n " machines examined")]
      (concat [head]
              (map (fn [m]
                     (str "   " (:file m) " · " (:name m) " — why: "
                          (let [w (:why m)]
                            (if (empty? w)
                              "unknown (z3 gave no reason)"
                              (join ", " (map (fn [x] (pr-str x)) w))))))
                   u)))))

(defn- failure-lines [r]
  (let [f (:failures r) un (:unreadable f) rr (:reread f)]
    (concat
      ["5. failures"
       (str "   unreadable files: " (count un))
       (str "   re-read failures: " (count rr))]
      (map (fn [p] (str "   ✗ unreadable: " p)) un)
      (map (fn [x] (str "   ✗ re-read: " (:file x) ": " (:error x))) rr))))

(defn- mode-line [r]
  (if (= :walk (:mode r))
    "mode: walk (corpus + ledger)"
    "mode: ledger-only (no corpus walk)"))

(defn render
  "The human report: which mode ran, the five labelled sections, and the honest
   limit of what they measured. Returns a string."
  [r]
  (join "\n"
    (concat
      [(str "bl z3 stats — " (mode-line r))]
      (corpus-lines r)
      (cost-lines r)
      (tier-lines r)
      (undecided-lines r)
      (failure-lines r)
      [""
       (str "verdict: " (if (:ok r) "ok" (str "FAIL — the walk did not reach the grep bound")))
       "limit: the ledger counts this VM's decisions, and the walk is serial — its cost is"
       "       one machine at a time. The corpus's :why is z3's own reason, kept on the decision."])))
```

## The command

`bl z3 stats [--path DIR …] [--dry-run] [--json]`. `--path` chooses the
directories to walk (default `priv` + `examples`); `--dry-run` skips the walk
(the ~9 s part) and reports the ledger alone. The mode that ran is printed, so a
ledger-only run can never be mistaken for a clean corpus.

The exit code is the coverage verdict: `0` when the walk reached the grep bound,
`1` when it did not (an empty or partial walk must not exit green), `2` on a
usage error.

`bl.cli`'s global flag set lives in `bl.cli` — another session's file — so
`--dry-run`, which parses today, is the spelling of the skip; the positional word
`cost` is accepted as the same mode, so the verb works whichever spelling the CLI
exposes.

```beam-lisp
(defn run
  "`bl z3 stats [--path DIR …] [--dry-run] [--json]`. Returns an exit code."
  [args st]
  (u/register-paths st)
  (let [sub (if (empty? args) "stats" (first args))
        rest-args (if (empty? args) args (rest args))]
    (cond
      (= sub "stats")
      (let [dirs (if (empty? (:paths st)) default-dirs (:paths st))
            ledger-only (or (:dry_run st)
                            (some (fn [a] (= a "cost")) rest-args))
            report (stats-report {:dirs (vec dirs) :walk? (not ledger-only)})]
        (u/emit st report render)
        (if (:ok report) 0 1))

      (or (= sub "help") (= sub "--help") (= sub "-h"))
      (do (println "bl z3 stats [--path DIR …] [--dry-run] [--json]")
          (println "  the oracle's own dashboard: the corpus and its coverage, the cost,")
          (println "  the tier/fragment histogram, the undecided machines (with z3's :why),")
          (println "  and the failures.")
          (println "  --dry-run   skip the corpus walk (the ~9 s part): ledger only")
          0)

      :else
      (u/usage-error (str "bl z3: unknown subcommand \"" sub "\" (stats)")))))
```

```beam-lisp
;; FOLLOW-UP (MCP, not this file): a `z3_stats` tool belongs in
;; `priv/lib/mcp/tools.bl`, returning exactly `(stats-report {:walk? false})` (or
;; the walk, if the transport can wait) — so the MCP surface and the CLI are two
;; printers of one value. That file is owned by another session right now
;; (PLAN-112 P7), so the tool is not added here; `stats-report` is the seam it
;; calls.
```
