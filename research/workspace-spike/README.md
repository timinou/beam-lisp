# A little Beam Lisp machine

Welcome! This playground gives you a small project, a live REPL, an editor, and a generator that can propose changes across namespaces. Everything important is also an ordinary BL operation. The buttons are another way to call those operations.

You will teach an invoice function to include a late fee. The interesting part is not the arithmetic: it is watching a proposal become **made**, **saved**, and **live** at different moments.

## Come in and look around

From the repository root:

```sh
BEAM_LISP_AOT_CACHE_DIR=/tmp/bl-playground-aot \
  bin/bl run research/workspace-spike/serve.bl
```

Open **http://127.0.0.1:7871/play**. The terminal prints a fresh workspace under `/tmp`. Your project files are not edited. Keep that printed path if you want to return to this playground later.

The small circle in the top bar switches **Carbon** and **Snow**. Try both; they are the same workspace, not two different applications.

The page has four places to explore:

- **Buffer** — choose a source file, edit it, and save deliberately.
- **Generate** — start a conversation and inspect its visible turns.
- **Proposal** — see every affected file and the Made/Saved/Live state.
- **REPL** — call the same APIs directly. Ctrl+Enter evaluates your form.

The existing browser REPL is also mounted at `/repl` in this prototype's server. The playground's REPL panel is already connected to the workspace's evaluation environment and has `w`, `ws`, `change`, `gen`, and `ui` ready. That is the easiest place to follow this tour.

The prototype starts real daemon services in the same VM. It is a dedicated disposable-project launcher, not yet a replacement for `bl repl --ui FILE` or an attachment UI for an arbitrary already-running daemon.

## 1. Files are values you can inspect

Open the REPL tab and ask:

```clojure
(ws/files w)
(ws/definitions w 'app.invoices)
```

Open the same file from code:

```clojure
(def b (ws/open! w "src/app/invoices.bl"))
(ws/snapshot b)
```

`b` is a stable address. Its snapshot is ordinary data containing the source, namespace, basis hash, and dirty state. There is no browser-only file object to discover.

Click **Open in REPL** on a buffer, proposal, or experience to bind that selection as `buffer`, `p`, or `experience`. The page opens the REPL with an inspection form ready. The binding is explicit, so merely hovering a file never overwrites a variable you are using. Programmatically, the same operation is `(ws/bind! w 'buffer b)`.

Make a tiny note:

```clojure
(def note (ws/new-file! w "src/notes.bl"
                       "(ns notes)\n(def answer 42)\n"))
(ws/snapshot note)
```

It is a draft. Nothing has been written to disk yet.

```clojure
(ws/save! note)
(ws/files w)
```

You can do the same thing with **New file** and **Save**. An existing destination is a conflict, not an invitation to overwrite it. Closing a dirty buffer refuses to throw your work away. Saving checks that an external editor has not changed the original file underneath you.

The editor uses the project's existing CodeMirror bundle. Ctrl+S saves the active buffer. If the bundle cannot load, the page says so and leaves an editable textarea available. Switching between files keeps edits as drafts; saving is still explicit.

## 2. Give the invoice a useful companion

The initial implementation returns only `:subtotal-cents`:

```clojure
(ns user (:require [app.invoices :as invoices]
                  [dev.workspace :as ws]
                  [play.change :as change]
                  [play.gen :as gen]
                  [play.ui :as ui]))

(invoices/total {:subtotal-cents 1000 :late-fee-cents 250})
;; 1000
```

Namespace declarations are how this language brings in aliases. Use `(ns … (:require …))`, rather than a standalone Clojure `require` call.

Now start a generation:

```clojure
(gen/use! w "src/playground.bl")
(def x (gen/ns "Include late fees in invoice totals"))
```

The call returns immediately. `x` addresses an experience with a running conversation, not a blocked HTTP response.

```clojure
(ws/snapshot x)
(gen/turns x)
(gen/await! x 90000)
```

The default provider is **Demo**: deterministic, offline, and free. It is intentionally scoped to this invoice exercise. It proposes a `billing.rules` namespace and changes `app.invoices/total` to use it, keeping the unrelated `label` definition and its surrounding comments.

In the browser, the Generate tab provides the same prompt and provider choice. The experience remains in the rail when you move elsewhere. Background progress does not take your editor focus or save code behind your back.

This spike streams conversation turns and check status, not individual model tokens. There is no typewriter animation pretending a completed response is streaming.

## 3. Made is not saved. Saved is not live.

```clojure
(def p (gen/proposal x))
(:changes (ws/preview p))
(ws/status p)
```

The proposal contains both sides of the integration: the new namespace and the existing caller edit. Review them together in the Proposal tab.

At this point:

```text
Made: a revision     Saved: —     Live: —
```

Try it without publishing:

```clojure
(ws/try! p)
```

Verification checks parsing and namespace loading in an isolated candidate environment. It does **not** mean your project's whole test suite ran. The executable walkthrough below also checks the invoice behavior explicitly.

Choose the version you want to keep:

```clojure
(gen/accept! x)
```

This saves the proposal's source changes before selecting its accepted history entry. The owning notebook has a single ledger:

```text
src/playground.bl
src/.playground.cache.bl
```

The ledger is readable BL data: prompts, visible turns, version addresses, and the accepted selection. Reading it never calls a model or executes historical proposals.

The source is now saved. The active workspace image is still independent:

```clojure
(ws/make-live! p)
(app.invoices/total {:subtotal-cents 1000 :late-fee-cents 250})
;; 1250

(ws/status p)
```

For this revision, Made, Saved, and Live now name the same version. You can also make a verified candidate live before saving it. A newer candidate does not silently become either the saved or live version.

“Live” here means the **playground workspace's environment**. It does not promise migration of arbitrary running application processes, databases, or a different daemon's image.

## 4. You can write proposals yourself

The model does not have a special editing back door. Its proposals use the same constructors:

```clojure
(def greeting
  (ws/propose! w
    (change/bundle "Give invoices a friendlier label"
      (change/in-namespace 'app.invoices
        (change/replace-definition 'label
          '(defn label [invoice]
             (str "Hello, invoice " (:number invoice))))))))

(ws/preview greeting)
(ws/verify! greeting)
(ws/save! greeting)
(ws/make-live! greeting)
```

Structural edits address a definition by name. They do not ask you—or the model—to count lines.

File management uses proposals too:

```clojure
(def move
  (ws/propose! w
    (change/bundle "Put the note in an archive"
      (change/move-file "src/notes.bl" "archive/notes.bl"))))

(ws/preview move)
(ws/verify! move)
(ws/save! move)
```

That is a **file move**, not a namespace refactor. The prototype does not silently rewrite callers or pretend that moving a file renames its namespace.

To undo a saved proposal, first make an inverse proposal:

```clojure
(def back (ws/undo! move))
(ws/preview back)
(ws/verify! back)
(ws/save! back)
```

Undo checks the current basis too. It cannot safely put old bytes over somebody else's new edit, so it refuses that conflict.

## 5. Keep the conversation; control the run

```clojure
(gen/versions x)
(gen/turns x)
(gen/refine! x "Keep the same arithmetic, with a short docstring")
(gen/cancel! x)
```

Cancel ends local work. A provider may already have processed or billed a request; cancellation cannot promise to reverse that. Late worker output must not publish a new ready version after cancellation.

A malformed model response is a visible failure or bounded repair turn. Model output is decoded as the allowed change constructors plus quoted code—not evaluated as an arbitrary patch program. Automatic generation accepts named function definitions and literal require specs; raw file operations, executable setup forms, and namespace-name injection are rejected before candidate loading. Trying or making generated code live is still code execution; an environment fork is not a filesystem/network sandbox.

## 6. Switch the theme from the REPL

```clojure
(ui/theme! w :snow)
(ui/theme! w :carbon)
```

The toolbar calls that same BL operation. The prototype treats appearance as a workspace preference. Browser focus and active file selection stay per browser session.

## 7. Return tomorrow

Stop the launcher with Ctrl+C. Reopen the directory printed earlier:

```sh
BEAM_LISP_AOT_CACHE_DIR=/tmp/bl-playground-aot \
  bin/bl run research/workspace-spike/serve.bl -- \
  --root /tmp/YOUR-PRINTED-WORKSPACE --port 7871
```

Saved source and conversation history return. The prototype does not claim an old process image survived a VM restart: Live is rebuilt explicitly, not fabricated from yesterday's badge.

## 8. Invite DeepSeek, deliberately

To enable the key provisioned in the repository's `.env`:

```sh
BEAM_LISP_AOT_CACHE_DIR=/tmp/bl-playground-aot \
  bin/bl run research/workspace-spike/serve.bl -- \
  --deepseek-env .env
```

Choose **DeepSeek** in Generate. Demo remains the default, even when credentials are available.

From the API:

```clojure
(def real
  (gen/ns w "src/playground.bl"
          "Include late fees in invoice totals"
          {:provider :deepseek :ns 'billing.rules :max-repairs 0}))
```

The spike supplies only the invoice source and the target namespace source. It does not send `.env`, the whole repository, or unrelated files. Credentials are used in the authorization header and are not printed or stored in the ledger.

Requests have a 60-second HTTP timeout and a 2400-output-token limit. The default repair budget is one additional request; `:max-repairs 0` makes exactly one attempt. The provider and instructions are deliberately scoped to this small exercise. This is not yet an unrestricted project-wide agent.

## Try the automated tours

No browser or API key needed:

```sh
bin/bl run research/workspace-spike/api_walkthrough.bl
bin/bl -p research/workspace-spike test \
  research/workspace-spike/api_test.bl \
  research/workspace-spike/gen_test.bl \
  research/workspace-spike/provider_test.bl \
  research/workspace-spike/image_test.bl
```

The walkthrough creates its own sample and checks the same operations you just used: file drafts, proposals, independent lifecycle state, a stale-source conflict, cancellation, and reopen.

One explicit real-provider smoke, with no automatic repair:

```sh
bin/bl run research/workspace-spike/deepseek_smoke.bl -- .env
```

It prints the disposable workspace path and results, never the key. Replay a saved real-provider proposal without another request:

```sh
bin/bl run research/workspace-spike/deepseek_smoke.bl -- \
  --saved /tmp/YOUR-PRINTED-WORKSPACE
```

Replay checks the source basis too. If you have changed those files since that version, it reports a conflict rather than overwriting your newer work.

## Honest prototype boundaries

- `play.change` and `play.gen` are candidate APIs. The production `dev.change` executor is untouched; this research tree is not installed as a competing production editor.
- Parsing/load verification is not an automatic test-suite run or a security sandbox.
- Trial images use private namespace identities because BEAM namespace shims are VM-global. The source and proposal keep their logical names. The supported slice is ordinary namespace declarations, requires, definitions, and explicit qualified/aliased calls; dynamic namespace tricks, arbitrary macro-generated references, and hot migration of existing closures are not promised. Private generated modules remain for the prototype VM's lifetime; restart for long exploratory sessions.
- Multi-file saving is guarded and compensates for ordinary write failures. It is not a crash-atomic transaction across several filesystem paths.
- The generation ledger acceptance write follows the source save. It does not yet share a single crash-recovery journal with that save.
- `gen/ns` is an explicit generation operation here, not the future accepted-version expansion macro. Generated namespaces are saved as ordinary source; the sidecar keeps their history. Do not embed provider calls in normal application-loading code.
- Token-level streaming, arbitrary application state migration, full namespace rename, editable candidate-version buffers, comprehensive dependent-test discovery, and the final cursor-hover/DWIM integration are outside this first API playground. `try!` returns a load receipt; a first-class interactive trial handle is a next-step API.
- The embedded API REPL shares the workspace image; the separate `/repl` endpoint uses the existing session REPL. This prototype does not yet offer independently publishable workspace REPL sessions per browser tab.
- Source files and generated versions share the proposal/view machinery; this is a place to test the API, not the finished Lisp-machine desktop.
