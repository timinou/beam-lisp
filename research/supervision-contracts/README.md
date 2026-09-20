# The same four contracts, applied to supervision

`research/reader-contracts/` built four contracts into the reader and landed them
in `priv/boot/reader.bl`:

|contract|reader form|what it bought|
|---|---|---|
|**options are a value**|`(read src {:file f :diagnostics :collect})`|policy at the call site; no ambient config; a harness asks for different behaviour without a second implementation|
|**a span locates the failure**|`:offset`/`:end-offset`, `:end-line`/`:end-col`, `:opened-at`|the failure UNDERLINES itself, slices its own source, and can name a SECOND location (the opener a stray closer belonged to)|
|**a failure is a value, in one shape**|`{:bl_diag true :kind :msg :line :col :offset …}`|ONE renderer draws reader errors and type warnings alike; a repair pass dispatches on `:kind` instead of re-parsing a sentence|
|**one loop, two views**|`stream` / `read-next` beside `read-forms*`|the incremental and the batch view cannot drift apart|

This note asks the same four questions of `priv/std/proc/super.bl` — supervision
trees as data — and of `priv/std/typed.bl`, which is where the diagnostic
VOCABULARY already lives. It is a transfer of shape, not a rewrite.

## What the supervisor says about itself

`priv/std/proc/super.bl` opens with:

> The supervisor is the only bundle that is a PROCESS, not a library: it owns
> children, it must never block, it must never crash. Its state is the child set
> and the restart ledger — both of which OTP keeps for us.

and then, in `children`:

> OTP does not expose per-child restart counts; the tree shape is what it
> exposes, so that is what we hand back.

Those two sentences are the whole problem. The spec DECLARES a policy —
`(intensity 3 5000)`, "3 restarts per 5s, then give up" — and the declared state
is "the child set **and the restart ledger**". But the ledger is the one half of
the state that no verb returns, because OTP keeps it privately. A declared policy
that cannot be REPORTED is a policy nobody can test, alert on, or explain after
an incident.

That is the reader's situation before §1 and §2 of the reader plan, exactly: the
position (and, later, the offsets) existed during the descent, and the failure
said nothing about it. The fix there was to carry the data until it could be
reported. The fix here is the same, applied to a different descent.

## The four transfers

### 1. Options are a value — already true, and the precedent

`defsupervisor` builds a spec map:

```clojure
{:__supervisor__ true :strategy :one-for-one :intensity [3 5000] :children (…)}
```

A supervision tree is already data, declared, and readable without running it.
This is the repo's native idiom, and the reader's `read` arguments map is the
same idea arriving from the other side. **No change.** It is evidence that "the
thing is a value" is how this tree already thinks.

### 2. A span locates the failure — the position cannot come from the tree

**Measured** (this venue, `./bl -p priv/std run`, a macro that prints its own
argument):

```
probe-pos (child :acct account 100)  →  (child :acct account 100)
```

The clause reaches `defsupervisor` as a BARE form: the compiler strips `{:meta …}`
position wrappers before a macro sees its arguments. So the tree CANNOT stamp its
child clauses with source positions, and a supervision event cannot point at
`(child :acct account 100)` by line.

Where the position must come from instead: the crash's own annotated code. The
compiler already attaches `:ann` to nodes — that is exactly what
`errors/node->warning` reads (`(or (:col a) 1)`, `:end-line`, `:end-col`) and what
`typed/eff-pos` falls back to (`(:__pos env)` for synthesized nodes). So an event's
`:where` is a RUNTIME span, taken from the failing form's annotation, and the
event carries the same `:line`/`:col`/`:end-line`/`:end-col` keys the renderer
already draws a caret from.

### 3. A failure is a value, in one shape — and there are three shapes today

The tree currently has three diagnostic vocabularies:

|producer|shape|rendering|
|---|---|---|
|reader (before this week)|`BeamLisp.Reader.SyntaxError`, message string|`file:line:col: message` — no caret|
|reader (now)|`{:bl_diag true :kind :msg :line :col :offset :end-line :end-col …}`|whatever the host edge renders; `errors/render`-compatible|
|checker|`{:msg :line :col :end-line :end-col :form}`|`errors/render` — caret + underline, L12-clean|
|supervisor / OTP|`{:EXIT, pid, reason}`, `{:badmatch, …}`, SASL lines|raw host tuples — an L12 violation in the user's face|

Three shapes produce three qualities of experience, and the supervisor's is the
worst: a supervision failure today shows a human BEAM terms.

**The transfer:** a child's exit becomes an EVENT in the checker's shape —

```clojure
{:bl_diag true
 :kind :child-exit            ; :intensity-exceeded :child-restart-limit :tree-down
 :id :acct :pid #PID<…>       ; which child, which incarnation
 :reason :badmatch            ; the exit reason, delaborated by errors/render
 :restarts 4 :window 5000     ; the ledger, finally reportable
 :msg "supervisor billing: child :acct exited (:badmatch) — 4 restarts in 5000ms"
 :line 42 :col 11 :end-line 42 :end-col 19}   ; where the crash came from (see #2)
```

One shape, one renderer: `errors/render` draws a supervision failure the same
way it draws a type warning, and `errors/delaborated?` becomes the gate that no
`{:badmatch` ever reaches a human.

`typed` is what makes the reason legible: the event's `:reason` names a value the
checker already has an opinion about — `(performer shared payload principal)`
crashing on an arity, or a `:badarg` on a form whose argument tags are in the
evidence table. The conjunction is the deliverable: **the reader's spans, the
checker's evidence, the supervisor's ledger, rendered by one renderer.**

### 4. One loop, two views — the snapshot needs a stream

`children` is a snapshot. Between two calls, the interesting history is gone: how
many restarts, in what window, which reason, what the tree did after the
intensity budget was spent. The supervisor must never block and never crash, so
the stream cannot be a callback INTO it.

The reader's answer transposes directly: a sidecar owns the events and the
ledger, the supervisor keeps supervising.

```
children  →  the snapshot            (already exists)
events    →  the stream, subscribed  (the transfer)
```

Acceptance for the pair: an induced crash of a named child yields exactly one
`:child-exit` event carrying `:id`, the failing incarnation's `:pid`, `:reason`,
and the running `:restarts`/`:window`; and a fourth crash inside the window
yields `:intensity-exceeded` BEFORE the tree gives up — i.e. the declared policy
becomes observable at the moment it matters.

## The scoping lesson, from `typed` — do not repeat BUG-041

`typed.bl` keeps per-check state in the PROCESS dictionary, and its comment
records why: those atoms were once VM-global, so every check accumulated into the
next caller's report — "the suite's phantom diagnostics (BUG-041)". The ledger
has the same failure mode waiting: one VM-global counter would attribute one
supervisor's restarts to another's, and a restart budget is a SAFETY mechanism —
phantom counts would make trees give up early or never.

So: the ledger is per-supervisor and per-child, carried by the process that owns
it, and the ambient/current split `typed` uses (`state-key` + `ambient-key`) is
the pattern to copy, not to reinvent.

## Change list, ordered, each independently verifiable

1. **`(proc.super/events s)`** → the stream; `(proc.super/events s {:id :acct})`
   to filter. Sidecar process, monitors the children, hands back `[:ok event
   sidecar']` / `[:eof sidecar']` — the `read-next` shape.
   *Accept:* one induced crash → one `:child-exit` with the right `:id`/`:pid`/`:reason`.
2. **`(proc.super/ledger s)`** → `{:id {:restarts n :window ms :last-reason r
   :last-at ts}}` from OUR counters. *Accept:* after k induced crashes the
   reported count is k, with no OTP introspection.
3. **`(proc.super/render s event)`** → delegate to `errors/render`.
   *Accept:* byte-identical caret layout for a supervision event and a type
   warning at the same position; `(errors/delaborated? out)` is nil.
4. **`typed` evidence in the event.** *Accept:* an event whose `:where` is a call
   site with `:ann` and whose args are in the evidence table renders as
   "<form> is called with n arguments — a <type> takes <arity>".
5. **The intensity event** (policy observable at the boundary). *Accept:* the 4th
   crash in a 3-per-5000ms window emits `:intensity-exceeded` before the tree
   dies.

## What this note does NOT claim

- **Nothing is implemented.** This is a design transfer with a change list, not a
  cutover. The reader contracts were built and measured before being written up;
  these are not.
- **Whether a supervision tree can be STARTED in the verification venue was not
  established.** The tree's `proc.super` DOES load from source
  (`./bl -p priv/std run` → "proc.super loaded: true"), but my probe referenced
  `BeamLisp.Supervisor` as a value rather than calling it, so the probe failed for
  a probe reason and says nothing about the module. Establishing it is step zero
  of implementing #1.
- **The end-to-end CLI path for the reader work is still unverified** (the drop
  ships a compiled reader; see `research/reader-contracts/README.md`).
