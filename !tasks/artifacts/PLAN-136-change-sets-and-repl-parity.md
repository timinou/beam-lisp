# Checkpoint 2: every interface is a REPL; generation proposes coherent change sets

Status: architecture only, after user review of the proc workspace design. No feature implementation, no provider call, and no `.env` contents read for this checkpoint. This document refines the acceptance/save/live semantics in `PLAN-136-proc-workspace-architecture.md` for changes that span namespaces and source files.

## 1. Findings from the override spike

Inspected `/home/user/code/undefine/beam-lisp--override-spike` (detached at `9949593b`). Its useful override work is uncommitted there, but it is ALREADY present in this branch. `git diff --no-index` reports no differences for either `priv/std/bl/override.bl.md` or `research/p17_overrides/patches/edn_tagged_readers.bl` between the spike and this tree. No cherry-pick is necessary. Do not copy old CLI/Mix-era wiring over the current CLI.

The useful existing contracts are:

- A patch is a BL `transform [ctx]`, with scoped codebase facts and source readers, returning proposed full sources and tests.
- The tagged-reader example finds named definitions using BOTH the codebase database and reader structure. It refuses missing/disagreeing targets instead of guessing line offsets.
- It verifies diagnostics, loadability, related existing tests, and explicit new tests.
- Shipped namespaces are vendored into a project override root instead of overwriting an installation.

Important limits from reading the implementation, not a new runtime audit:

- `run-patch` evaluates the patch as arbitrary code. A context map is NOT a sandbox.
- `cmd-apply` writes into the real override directory BEFORE verification. Its rollback is called from selected verification-failure branches, not an encompassing crash-safe transaction around every write/exception.
- Rollback restores old bytes without a basis comparison; it is not safe to reuse as a concurrent multi-file editor.
- Implicit tests are selected by textual `require` matching, not a sound dependency closure.
- It explicitly tells users to restart a warm daemon. That is not the new live/staged workflow.

Decision: keep its ergonomic transformation/program idea and source-addressing concepts, adapt its public verb onto the SAME generalized `dev.change` planner/executor used by the workspace, and preserve the trusted-program entrypoint as an explicit execution mode. Do not create a second override executor, change ledger, or source of transaction policy. Current `dev.change` policy is host-side; the extension/cutover puts new domain policy in BL, retaining only necessary filesystem/runtime substrate. Existing supported behavior gets characterization tests before cutover.

## 2. One proposed change set, not a generated island

`gen/ns` returns an experience whose candidate version contains a **proposal**:

- the generated namespace and its definitions;
- companion edits to existing namespaces/functions/requires/call sites;
- additions or updates to tests;
- a per-operation reason and structural target;
- immutable basis hashes, selected source provenance and dependency edges;
- verification results tied to that exact proposal revision and image/source basis.

The primary `gen/ns` defaults to the namespace of its owning file: accepted definitions expand at that call site, and generated require changes are explicit source operations. It must not quietly replace handwritten definitions in the same namespace; those are named companion edits requiring review. A genuinely additional namespace uses a source-creation operation at the normal namespace-resolved project path, so ordinary `require` works after restart. The cache retains its proposal/history but the origin macro does not also redefine that separately materialized namespace. Each definition has one active source of truth, not a cache expansion competing with a generated file.

A proposal is also the unit produced by manual structural edits, rename/move workflows, and override transformations. It is not a gen-only data structure. `gen` owns prompts/turns/provider behavior; `dev.change` owns transformations/plans/verification/receipts; `dev.workspace` owns logical handles and process state; views only project those values.

The model does NOT calculate file hashes, browser cursor offsets, safe output paths, or transaction IDs. BL resolves the model's semantic addresses against an immutable project snapshot, computes those facts, and refuses missing/ambiguous targets. A changed source requires a new plan/rebase and fresh verification; changing a line number is never an implicit rebase.

### Proposed authoring surface

These are design examples, not existing APIs or patches to the current project. An example fixture has `app.invoices/total`, taking a map with `:subtotal-cents` and `:late-fee-cents`.

```clojure
(change/bundle "Extract invoice arithmetic and wire the existing total"
  (change/create-namespace 'billing.rules
    '(defn total [subtotal-cents fee-cents]
       (+ subtotal-cents fee-cents)))

  (change/in-namespace 'app.invoices
    (change/require '[billing.rules :as rules])
    (change/replace-definition 'total
      '(defn total [invoice]
         (rules/total (:subtotal-cents invoice)
                      (:late-fee-cents invoice)))))

  (change/in-namespace 'app.invoices-test
    (change/require '[app.invoices :as invoices])
    (change/add-definition
      '(deftest total-includes-fee
         (is (= 1250 (invoices/total {:subtotal-cents 1000
                                    :late-fee-cents 250})))))))
```

Ordinary BL constructors return ordinary operation data. Namespace scopes remove repeated qualification. Full quoted forms are readable and editable; requires are structural set-aware edits, not concatenated strings. The exact same constructors compose at the REPL. `change/rename-definition`, `change/move-namespace`, and guarded file operations share this representation as their support is implemented.

For model responses, the default path accepts only the closed constructor/literal/quoted-form subset and decodes it with the existing reader WITHOUT arbitrary evaluation or macroexpansion. That is a restricted authoring surface of the same API, not a claim that a context map limits BL's authority. Quoted replacement code is data until explicitly compiled/tried. Constructor decoding rejects unknown forms, nonliteral target expressions, path escapes and malformed/overlapping operations.

Trusted custom `transform [ctx]` programs remain available for transformations that require arbitrary scoped queries. Running one is explicit code execution; it is not automatically triggered by receiving an LLM response or displaying a cache entry. A future OS-isolated execution venue can strengthen this, but a forked env/fence does not sandbox filesystem/network/process effects, and this checkpoint does not promise otherwise.

## 3. Carbon/Snow controls and REPL operations are one capability surface

No feature is UI-only. The browser invokes the same registered BL commands as the REPL, with the same basis guards, authorization and receipts. Each meaningful UI action exposes a copyable **REPL form**, and a structured receipt can be reused as the next operation's input. This is discoverability, not a second text-only command interpreter.

Each panel also has an **Open in REPL** affordance: file-tree selection, namespace, definition, proposal, or generated version becomes an inspectable value in the existing session. The prompt/context strip names the selected object and evaluation namespace. This is one evaluator with explicit context, not a separate evaluator/process per widget. Copyable forms contain stable addresses so they remain understandable outside the selected panel; no invisible JavaScript state is required to replay them. A buffer's Eval command still targets its displayed namespace/session, not whichever sidebar row happened to be hovered last.

Proposed public examples (not implemented APIs):

```clojure
(require '[dev.workspace :as ws]
         '[dev.change :as change]
         '[gen :as gen])

(def w (ws/attach! "."))

;; Inventory and navigation return ordinary values.
(ws/files w)
(ws/namespaces w)
(ws/definitions w 'app.invoices)
(ws/references w 'app.invoices/total)

;; Create starts a DRAFT buffer. Saving to disk is a visible separate action.
(def b (ws/new-file! w "src/billing/rules.bl" '(ns billing.rules)))
(ws/open! w "src/app/invoices.bl")
(ws/buffers w)
(ws/snapshot b)
(ws/save! b)
(ws/close! b)                          ; dirty/conflicting state is not discarded

;; File operations compose into a proposal, just like model-authored changes.
(def p
  (ws/propose! w
    (change/bundle "Move the legacy module out of the active source tree"
      (change/move-file "src/legacy.bl" "archive/legacy.bl"))))
(ws/preview p)
(ws/verify! p)
(ws/save! p)

;; The same planning path covers mkdir, copy, trash/delete, restore and undo.
;; Namespace-aware moves are DIFFERENT from raw file moves:
;; (change/move-namespace 'billing.rules 'finance.rules) also plans ns/requires
;; and impacted references. No silent pretend-refactor from a rename dialog.

;; A model-backed operation has the identical proposal lifecycle.
(def x (gen/ns "Introduce late-fee arithmetic and wire it into invoice totals"))
(def p (ws/proposal x))
(ws/changes p)
(ws/preview p)
(ws/verify! p)
(ws/try! p)                           ; whole selected closure, session image only
(ws/save! p)                          ; source + sidecar accepted pointer
(ws/make-live! p)                     ; coherent project image publication
(ws/status p)                        ; made/saved/live revisions, not one boolean
(ws/undo! (ws/receipt p))              ; inverse plan, with current-basis checks

;; View operations are also BL commands, scoped to this session.
(ws/theme! :snow)                     ; :carbon is the other palette
(ws/focus! x)
(ws/pin! x)
(ws/collapse! x)                      ; affects presentation, not the run
```

The complete parity inventory includes:

| Interface affordance | REPL capability |
|---|---|
| File tree, filter, refresh | inventory/search/refresh queries and commands |
| Create file/directory, copy, move, trash, restore | guarded file operations through proposals |
| Open/switch/close buffers, save/save-as, discard draft | addressed buffer commands with dirty/conflict receipts |
| Namespace outline, definition navigation, docs/references | queries returning symbol addresses and ordinary data |
| Structural replacement, rename, namespace move | composable change constructors, preview/verify/commit |
| Eval selection/form, inspect value, stop evaluation | session commands with operation handles and cancel |
| Gen turns, follow-up, retry/cancel, versions | experience commands and immutable turn/version queries |
| Review selection, dependency closure, compare, undo | proposal queries and receipt-based commands |
| Make live, inspect held reasons, restore earlier live revision | explicit coherent reload operations |
| Focus/pin/collapse experiences, Carbon/Snow preference | session-view commands, independent of project changes |

A raw filesystem move may deliberately break namespace resolution; it must show diagnostics and never silently imply that callers were refactored. A namespace move computes source/require/reference changes through the structural index. Destructive commands require explicit intent and produce recoverable receipts; a model suggestion cannot authorize deletion. Copy/save-as refuses overwrite by default. Paths are confined to the declared workspace, with symlink/path-escape checks; editing a dependency means a visible project override, not an installation write.

## 4. Made, saved, live: independent revision pointers

Do not encode these as a linear enum. A user can try code before saving, save without publishing, or generate a newer draft while an older version stays live.

```clojure
{:made  "r7"
 :saved "r5"
 :live  "r6"
 :review {:selected "r7" :accepted? false}
 :verification {:revision "r7" :basis "project-b42" :status :passed}}
```

The UI renders three explicit revision badges:

```text
Made r7      Saved r5      Live r6
```

- **Made**: materialized candidate buffers/operation set. Conversation/candidate history may already be persisted in the sidecar; that is NOT the same as saving this revision as the source version to load.
- **Reviewed/accepted**: selection approved by the user. Approval is tied to exact content and required companion edits, not a permanent permission for future generations.
- **Saved**: required source edits and the accepted-expansion pointer have been committed to disk together through the guarded proposal transaction.
- **Live**: that exact proposal revision has passed coherence and is active in the target project image. Session-only trials are labeled separately and do not advance project Live.

Any operation records exact touched file/namespace revisions. A partial external edit marks Saved as diverged; a later image reload marks Live as different. A whole-proposal badge is shown only if its entire required closure matches, otherwise show mixed/diverged with per-target detail.

Refinement creates `r8` without changing Saved or Live. Verification fails/holds only that candidate; old source and live definitions keep serving. Undo is a new guarded inverse proposal; it does not rewrite history or blindly restore old bytes over somebody else's edits.

Acceptance semantics refined from checkpoint 1: `accept!` may record review selection, but must NOT advance the macro's durable accepted pointer before required companion source edits are saved. Otherwise a restart could load generated code that assumes transformations never written to disk. Save commits that pointer and the required source closure. Make Live is independent; the common UI can offer explicit Save & Make Live, with a receipt reporting each outcome separately.

## 5. Cross-file state management with proc

Add a proposal coordinator under the existing workspace supervision tree. It owns each proposal's revision, target closure, reservations, verification and commit state; file owners still serialize mutations to their source/sidecar pair.

1. Build against an immutable project/source snapshot. Structural operations resolve to guarded old/new bytes plus namespace/image plans, without touching working files.
2. Reserve affected file owners in canonical path order to avoid deadlock. Reservations have operation IDs, monitors and bounded leases; a dead coordinator cannot wedge the workspace.
3. Verify the ENTIRE selected dependency closure in an overlay workspace/image. Generated tests run against the overlay, not against a half-written project. Verify dependent namespaces/call sites as well as target files. Source-query test discovery supplements declared/explicit tests; it is not proof that every affected test was found.
4. Recheck source bases and selection at commit time. Any external editor change invalidates the old verification and returns a conflict. No implicit retargeting or unreviewed rebase.
5. Save via a durable prepare journal and staged files, then per-file atomic replacement and a final commit marker. The daemon's watcher/index/reloader observes only committed transaction revisions and reconciles once afterward. Recovery completes or safely reports/rolls back an interrupted transaction using basis checks; it never overwrites intervening external edits.
6. Separately stage and commit the whole namespace bundle through `reload`. State migration or incompatible live-process changes can hold publication; code coherence alone is not proof that every running process can adopt a new state shape.

A multi-file save is **journaled and recoverable**, not an OS-atomic rename of several paths. External tools not participating in the transaction can observe intermediate disk states. Do not advertise stronger atomicity. Workspace clients see a consistent committed snapshot, and startup recovery resolves prepared transactions before normal evaluation resumes.

Cancellation before commit ends the run and releases reservations. During commit, finish recovery to a defined state rather than killing a writer mid-rename. Worker results carry proposal revision/run epoch so late output cannot overwrite a newer plan. Paid provider requests are never blindly replayed after a crash.

The existing `bl override` command becomes another adapter to this coordinator/planner. It may still accept trusted transform programs returning full sources; the adapter converts those into basis-guarded replacement proposals and uses the shared verification/save/live policy. One source of transaction truth, no legacy write-first path left behind after cutover.

## 6. Persistence and UI of companion transformations

Keep the user's one-to-one generation cache rule:

```text
src/billing.bl -> src/.billing.cache.bl
```

The source containing a gen call owns that experience's version history. One version stores its generated namespace, companion transformation forms, reasons, dependency edges, materialized digests and verification/receipt references. Editing `app.invoices` as a companion does NOT create `.invoices.cache.bl` unless that file itself contains gen calls. Proposal receipts/transaction journals are workspace-wide references, not copies of competing generation history. Ledger reads are data-only; no arbitrary transformation execution on hover, file load or restart.

Regular load expands only the saved accepted generated code. Companion transformation programs are NEVER replayed as load-time side effects: their materialized source changes were saved with the accepted pointer, and dependency/basis mismatch becomes explicit stale/conflict state. A saved namespace version may need several sources; the build tracks that dependency closure and sidecar digest.

For multiple gen origins in one proposal, each remains owner of its own history; the transaction references all source sidecars and advances their accepted pointers coherently rather than duplicating ownership.

UI proposal card:

```text
billing/rules                         Made r7 · Saved r5 · Live r5
  Generated namespace                 + total
  Required integration
    app.invoices                      ~ total · + require
    app.invoices-test                 + total-includes-fee
  Checks                              compile ✓  tests ✓  coherence held
  [Try in session] [Save] [Make live]
```

Every row opens an ordinary namespace/definition/file buffer with the same structural editing tools. Each operation shows why it exists, its diff, dependent operations and verification. Required edits cannot be unchecked while silently keeping a green badge: selection must be dependency-closed or return a visible unsatisfied requirement. Independent changes can be split into separately verified proposals. Editing a generated change creates a new revision and invalidates the old evidence.

When focus leaves, the card collapses to the symbol row with compact Made/Saved/Live state. Clicking a companion symbol opens its normal buffer with a backlink to the proposal that suggests the edit; it does not become a second conversation with separate history. Theme changes are ordinary session-state commands rendered through Carbon/Snow tokens; they never affect proposal state.

## 7. The next spike, after this checkpoint

User has authorized using `DEEPSEEK_API_KEY` from `.env` for the next prototype, after this checkpoint. Do not print, commit, put in a model prompt, store in sidecars, or expose through REPL command receipts the key or `.env` contents. Load it only into the provider's environment/header. Project-context collection must exclude secrets/dotenv and operate on an explicit scoped source selection. Provider diagnostic output must redact authorization material.

The prototype should prove one narrow vertical slice before broad UI work:

1. A disposable sample project with one existing function and test; a file-backed `(gen/ns "...")` asks for a small namespace plus a useful companion function/require change.
2. DeepSeek returns the structural proposal constructor forms (not raw whole-project rewrites). Decode without arbitrary eval; show visible turns and the actual proposed changes. Invalid output becomes a visible repair turn.
3. Preview the generated namespace and companion definition in shared buffers, render Made/Saved/Live badges and collapse/pin behavior, and run the exact same actions from the REPL.
4. Try in session; save the required closure; make it live; restart and prove the accepted generated code and companion source load without another provider request.
5. Edit a touched source externally before commit and prove a conflict; inject validation failure and prove old source/live state remains; prove cancelled/stale provider output cannot advance revisions.

Use a deterministic fake-provider suite for all lifecycle and fault cases; one bounded real-provider smoke demonstrates integration, not a nondeterministic test requirement. Set an explicit request/token/repair budget, show it in the experience, and make cancellation honest about a provider request that may already have been billed.

No provider-backed spike is started in this checkpoint.
