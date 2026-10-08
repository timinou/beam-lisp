# 04 — Hot reload: app and bl-stdlib change in place

**Thesis:** a deploy that changes bl code — an app namespace *or* a namespace the
language ships — lands by an atomic, per-var swap inside the one long-lived node,
with no restart and no dropped request; an edit that does not hold together is
refused and the old code keeps serving.

## The claim

`zero-downtime.md §L1` ("hot reload is the default") claims that a level-1 change
— a function, a namespace — is made live *inside* the running node by hot reload,
never by starting a second node and cutting over. The load-bearing consequence is
that this reaches **everything written in bl**, not just application code: the
language's own stdlib namespaces update the same way. Blue-green is reserved for
the *platform floor alone* — the bl closure, OTP, the OS closure (a level-3
change, proven by `09_platform_swap`). This spike proves both halves of that
split: L1 is hot, and an incoherent L1 edit is held rather than half-shipped.

## The idea

Two different things can change on a box, and they are not the same operation:

```
app / bl stdlib  →  HOT: swap the code in place, the node never restarts
platform floor   →  BLUE-GREEN: a new node comes up beside the old, cut over
```

Why the split matters for devops: the overwhelming majority of changes are code
(*your* code and *the language's* code). If every one of those costs a restart,
you are paying full downtime — connections dropped, in-flight requests lost,
caches cold — for a change that never needed any of it. So L1 must be free.

Making hot reload *free* is easy; making it *safe* is the hard part. The naive
version — evaluate the new source and hope — is how you ship a broken image: a
mid-rename save leaves a caller dangling, and the whole point is that you never
observe a half-applied change. This spike's real machinery solves it with two
moves:

- **The unit of change is the edit *bundle*, not the file.** A rename touches a
  definition and five callers; each *file* save alone is incoherent, the *set* is
  fine. You stage every edit, then commit the set together.
- **Coherence is decided STATICALLY, before anything is evaluated.** `commit`
  reads the staged sources plus the live image's public names and asks "does this
  whole bundle hold together?" — a call with no definition anywhere, a promise
  never fulfilled, a require cycle, a type conflict. Only a bundle that passes is
  evaluated into the image, and each `defn` lands as an atomic per-var swap.
  A caller already in flight finishes on its captured body; the next call
  resolves the new one. ∴ no caller ever sees a missing or half-updated var, and
  an incoherent edit never touches the live image at all — old code keeps serving.

That last clause is the headline guarantee: **`commit` either applies the whole
bundle or holds the whole bundle.** There is no third outcome where some of it
is live.

## Walkthrough

The spike is small; every line is load-bearing. Run it with the command in
[Run it](#run-it) and the printed stages map one-to-one onto the steps below.

### Step 0 — arm the production gate

```clojure
(ns vps.hot-reload (:require [reload]))

(reload/set-enabled! true)                 ; prod gate: mutating reloads on
```

`reload` refuses *mutating* reloads in a packaged image by default — only a
development image, or one with `BEAM_LISP_RELOAD=1`, will commit. This is the
prod policy: you do not get to silently swap code into a shipped node unless you
opted in. `set-enabled!` overrides that decision for the session, which is how a
canary or a test exercises the live path. Everything below depends on this being
on; a commit with it off returns `:held` with a `:policy` reason and the old code
still serving (see the exercises).

### Step 1 — bring up a live app namespace and a concurrent caller

```clojure
(reload/stage "app" "(ns app) (defn handle [] \"v1\")")
(reload/commit)
(def results (atom []))
(def halt? (atom false))
(def loper
  (erlang/spawn
    (fn [] (loop []
             (when (not (deref halt?))
               (swap! results conj (app/handle))
               (Process/sleep 2) (recur))))))
(Process/sleep 20)
```

`reload/stage` buffers a namespace source into the pending **bundle**; it does
not touch the image. `reload/commit` proves the bundle coherent and, if so,
applies it — so `app/handle` is now live and returns `"v1"`.

Then the spike starts a caller that matters: a spawned process looping
`(app/handle)` every 2 ms, appending each answer to `results`. This is the
stand-in for real traffic — the thing that must never see a broken value. It
runs concurrently with every commit that follows.

### Step 2 — L1a: an app update is hot

```clojure
(reload/stage "app" "(ns app) (defn handle [] \"v2\")")
(def app-up (reload/commit))
(Process/sleep 20)
(println "── app update ──" (:status app-up) " handle→" (app/handle))
```

Stage the new source, commit, keep going. `app-up` is the commit's bundle
status; `(:status app-up)` is `:applied`, and `(app/handle)` now returns `"v2"`.
No process restarted, no port rebound — the loop above simply starts seeing
`"v2"` on its next call because the var was swapped in place. The printed line is:

```
── app update ── :applied  handle→ v2
```

### Step 3 — L1b: a bl *stdlib* update is hot, the same way

```clojure
(reload/stage "mylib" "(ns mylib) (defn version [] \"lib-1\")")
(reload/commit)
(def before-lib (mylib/version))
(reload/stage "mylib" "(ns mylib) (defn version [] \"lib-2\")")
(def lib-up (reload/commit))
(println "── bl/stdlib update ──" (:status lib-up)
         " version " before-lib "→" (mylib/version))
```

This is the correction the spike exists to encode. A namespace the *language*
provides is not special: it is a namespace, so it stages and commits through
exactly the same gate. `before-lib` captures `"lib-1"`, the new source is staged
and committed (`:applied`), and `(mylib/version)` now returns `"lib-2"` — while
the node lives. There is no second mechanism for stdlib, and there does not need
to be:

```
── bl/stdlib update ── :applied  version  lib-1 → lib-2
```

(the doubled spaces are `println`'s single-space join around the literal
`" version "` and `"→"` args — the values themselves are `lib-1` then `lib-2`,
`println` printing strings unquoted)

### Step 4 — the safety net: a coherent edit lands, then an incoherent one is HELD

First the spike establishes a two-function namespace and commits it:

```clojure
(reload/stage "app" "(ns app) (defn helper [] 1) (defn handle [] (str \"v\" (helper)))")
(reload/commit)
```

So `app` now defines `helper` and `handle`, and `handle` returns `"v1"` (it
concatenates `"v"` with `(helper)` → `1`). Then it stages an edit that *drops*
`helper` while still calling it:

```clojure
(def bad "(ns app) (defn handle [] (helper))")    ; helper removed, still called
(reload/stage "app" bad)
(def coh (reload/coherence [["app" bad]]))
(def held (reload/commit))
(Process/sleep 10)
(reset! halt? true) (Process/sleep 10)
(println "── incoherent edit ──" (:status held)
         " coherence-errors=" (count coh) " handle STILL→" (app/handle))
```

`reload/coherence` is the predicate pass exposed for inspection: it takes the
staged pairs and returns every reason the bundle does not fit. Here `app` is *in*
the bundle, which means it is a **whole-namespace replacement** — under that
semantics `helper` is genuinely removed even though the live image still holds
it, so `(helper)` is an unqualified same-ns call to a name the new source no
longer provides → one `:dangling` error. `(count coh)` is `1`.

`reload/commit` runs the same pass and, finding an error, **holds** the bundle:
`(:status held)` is `:held`, the error is printed, and — the point — `(app/handle)`
**still returns `"v1"`**. The old code is untouched. You see both the gate's report
and the proof it did nothing:

```
reload: bundle HELD — 1 reason(s); old code still serving:
  [dangling] undefined var: app/helper — nothing in the bundle or image defines it
── incoherent edit ── :held  coherence-errors= 1  handle STILL→ v1
```

### Step 5 — inspect the stream and assert

```clojure
(def seen (deref results))
(def answers (distinct seen))
(println "── request stream ──" (count seen) "reqs, answers=" (pr-str answers))
```

Every value the concurrent caller ever observed, across two app commits, a stdlib
commit, and a refused edit, is one of the real answers:

```
── request stream ── 30 reqs, answers= ["v1" "v2"]
```

(the request count is just however many 2 ms iterations fit in the spike's ~60 ms
of sleeps — the assertion only requires `> 5`; the `(pr-str answers)` set is the
substantive output)

(`"v1"` appears before Step 2 and again during Step 4's *coherent* edit, whose
`handle` also returns `"v1"`; the `distinct` set is therefore `["v1" "v2"]`.) The
assertion block then checks the whole story:

```clojure
(def ok (and (= :applied (:status app-up))      ; app hot-updated
             (= :applied (:status lib-up))      ; bl/stdlib hot-updated
             (= "lib-2" (mylib/version))
             (= 1 (count coh))                  ; the bad edit is incoherent (dangling)
             (= :held (:status held))           ; and REFUSED — old code serves
             (> (count seen) 5)
             (every? (fn [x] (or (= x "v1") (= x "v2") (= x "v1") (String/starts_with? x "v"))) seen)))
(println "")
(println (str (if ok "PASS" "FAIL") " 04_hot_reload  (app+bl hot; incoherent HELD)"))
```

Note the shape of the guarantee the stream *actually* enforces: the loop appends
only values returned by `(app/handle)`. If a swap ever left the var briefly
undefined, the call would raise and the spawned process would die — the loop's
mere survival to `(reset! halt? true)` is the real evidence that no call ever
observed a missing var. The trailing `(String/starts_with? x "v")` clause is
looser than it looks (every plausible answer begins with `"v"`), so treat the
printed `answers` as the honest evidence and the `every?` as belt-and-braces;
[Exercise 4](#exercises) tightens it.

## What's real vs modelled

**Real — the gate itself.** This spike drives the production `reload` module
(`priv/std/reload.bl`), not a model:

- `reload/set-enabled!` / `reload-enabled?` — the real mutation policy. A
  packaged image refuses mutating reloads unless `BEAM_LISP_RELOAD=1`; a refused
  bundle is *held*, identically to an incoherent one.
- `reload/stage` — real: buffers a namespace's source into the pending bundle
  (`:staged`) without touching the live image.
- `reload/coherence` — real, and exposed exactly for demos like this: the static
  predicate pass (`dangling-errors`, `promise-errors`, `removal-errors`,
  `type-errors`, `require-cycle-errors`) over the staged sources plus the live
  image's public names.
- `reload/commit` — real: prove coherent → apply atomically; else hold. The
  apply path is `apply-bundle!`, which evaluates into `:global` (this spike does
  not rebind the commit target, so it commits into the one running image) and
  lands each `defn` as a `Link.defvar` in place — the atomic per-var swap. A
  dropped name is genuinely removed via `BeamLisp.Env/undefine_var`, which is why
  the `:dangling` error fires. The namespace-level (`app` in the bundle ⇒ only
  its new names count) semantics is real, and is precisely what makes the
  renaming-ethics case — and the held outcome here — correct.
- The coherence predicates rest on shipped machinery: the dangling check uses the
  deferral layer's unknown-call collector; the type check uses
  `deferred/check-file-deferring`; the cycle check uses `source-graph/cycles`
  (the same owner the build fails on).

**Modelled / simplified — be precise:**

- **`app` and `mylib` are toy namespaces.** `(defn handle [] "v1")` and
  `(defn version [] "lib-1")` are stand-ins. `mylib` demonstrates that the
  *mechanism* is identical for app code and language-shipped namespaces — it is
  **not** an actual stdlib namespace, and no real stdlib file on
  `BEAM_LISP_PATH` is edited. The spike proves the door is the same for both; it
  does not ship a stdlib upgrade.
- **The "concurrent traffic" is cooperative, not preemptive.** The stream is one
  BEAM process with `(Process/sleep 2)` between calls. That exercises the claim
  that calls keep resolving correctly *across* commits, and that the loop never
  dies on a missing var. It does **not** stress-test atomicity against a true
  parallel race: a swap interleaves at scheduler yield points, not mid-call on
  another core. The atomicity guarantee rests on `Link.defvar`'s in-place var
  swap (real), not on this loop's scheduling.
- **No deploy trigger is involved.** The spike stages edits by hand. The design
  doc's L1 pipeline — `reload/ward` (load the new code beside the old),
  `reload/migrate` (state migration), a `z3` contract check, and canary-as-datom-
  branch — is *not* exercised here. Those modules exist under `priv/std/reload/`,
  but this spike drives only `stage`/`coherence`/`commit`. The message-migration
  predicate (`reload.migrate`, attached via `reload/attach`) is likewise absent;
  a bundle that changes a live process's message contract is not tested here —
  that is spike `08`'s territory (z3-proven migrations).
- **One commit target.** In production and normal dev the target is `:global`
  (as here). Under tests the same gate is pointed at an isolated ward fork via
  `with-target`; this spike does not, so it mutates the real running image by
  design.

The honest boundary, in one line: **the reload coherence gate, the atomic
per-var swap, namespace-level replacement, and the prod policy are the real
organ, exercised as-is; what is modelled is the trivial app/stdlib content, the
cooperative (not preemptive) caller, and the absent deploy/ward/migrate/z3
pipeline around the gate.**

## Run it

```
./blx run research/vps_spike/04_hot_reload.bl
```

Expected final line (copied from the spike):

```
PASS 04_hot_reload  (app+bl hot; incoherent HELD)
```

Cold start costs ~10-15s (`blx` JIT warmup) — that latency is boot, not work.
The spike is also part of the default sweep: `research/vps_spike/run.sh` runs it
(and `01`–`08`) and prints the same `PASS`/`FAIL` line.

## Exercises

1. **Make the bad edit coherent.** Change `bad` to
   `(ns app) (defn helper [] 1) (defn handle [] (helper))` — `helper` is kept and
   defined, so nothing dangles. Predict: `(count coh)` → `0`, `(:status held)` →
   `:applied`, and `(app/handle)` → the *integer* `1` (this `handle` is
   `(helper)`, not the `(str "v" (helper))` of the earlier commit). Then work out
   whether the `every?` clause still passes when `results` contains integers and
   strings mixed — and what that tells you about how tight the original
   assertion really was.

2. **Exercise the cross-namespace half of the renaming ethics.** After the
   coherent Step 4 commit, stage and commit a second namespace that calls
   `app/helper` — e.g. `(ns other (:require [app])) (defn go [] (app/helper))`.
   Now stage an `app` that drops `helper` and commit. Predict: coherence reports
   an *additional* `:removal` error (a live caller outside the bundle still
   reaches the dropped var), and the bundle is still `:held`. Then stage `other`
   in the *same* bundle (minus its call) and predict it lands `:applied`.

3. **Prove the prod policy is a separate reason to hold.** Insert
   `(reload/set-enabled! false)` before one of the coherent commits (e.g. the
   mylib `lib-2` stage). Predict: `(:status lib-up)` becomes `:held` with an
   error of `:kind :policy` — *not* an incoherence — and `(mylib/version)` stays
   `"lib-1"`. Then re-enable and confirm the same stage applies. This is why
   "held" and "incoherent" are not synonyms.

4. **Tighten the stream assertion.** Replace the trailing
   `(String/starts_with? x "v")` clause with an explicit set membership
   (`(contains? #{"v1" "v2"} x)`), then deliberately break a swap (e.g. stage an
   `app` whose `handle` returns `"vX"` and commit it). Predict which clause of
   `ok` flips to false, and whether the printed `answers` reveals the bad value
   first. This shows how much the loose clause was hiding.
