# 11 — ssh access: the door admits you into a capped REPL, capped by your token

An ssh connection is admitted by the same token machinery spike 10 built: the
token opens a heap-bounded session, and the modules it never granted are not
merely denied at runtime — they do not compile.

## The claim

`docs/design/vps/devops.md` §*Identity, secrets, blast radius* (the spike header
calls it "§access") states the whole access story in one line: "ssh key →
Biscuit token → attenuation → capped env fork → RLS-scoped queries", and that
"nobody sshes in to edit a file." `docs/design/vps/README.md` says the same from
the other side — `executor/ssh` on `:2222` is where "humans and agents get a
capped REPL", and a human receives "exactly what a human receives: a capped REPL
behind a token." The companion claim is `incident-ritual.md` §*On-call
ergonomics*: "your REPL is capped: an exhausted operator with production access
still cannot `System/halt` the node — the capability stack is the guardrail when
judgment is weakest." This spike proves that the front door is the token: one
engine admits a token into a capped session, a forged token forks nothing, a
user's sessions are bounded by an operator-set ceiling, and inside the session
the token's grants are the language.

## The idea

A conventional ssh login lands you as a *uid*, carrying every right that uid
has. Root can `halt`, read `/etc/shadow`, rewrite the disk; a normal user
carries a home directory and a shell whose every syscall is gated by the kernel
at runtime. The dangerous actions are all *sayable* — you can type them, they
just get refused when the guard checks. That leaves the familiar gap: a guard
that was skipped, a path that forgot the ACL, a credential pasted into the wrong
terminal at 03:00.

Here the "shell" is a REPL, and the vocabulary of that REPL is fixed by the token
you present. The eval compiles **inside** an env whose capability set is the
token's grants; a module the token never granted has no binding, so the source
that names it does not compile. The blast radius is not "what the guard would
let you do" but "what the language lets you say":

```
module ∈ caps  → compiles → may run
module ∉ caps  → does not compile → unspeakable
```

Two consequences matter for devops. First, the guardrail is structural, so it
does not depend on the operator being careful — the exhausted on-call engineer
cannot save the line that halts the node. Second, the *same door* serves humans
and agents: an agent's leaked token is bounded to exactly the calls the token
granted, no different from a human's session.

The ceilings around that vocabulary are separate and deliberate. The token grants
**rights** (which modules you may name); the operator's `policy` sets **limits**
(how much memory you may hold). A token is not allowed to raise its own ceiling,
because attenuation only narrows rights — if limits rode the token, "attenuate"
would become a resource-escalation path. So `admit` takes the policy from the
operator and the caps from the token, and never the reverse.

## Walkthrough

The spike is a namespace `vps.ssh-access` that requires the real
`executor.sandbox` (`sb`), `auth`, and `env`. Read it top to bottom.

### Step 0 — a root key, and the operator's ceilings

```clojure
(def root (auth/keypair))
(def rootpub (auth/public root))

;; the operator's per-user ceilings (executor.sandbox policy shape)
(def policy {:mem-per-session 2000000 :mem-per-user 8000000})
```

`auth/keypair` is the root of trust for the node — the key that signs the
fleet's tokens. `rootpub` is the public half, which `admit` verifies against.
`policy` is the operator's map: each session may reserve two million words, and
one user's live sessions may sum to eight million. These are **limits**, set by
the host, not facts a token can assert.

### Step 1 — alice's token: an identity and one capability

```clojure
(def alice (auth/issue root [["user" "alice"] ["right" "Elixir.String" "all"]]))
```

`auth/issue` mints a real Ed25519 Biscuit from a list of facts. Two facts go in:
`["user" "alice"]` is who the token speaks for, and
`["right" "Elixir.String" "all"]` is the single capability — the right to call
the `Elixir.String` module. Nothing grants `System`, `File`, or anything else.
This is the same token shape spike 10 minted; the front door will consume it
directly.

### Step 2 — admit: the token opens a capped, heap-bounded session

```clojure
(def reg (sb/registry))
(def adm (sb/admit reg rootpub alice (auth/context {:policies [(auth/allow [])]}) policy nil))
(def session (:ok adm))
(println "── admit (token → capped session) ──")
(println "  admitted principal:" (:user session)
         "  heap-words:" (:mem-per-session (:policy session)))
```

`executor.sandbox/registry` is the per-user accounting atom — one per executor
host. `sb/admit` is the same admission function `executor.ssh`'s session
starter calls, with the same authorizer context shape the daemon builds
(`(auth/context {:policies [(auth/allow [])]})`, an `allow if true` policy). Its
arguments are, in order: the registry, the root public key, the token, the
authorizer context, the operator policy, and a datom conn (here `nil` — no
audit recording on this run).

Inside `admit`, `auth/caps-for` first authorizes the token under `rootpub`; only
on `:allow` does it read the `user` fact (`auth/verified-facts`) and check the
per-user ceiling. On success it forks a capped env and reserves the memory.

The two printed lines are the proof of admission: the principal came from the
*verified* token (an unverified token can never assert an identity), and the
session carries the resolved per-session heap word-count.

`sb/admit` returns `{:ok session}`, and `session` is
`{:user :env :policy :registry :disk}` — the `:env` is a real `env/fork` of
`:global` bounded to the granted caps, so every later eval in the session hits
the compile gate.

### Step 3 — fail closed: a forged token forks nothing

```clojure
(def evil-root (auth/keypair))
(def forged (auth/issue evil-root [["user" "root"] ["right" "Elixir.System" "all"]]))
(def forged-adm (sb/admit reg rootpub forged (auth/context {:policies [(auth/allow [])]}) policy nil))
(println "── fail closed (forged token) ──")
(println "  forged admit:" (pr-str forged-adm))
```

A second key, `evil-root`, mints a token that *claims* to be `root`'s and asks
for `Elixir.System`. Presented to the real node's `rootpub`, the signature chain
does not verify, so `auth/caps-for` returns `{:error {:verdict :deny
:reason :invalid-signature}}` and `admit` returns
`{:error {:reason :invalid-signature :stage :authorize}}` — **before** it reads
any identity fact, checks any quota, or forks anything. The printed
`{:error {…}}` is the whole answer: no session, no env, no effect. Fail-closed
means the error is the outcome, not an exception someone might forget to catch.

### Step 4 — the per-user ceiling: the fifth session is refused

```clojure
;; per-user 8M / per-session 2M ⇒ 4 sessions fit, the 5th is over quota
(def more (map (fn [_] (sb/admit reg rootpub alice
                         (auth/context {:policies [(auth/allow [])]}) policy nil))
               (range 4)))
(def over (last more))
(println "── per-user memory quota ──")
(println "  5th concurrent session:" (pr-str (if (:ok over) :admitted (:error over))))
```

Admission already succeeded once in Step 2, so the registry holds a two-million
reservation for `alice`. The four more admits bring the running total to 4M, 6M,
8M — and the fourth of these, which is the *fifth session overall*, would make it
10M against the 8M ceiling. `admit` refuses it with
`{:error {:reason :mem-quota-user :stage :admit …}}`, so the printed line is
`:error`. The refusal is a *pre*-reservation check: no env is forked, no tally is
raised. Limits are enforced at the door, not after the resource is spent.

### Step 5 — the `bl>` REPL: the token's caps are the language

This is where the spike is deliberately explicit about a real defect. The
comment above the bridge says it plainly:

```clojure
;; The stock admit env denies even granted modules on this drop (see header),
;; so build the session env with the caps bridge to show the INTENDED behaviour.
(defn cap->str [c] (erlang/atom_to_binary (erlang/element 1 c)))
(def caps (mapv cap->str (:ok (auth/caps-for rootpub alice (auth/context {:policies [(auth/allow [])]})))))
(def repl-env (env/fork :global {:caps caps :max-heap-words (:mem-per-session policy)}))
(defn repl [src] (try {:ok (env/with-env repl-env (fn [] (env/eval src)))}
                      (catch e {:denied (ex-message e)})))
```

`cap->str` takes one caps entry `c`, pulls its first element (the resolved
**module atom**), and converts it to a binary — so a `{ModuleAtom op}` tuple
becomes the string `"Elixir.String"`. `auth/caps-for` is called again to get
alice's resolved entries, each is bridged to a module-name string, and the
result for a token granting `Elixir.String` is `["Elixir.String"]`.

Why the bridge at all is the honest finding (covered in full in *What's real vs
modelled*): the stock `admit` path forks with the *resolved* entries, and on
this drop those do not match what the compile gate tests, so the stock session
env denies even the module the token granted. The bridge restores the **author
shape** — a bare module-name string — which `env/fork` resolves to the bare
module atom the gate accepts.

`env/fork :global {:caps ["Elixir.String"] :max-heap-words 2000000}` is
therefore a real fork of the substrate root narrowed to one module, with the
operator's per-session heap bound. `repl` then binds that env for the duration
of the thunk and calls `env/eval` — the real compile-and-run path — capturing
either `{:ok value}` or `{:denied message}`.

Three probes against that one session env:

```clojure
(def granted (repl "(String/upcase \"deploy\")"))     ; token granted String
(def halt    (repl "(System/halt 0)"))                ; never granted → unspeakable
(def fs      (repl "(File/read \"/etc/shadow\")"))    ; never granted → unspeakable
(println "  bl> (String/upcase \"deploy\")  →" (pr-str granted))
(println "  bl> (System/halt 0)            →" (:denied halt))
(println "  bl> (File/read \"/etc/shadow\") →" (:denied fs))
(println "  node still alive after halt attempt:" (+ 1 1))   ; we're still running
```

- `String` **is** in the set, so the interop reference resolves, the form
  compiles, and it returns `"DEPLOY"` — `{:ok "DEPLOY"}`.
- `System` is **not** in the set, so `(System/halt 0)` does not compile;
  `halt` is `{:denied <message>}`. The line that kills the node is not worth
  refusing — it never becomes executable code.
- `File/read "/etc/shadow"` is the same: `File` is not granted, the reference
  does not resolve, and `fs` is `{:denied <message>}`.

The last print is a liveness canary: reaching line `(+ 1 1)` proves execution
proceeded past the halt attempt. It is deliberately trivial — if the halt had
compiled and run, there would be no line to print. The node survives, and the
run continues.

### Step 6 — the verdict

```clojure
(def ok (and (= "alice" (:user session))              ; admitted the right principal
             (contains? forged-adm :error)            ; forged token forks nothing
             (not (:ok over))                          ; quota refuses the 5th session
             (= :mem-quota-user (:reason (:error over)))
             (= "DEPLOY" (:ok granted))               ; granted capability runs
             (:denied halt)                            ; node-halt unspeakable
             (:denied fs)                              ; fs unspeakable
             (= 2 (+ 1 1))))                           ; and the node is still alive
(println (str (if ok "PASS" "FAIL") " 11_ssh_access  (token → capped REPL; fail-closed; quota)"))
```

Seven-plus conjuncts, each an observable fact rather than a grep of a message:
the verified principal is `"alice"`; the forged admit carries an `:error`; the
fifth session is refused **for the specific reason** `:mem-quota-user` (not any
error); the granted call *executed* (`"DEPLOY"`); both dangerous calls were
denials; and the canary held. The verdict is a single `and` over those facts.

## What's real vs modelled

The spike's value is that most of its surface is the engine the ssh daemon
actually runs; the honesty is in naming exactly where it stops short.

**Real, exercised as-is:**

- `auth/issue`, `auth/keypair`, `auth/public` — the token is a real signed
  Ed25519 Biscuit; the forged token is signed by a *different* key. Nothing here
  is a stub.
- `auth/context` + `auth/allow` — the same authorizer context and `allow if true`
  policy `executor.ssh`'s session starter builds.
- `auth/caps-for` — the real authorize-then-project call. The whole Biscuit
  chain (signature verification, block scoping, deny-overrides, the `:verdict`
  reason) decides whether a caps set is ever produced.
- `executor.sandbox/registry` and `executor.sandbox/admit` — the actual
  admission function `executor.ssh/start-session` calls, with its actual
  argument order. Identity is read from `auth/verified-facts` *after* the
  signature verifies; the per-user memory quota is enforced; the forged-token
  path returns a fail-closed `{:error {:reason :invalid-signature :stage
  :authorize}}`.
- `env/fork`, `env/with-env`, `env/eval` — the real capability gate. The fork's
  caps are a structural intersection; the eval compiles against them; a denied
  reference is a genuine compile error, not an injected stub.

**Modelled, simplified, or honestly defective — read these carefully:**

- **No live SSH, no network, no store.** `executor.ssh` is not booted. The
  transport (OTP `:ssh`, the host-key `:ssh_server_key_api` callbacks,
  `is_auth_key`'s enrolled-key authorization) and the token store
  (`executor.store/token-for`, which in production maps an authenticated ssh key
  to its base64 token) are **not** exercised. The spike calls the same engine
  functions the daemon calls, in-process, with the token passed directly.
- **The caps-for tuple-vs-string drop bug — this is the honest finding.** On
  this drop `auth/caps-for` returns the granted module as a **resolved tuple**
  `{:Elixir.String, :all}` for alice's `["right" "Elixir.String" "all"]` fact,
  but the compile gate's membership test accepts either a **bare module atom**
  or `{module, <specific op>}` — and `:all` is never the specific op a call site
  reports (`String/upcase` has no op-table entry, so its op is `nil`). So the
  tuple matches nothing, and the stock `admit` env denies even the module the
  token granted. **It fails SAFE — over-restrictive, never unsafe:** the failure
  mode is "granted calls do not compile", not "ungranted calls do". The spike
  shows the real `admit` first (Steps 2–4), then applies the one-line caps
  bridge — `cap->str` re-presents each resolved tuple as the module-name string
  the gate resolves to a bare module — to demonstrate the **intended** grant:
  granted runs, ungranted is unspeakable. (The projection only produces a bare
  module name when the token's op is the generic `"call"`; a non-`"call"` op like
  `"all"` becomes a `[module op]` pair and lands on the mismatched tuple path.
  That asymmetry is the defect, and the bridge is the fix's shape.)
- **The REPL is not `executor.sandbox/run`.** The production `sb/run` spawns a
  `spawn_monitor`'d child that sets `process_flag(:max_heap_size, %{size: words,
  kill: true})` and then runs `env/with-env` + `env/eval`, returning
  `{:ok value} | {:error …}`; a memory blowout kills only that eval process and
  surfaces as `{:error {:reason :memory-quota}}`. The spike's `repl` evals in the
  **current** process, so the fork's `:max-heap-words` is recorded but the
  hard per-eval kill is **not** exercised here. The per-*user* ceiling *is*
  exercised — but at admission (Step 4), not as a live OOM.
- **The quota is a reservation, not a measurement.** `admit`'s ceiling sums each
  session's *reserved* `:mem-per-session` budget (`:mem-used` in the registry),
  not the live heap a session actually holds. It bounds worst-case concurrent
  reservations; it does not measure allocations.
- **Disk quota (`executor.sandbox/account-write!`) is not exercised.** No
  session is granted `File`, and `policy` carries no disk keys — the resolved
  disk ceilings default to `0` (fail closed), so there is nothing to write and
  nothing to bill.
- **No audit datoms.** `admit` is called with `conn = nil`, so neither the admit
  decision nor the forged denial is recorded. The real daemon can pass a datom
  conn and record per-command verdicts; this run does not.
- **The probes are illustrative.** No node is halted and no secret is read —
  the sources never compile, so nothing is attempted. If `System` or `File`
  *were* granted, you would see a runtime outcome instead of a compile denial.
- **Wrong-principal (confused-deputy) is out of scope.** The spike covers the
  *unverified* token (wrong root). The complementary check — alice's key cannot
  authenticate as bob — lives in `executor.ssh/is_auth_key`'s owner match and is
  not on this spike's path.
- **The denial message is Elixir's.** `repl` catches whatever `env/eval` raises
  and reports `ex-message`; the assertions check only that a denial is non-nil,
  so they neither depend on nor pin the wording. A real run prints a raw
  compiler error, not a designed refusal.
- **`:global` is assumed to hold the granted module.** The narrowing claim rests
  on `:global` having at least `String`; the spike takes that as given and
  narrows downward.

## Run it

```
./blx run research/vps_spike/11_ssh_access.bl
```

Cold start costs ~10–15s (JIT warmup) before any output — that latency is boot,
not work. Run it from the worktree root so `blx` finds this checkout's stdlib on
`BEAM_LISP_PATH`. The body prints four sections and then the verdict:

```
── admit (token → capped session) ──
  admitted principal: alice   heap-words: 2000000
── fail closed (forged token) ──
  forged admit: {:error {:reason :invalid-signature :stage :authorize}}
── per-user memory quota ──
  5th concurrent session: :error
── the bl> REPL (caps from the token) ──
  bl> (String/upcase "deploy")  → {:ok "DEPLOY"}
  bl> (System/halt 0)            → <denial message>
  bl> (File/read "/etc/shadow") → <denial message>
  node still alive after halt attempt: 2
```

and the run ends on the exact final line:

```
PASS 11_ssh_access  (token → capped REPL; fail-closed; quota)
```

(That is one line; the two spaces before `(token` are the spike's literal
formatting.)

## Exercises

1. **Rewind the quota and predict the refusal boundary.**
   Change `policy` to `{:mem-per-session 2000000 :mem-per-user 10000000}`.
   Predict: five sessions sum to 10M, which now *fits* (`mem-after = 10M` is not
   `> 10M`), so `more`'s last admit succeeds, `(:ok over)` is truthy, and the
   assertion `(not (:ok over))` fails → the run ends `FAIL`. Push the ceiling to
   `8000000` again and confirm the fifth is refused with `:mem-quota-user`. This
   pins the comparison as strict-greater-than.

2. **Change the grant to one the gate can actually match — predict the change in
   the *stock* path.**
   In `alice`'s token, use the generic op `"call"` instead of `"all"`:
   `["right" "Elixir.String" "call"]`. Predict: `auth/caps-for` now returns a
   bare module name rather than a `{Module, :all}` tuple, so the *stock* `admit`
   env itself grants `String` and the bridge becomes unnecessary — the REPL
   lines are unchanged, but the reason changes from "the bridge fixed it" to "the
   projection already produced the author shape." This isolates the drop bug to
   the non-`call` op path.

3. **Grant the dangerous module and watch the *kind* of failure change.**
   Add `["right" "Elixir.File" "write"]` to `alice`'s facts and add
   `"Elixir.File"` to the bridge's spec. Predict: `(File/read "/etc/shadow")`
   stops being a compile denial; if it errors at all it errors at **runtime**
   (a filesystem/permission error, since `read` may not be the granted op), and
   the assertion `(:denied fs)` fails → `FAIL`. The guardrail moved from
   "unspeakable" to "speakable but OS-blocked" — precisely the conventional model
   this spike argues against. (Do **not** grant `"Elixir.System"` while probing
   halt: once it compiles, `System/halt 0` would actually stop the VM.)

4. **Probe the quota with different-sized sessions.**
   Set `policy` to `{:mem-per-session 3000000 :mem-per-user 8000000}`. Predict:
   sessions 1 and 2 reserve 3M and 6M; the third would make 9M > 8M and is
   refused — so with the pre-existing Step-2 admit plus one more from `more`, the
   refusal now lands on `more`'s *second* element. The assertion still holds
   (`over` = `(last more)` is an error either way), but the run now proves the
   ceiling is a sum of reservations, not a fixed session count.
