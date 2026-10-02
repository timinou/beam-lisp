# API playground: results and next decisions

## What you can play with

Start with [the walkthrough](README.md). The runnable playground is under `research/workspace-spike/`; it does not replace the production editor.

- `dev.workspace`: workspace handles, file inventory, draft buffers, definitions, explicit REPL bindings, proposals, verification, trial loading, guarded saves, private live images, inverse proposals, and snapshots.
- `play.change`: composable BL namespace/function/file operations and a data-only model-response decoder. Structural edits use the existing reader and `span-rewrite` span primitive.
- `play.gen`: asynchronous experiences, Demo/DeepSeek providers, `:ns`, bounded repair, cancellation, visible turns, versions, source-owned `.cache.bl` ledgers, acceptance, and restore.
- `play.ui`: BL-rendered Carbon/Snow views and allowlisted commands over those APIs. CodeMirror and a thin browser adapter handle editing and DOM updates. Open in REPL explicitly binds a selected buffer/proposal/experience as a BL value.

The scope is a small invoice project. It is deliberately small enough that you can read every proposed change and check the behavior yourself.

## Observed proof

### Deterministic tests

The four prototype suites exercise:

| Suite | Coverage |
|---|---|
| `api_test.bl` | Constructors, restricted decoding, source spans, paths, buffers, proposals, basis conflicts, save/live separation, undo, workspace isolation and restart |
| `gen_test.bl` | Async ready/failure/cancel, `:ns`, source-owned ledgers, restore/relocation, cross-workspace run isolation, quoted maps/sets, model-code refusal, and captured DeepSeek response replay |
| `provider_test.bl` | Local HTTP stub verifies the output-token budget reaches the request payload; no provider credentials are needed |
| `image_test.bl` | Same-named function isolation across trials/workspaces, symlink rechecking, explicit UI/REPL binding, stable buffers, ambiguous target refusal and composed creation |

Command:

```sh
bin/bl -p research/workspace-spike test \
  research/workspace-spike/api_test.bl \
  research/workspace-spike/gen_test.bl \
  research/workspace-spike/provider_test.bl \
  research/workspace-spike/image_test.bl
```

The final suite run reports **256 passing assertions**, zero failures/errors/incoherent files: 188 + 42 + 3 + 23. The separate `api_walkthrough.bl` also completes, including a source conflict, cancellation, and restart without another provider call.

The runs emit an existing `compiler_key_mismatch` floor warning after concurrent edits to boot-tier sources in this worktree. Those other edits were not discarded or folded into this prototype. This is focused prototype verification, not a claim that the whole repository suite is green.

### Real DeepSeek request

One explicit DeepSeek request used the key provisioned in `.env`, with **2400 maximum output tokens, a 60-second HTTP timeout, and no automatic repair** for that smoke. The key was not printed, placed in the prompt, or written into the sidecar.

The provider proposed:

1. `billing.rules/total`, adding integer subtotal and late-fee cents.
2. A require and replacement of `app.invoices/total`, delegating to that function.

The candidate loaded successfully, saved, and became live. Calling the original invoice entrypoint with `1000` and `250` returned **1250**. The unrelated `label` behavior was preserved. Saved history was reopened and replayed without another network request.

The first smoke's final assertion incorrectly expected quote characters around the printed string result. The assertion was corrected to compare the string inside BL; the saved real-provider proposal then passed the replay proof without rebilling. The captured response is now a deterministic regression fixture at `fixtures/deepseek-proposal.bl` and passes the final generation safety checks.

### Browser exercise

A real headless browser exercised the actual running application, not a generated mockup:

- Carbon and Snow palettes; code contrast was inspected and improved.
- A file became a dirty draft with no disk entry, was edited through CodeMirror, then saved and reported clean.
- `ws/definitions` in the embedded REPL saw the definition created through the UI.
- Open in REPL bound the selected source buffer; the prefilled inspection form evaluated successfully.
- The Generate control produced user/status/assistant/check turns and a ready, unsaved proposal using the Demo provider.
- Try left Live unset; Save set Saved without Live; Make Live brought the revision pointers together.
- A saved real-provider experience was displayed after reopening the workspace.
- The BL UI itself was reloaded from the REPL while the workspace remained running.

The repeatable HTTP seam check also passes:

```sh
node research/workspace-spike/browser_smoke.mjs http://127.0.0.1:7872
```

It checks missing-token and foreign-origin refusal, an API-backed REPL calculation, per-browser selection state, explicit REPL binding, traversal/dotfile refusal, palette assets, and the existing `/repl` page/editor routes. No credentials are printed by this check.

## Visual evidence

- [Carbon editor](evidence/carbon-editor.png)
- [Carbon proposal, Saved but not Live](evidence/carbon-proposal.png)
- [Snow live proposal](evidence/snow-live-proposal.png)
- [Snow conversation and version](evidence/snow-generation.png)
- [Contextual REPL inspection](evidence/carbon-repl.png)

These images include a real provider proposal and a later deterministic refinement. They are screenshots of the prototype, not promises about the final desktop layout.

## The most important finding

**An env fork is not function-code isolation.** The initial experiment returned `1000`, then returned `1250` from the original workspace after merely verifying a candidate. Inspection of `BeamLisp.Link.defvar` showed why: fresh function bodies still publish a VM-global namespace shim.

The prototype now uses private namespace identities for candidate/workspace images while keeping the original names in source and proposals. Tests prove that verify/try leave the live function—and another workspace's same-named function—unchanged. This is a bounded prototype technique, not a general solution for dynamic macros, arbitrary namespace tricks, old closures, or application process migration. Production design is tracked in FUP-116.

## API conclusions

1. **The common proposal value is useful.** A hand-written change, a model suggestion, and a file operation can use the same preview/verify/save flow.
2. **Separate Made/Saved/Live is necessary.** Source persistence and runtime publication must not be one opaque action. The prototype records these per proposal; the final interface still needs a version-family view showing the previous Saved/Live alongside a newer Made revision.
3. **Selection must be a first-class REPL value.** Explicit Open in REPL works better than UI-only IDs or silently overwriting variables when focus moves.
4. **`try!` should grow a first-class trial handle.** This spike returns a disposable-load receipt. The next API should let you evaluate several forms against a named candidate image, then publish or discard it.
5. **Restored addresses belong to the receiving workspace.** Copying a project must rebind its saved handles, and active generation keys must include both workspace and experience identity. Tests cover a copied history and cancellation that must not affect the other copy.
6. **The production transaction boundary remains work.** Ordinary source-write failures get guarded compensation, but source saves and ledger acceptance do not share a crash-recovery journal yet.

## Deliberate limits

The prototype does not implement the final accepted-version expansion macro, editable candidate-version buffers, cursor-hover/DWIM integration, token-level streaming, complete namespace rename/reference updates, automatic dependent-test discovery, or arbitrary runtime state migration. The embedded API REPL shares a workspace image; independently publishable trial sessions per browser are not implemented. Generated private modules remain for the prototype VM's lifetime.

Compilation and trial loading can execute macros and trusted code. The constructor decoder and setup-form restrictions are useful gates, **not an OS/filesystem/network sandbox**. Use the disposable fixture, review proposals, and keep paid generation explicit.
