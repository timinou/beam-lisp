# 02 — Capabilities: the blast radius is a compile error

A capped env fork makes an ungranted right *un*speakable — the code that would
abuse it does not compile, and attenuation can only ever narrow.

## The claim

`docs/design/vps/devops.md` §*Identity, secrets, blast radius* makes one
capability story carry the whole security surface: "ssh key → Biscuit token →
attenuation → capped env fork → RLS-scoped queries", and then the strong
sentence — "Secrets are vars in env forks that sibling envs cannot name — the
compile gate makes them unspeakable." The companion claim in
`incident-ritual.md` §*On-call ergonomics* is the same mechanism seen from the
human side: "an exhausted operator with production access still cannot
`System/halt` the node — the capability stack is the guardrail when judgment is
weakest." This spike proves the load-bearing layer of both: a fork of the env
gate where a granted call runs, an ungranted call never reaches execution, and a
child env can only hold a subset of its parent's rights.

## The idea

A conventional permission system is a *runtime* check. The syscall, the shell
command, the admin endpoint all exist; you call one, a gatekeeper inspects
credentials, and returns 403. The right is *sayable* — the dangerous code is
perfectly expressible, it just gets refused when it runs. That leaves an entire
class of failure open: a check that was skipped, a path that forgot to consult
the ACL, a confused-deputy call that inherits rights it should not have.

bl inverts this. An env carries a **capability set** — the host modules its code
may name. `(String/upcase "deploy")` is not a library call that a runtime guard
waves through; it is an interop reference the *compiler* resolves against the
env's caps. If `String` is not in the set, the reference has nothing to bind to:

```
call is in caps  → compiles → may run
call ∉ caps      → does not compile → unspeakable
```

So the blast radius of a hostile or sleep-deprived actor is not "what the guard
would let them do" but "what the language lets them say". There is no code path
to audit, because there is no code path at all. This is why the doc calls the
secrets *unspeakable*: a sibling env never had the module, so it can never
`File/read` the var, and no `chmod 600` file exists to leak.

**Attenuation** is the second half. `env/fork parent {:caps …}` produces a child
whose effective set is `parent ∩ spec` — intersection, structurally. A child can
only ever hold a subset of what its parent held. There is no grant-a-child-more
operation to exist, so privilege escalation through forking is not a bug you
defend against; it is a shape that cannot be written. A leaked agent token
attenuated to one narrow cap set can do exactly its one thing and cannot be
coaxed into naming anything else.

This matters for devops because the weakest component is not the code — it is
the human at 03:00, and the credentials that get pasted into the wrong terminal.
A guardrail that lives in the compiler does not need anyone to be careful.

## Walkthrough

The spike is a namespace `vps.capabilities` that requires the real `env`
module, then builds two envs, probes them, and asserts. Read it top to bottom.

### Step 0 — the probe helper

```clojure
(defn compiles? [e src]
  ;; try to compile+run `src` inside env `e`; {:ok v} or {:denied msg}
  (try {:ok (env/with-env e (fn [] (env/eval src)))}
       (catch ex {:denied (ex-message ex)})))
```

Everything hangs off this four-liner. `env/with-env` binds env `e` in *this*
process for the duration of the thunk; `env/eval` then compiles and runs the
source string **inside that binding** — and because the capability gate is part
of compilation, the binding is what decides whether the source compiles at all.
The `try`/`catch` collapses both outcomes into one value: a success is
`{:ok v}`, and a raised error (which is how a compile denial surfaces) is
`{:denied message}`. That single shape is why the rest of the file can branch on
`:ok` / `:denied` uniformly — the *reason* something didn't happen and the
*result* of something that did are the same kind of data.

Note carefully: the denial is caught, not pre-checked. The spike does not ask
"am I allowed?" and then decide whether to run; it simply tries to compile, and
a right that was never granted fails as a real compilation error.

### Step 1 — two envs, one narrowing

```clojure
;; ── an operator's session env: string + list ops, nothing else ──────────────
(def operator (env/fork :global {:caps ["Elixir.String" "Elixir.Enum"]}))

;; a deploy agent, attenuated further: string ops only
(def deploy-agent (env/fork operator {:caps ["Elixir.String"]}))
```

`operator` is a fork of `:global` (the substrate root) narrowed to two modules:
`Elixir.String` and `Elixir.Enum`. It is who an on-call human lands as: enough to
inspect and transform, nothing that can touch the node.

`deploy-agent` forks **from `operator`**, not from `:global`, with a spec of one
module. Its effective caps are `operator ∩ {"Elixir.String"}` = `{"Elixir.String"}`.
`Enum` is gone — the parent had it, the child dropped it, and no spec the child
could pass would put it back. This is the whole attenuation story in one line.

The cap names are **strings** (`"Elixir.String"`), not quoted module names —
`env/fork` interns them itself, and (see the next section) a string that names no
loaded module simply vanishes from the set rather than being trusted.

### Step 2 — the operator env: granted runs, ungranted is unspoken

```clojure
(def op-ok  (compiles? operator "(String/upcase \"deploy\")"))
(def op-halt (compiles? operator "(System/halt 0)"))         ; must be denied
(def op-file (compiles? operator "(File/read \"/etc/shadow\")")) ; must be denied
```

Three probes, one env, three different fates:

- `String/upcase` — `String` is in `operator`'s caps, so the interop reference
  resolves, the form compiles, and it returns the string. `op-ok` is
  `{:ok "DEPLOY"}`.
- `System/halt 0` — the call that would kill the node. `System` is not in the
  set, so the reference does not resolve; compilation fails and `op-halt` is
  `{:denied …}`. The operator *cannot save the source that halts the machine*,
  let alone run it.
- `File/read "/etc/shadow"` — the classic secret grab. Same story: `File` is not
  in the set, so it never compiles. `op-file` is `{:denied …}`.

The printed lines show both halves at once:

```clojure
(println "  String/upcase   →" (pr-str op-ok))
(println "  System/halt     →" (:denied op-halt))
(println "  File/read shadow→" (:denied op-file))
```

`pr-str` on the granted one prints the actual value `{:ok "DEPLOY"}` — the proof
that the allowed path really executed. The denied two print their denial
message: the assertion later only cares that a denial *exists*, but printing the
message keeps the run legible — you see the compiler complaining about a name
the env never had.

### Step 3 — the attenuated child: still allowed, now narrower

```clojure
(def da-str  (compiles? deploy-agent "(String/upcase \"ok\")"))   ; still allowed
(def da-enum (compiles? deploy-agent "(Enum/count [1 2 3])"))     ; parent had it, child dropped it
```

Two probes against `deploy-agent`, and together they are the narrowing proof:

- `String/upcase` still compiles in the child — attenuation did not cost it the
  grant it kept. `da-str` is `{:ok "ok"}`.
- `Enum/count` is denied — even though `operator` granted `Enum`, the child's
  spec did not carry it, and the intersection dropped it. `da-enum` is
  `{:denied …}`.

The `println` uses `(or (:ok da-enum) (:denied da-enum))` so the run shows
*whichever* happened — if the narrowing were broken and `Enum` leaked through,
you would see a value, not a denial, right in the output.

### Step 4 — the assertions and the verdict

```clojure
(def ok (and (= "DEPLOY" (:ok op-ok))            ; granted right runs
             (:denied op-halt)                   ; node-halt unspeakable
             (:denied op-file)                   ; fs unspeakable
             (= "ok" (String/downcase (or (:ok da-str) ""))) ; child keeps its grant
             (:denied da-enum)))                 ; attenuation only narrows
```

Five conjuncts, each an observable fact, not a grep of a message:

1. the granted right ran and returned `"DEPLOY"`;
2. the node-halt did not compile;
3. the filesystem read did not compile;
4. the child kept the grant it inherited (checked by round-tripping `"ok"`
   through `downcase`, so the test proves the call *executed*, not merely that
   it was allowed);
5. the child shed the grant the parent had.

```clojure
(println (str (if ok "PASS" "FAIL") " 02_capabilities  (blast radius = compile error)"))
```

The verdict is a single `and` over those facts. Nothing here inspects the *text*
of a denial, because a denial is only ever trusted as "it did not happen" — the
claim is about absence of capability, and absence is what is asserted.

## What's real vs modelled

This spike's honesty rests on the fact that the gate it exercises is the gate
the runtime actually uses; only the *layers around it* are trimmed.

**Real, exercised as-is:**

- `env/fork` — `priv/std/env.bl::fork`, which delegates to
  `BeamLisp.Env/fork`. The spike's `(env/fork :global {:caps …})` and
  `(env/fork operator {:caps …})` are genuine forks of the runtime's env
  registry, and the child's caps are genuinely `parent ∩ spec`.
- `env/with-env` — `priv/std/env.bl::with-env` → `BeamLisp.Env/with_env`. The
  binding really is installed for the thunk and really governs the compilation
  that follows.
- `env/eval` — `priv/std/env.bl::eval` → `BeamLisp/eval`. This is the real
  compile-and-run path, and the capability check that fires on an ungranted
  reference is the real gate inside that compilation, not a stub the spike
  installs.
- Caps **resolution discipline**, which lives in `priv/std/env.bl::caps-entry`
  and `caps-spec`: cap name strings are interned through `interop/module`
  (`binary_to_existing_atom`). A string naming no loaded module drops out of the
  set — fail closed — and a hostile string can never grow the atom table. The
  spike benefits from this even though it never writes a bogus name.

**Modelled in miniature / simplified — state these plainly:**

- **Only the env-fork hop of the identity stack is here.** The design's chain is
  "ssh key → Biscuit token → attenuation → capped env fork → RLS". This spike
  starts at the fourth link. When it says "a right the token never granted", read
  *token* as "the cap spec the env was forked with". The Biscuit minting,
  attenuation, and authorization that produce that spec are proven in spikes 10
  and 11, not here.
- **The resolved-tuple path is not exercised.** `env/fork`'s author shape is
  module-name *strings*; `auth/caps-for` returns *resolved* entries
  (`{ModuleAtom op}` tuples). Spike 11 documents the mismatch honestly: the stock
  `admit` path forks an env where even *granted* modules are denied — a fail-safe
  failure (too restrictive), never an unsafe one — and bridges it with a
  tuple→string coercion. In `env.bl`, `caps-entry` is deliberately idempotent so
  an already-resolved tuple passes straight through instead of being
  re-normalized to `nil` (that re-normalization would silently empty a sandbox).
  This spike forks with author-shaped strings, so it proves the fork/attenuation
  semantics but does **not** itself replay the resolved-entry handoff. That
  handling is real in `caps-entry`; it is just not on this spike's path.
- **Whole-module grants only.** `caps-entry` also accepts `[module op]` pairs for
  op-scoped grants (e.g. `File` read-only), and `env/allowed?` reports the module
  reachable for an op-scoped grant. The spike grants bare module names
  (`"Elixir.String"`), so op-level narrowing is *not* demonstrated — every grant
  here is all-or-nothing at the module.
- **The cap choice is illustrative.** `String`/`Enum` as the granted set and
  `System`/`File` as the denied set are picked to make a legible story. No secret
  is actually read and no node is actually halted; the spike only demonstrates
  that those sources do or do not compile.
- **The denial message is Elixir's, not bl's.** `compiles?` catches whatever
  `env/eval` raises and reports `ex-message`. The assertions check only that a
  denial is non-nil, so they neither depend on nor pin the exact wording — if you
  print the run you will see a raw compiler error, not a designed refusal
  message.
- **`:global` is assumed to be the broad substrate root.** The claim that
  `operator` is a genuine narrowing depends on `:global` holding at least
  `String` and `Enum`; the spike treats that as given and narrows downward.

## Run it

```
./blx run research/vps_spike/02_capabilities.bl
```

Cold start costs ~10-15s (JIT warmup) before any output appears — that latency is
boot, not work. The body prints the two sections and then the verdict. The
granted probes show their values; the denied probes show a denial message
(Elixir's raised error, `ex-message`):

```
── operator env ──
  String/upcase   → {:ok "DEPLOY"}
  System/halt     → <denial message>
  File/read shadow→ <denial message>
── deploy-agent env (attenuated: narrowing only) ──
  String/upcase   → {:ok "ok"}
  Enum/count      → <denial message>
```

and the run ends on the exact final line:

```
PASS 02_capabilities  (blast radius = compile error)
```

(That is one line; the two spaces before `(blast` are the spike's literal
formatting.) Run it from the worktree root so `blx` finds this checkout's stdlib
on `BEAM_LISP_PATH`.

## Exercises

1. **Try to widen a child — predict the denial.**
   Change `deploy-agent`'s fork spec to ask for a module its parent never had:
   `(env/fork operator {:caps ["Elixir.File"]})`. Predict: `File` is absent from
   `operator`, so the child's set is `operator ∩ {File} = {}` — both `File/read`
   *and* `String/upcase` now fail to compile. Attenuation cannot invent a right
   the parent lacked; the request for `File` buys nothing and costs the child the
   `String` it would otherwise have kept.

2. **Narrow a child to nothing.**
   Set `deploy-agent`'s spec to `{:caps []}`. Predict: `da-str` flips from
   `{:ok "ok"}` to a denial, and the assertion `(:ok da-str)` fails → the run
   ends `FAIL`. An empty spec is the floor of narrowing, and it is reachable —
   useful to confirm the intersection really is `parent ∩ spec` and not a merge.

3. **Grant the dangerous right to the operator and watch the *kind* of failure
   change.**
   Add `"Elixir.File"` to `operator`'s caps. Predict: `op-file` stops being
   `{:denied …}` from the *compiler*; the source now compiles, and if it errors
   at all it errors at *runtime* with a filesystem error (e.g. a permissions
   refusal on `/etc/shadow`). The guardrail moved from "unspeakable" to "speakable
   but blocked by the OS" — which is precisely the conventional model this spike
   argues against. (Do **not** add `"Elixir.System"` while probing halt: once it
   compiles, `System/halt 0` would actually stop the VM.)

4. **Introspect instead of probing.**
   Inside the file, after building the envs, call `(env/with-env operator (fn []
   (env/caps)))` and the same for `deploy-agent`, then print both. Predict: the
   operator's set contains `String` and `Enum`; the child's contains only
   `String`. This turns the narrow claim into a value you can read, and — unlike a
   `compiles?` probe — it shows you *which* rights each env holds, not merely
   whether one call went through.
