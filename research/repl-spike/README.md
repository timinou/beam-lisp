# repl-spike — PLAN-135 Phase 0: uncertainty retirement, measured

A throwaway-quality but fully working WebSocket REPL: per-session forked envs,
dropdown completion, syntax highlighting, interrupt, stdout streaming — built
to answer the Phase-0 uncertainty list with numbers, not opinions.

## Run it

```sh
# from the worktree root; private AOT cache so the shared lock/cache is untouched
BEAM_LISP_AOT_CACHE_DIR=$PWD/.bl-spike-aot ./bin/bl run research/repl-spike/serve.bl
# → http://127.0.0.1:7841/   (browser UI)   ws /ws   (protocol)

node research/repl-spike/probe.mjs    # scripted U1–U5 verification + timings
node research/repl-spike/probe2.mjs   # the interrupt sequence, frame by frame
```

`vendor/editor.bundle.js` is CodeMirror 6 + clojure mode + autocomplete,
esbuild-bundled to one 395 KB ESM file (host has node+esbuild; build recipe in
git history — npm i in /tmp, one esbuild call). **This is also the vendoring
answer for the final impl: one committed bundle, no runtime CDN, no build
step in the tree.**

## Verdict per uncertainty

| id | question | verdict | evidence |
|----|----------|---------|----------|
| U1 | eval over wire? | ✓ works today, in pure bl | probe.mjs U1 lines |
| U2 | completion cost? | ✓ index required, shape known | bench numbers below |
| U3 | clean interrupt? | ✓ one `:kill`, runner DOWN cleans up | probe2.mjs trace |
| U4 | web transport + CM6? | ✓ dropdown + highlighting live | shot-completion.png, shot-eval2.png |
| U5 | balanced? port parity? | ✓ harness works — and caught BUG-087 | fixtures below |
| U6 | wry desktop shell? | ✓ window opens on this Wayland host | wry_hello run log |

## Measured numbers (this host, 2026-09-20)

**Eval (U1)** — warm session, per-op: first eval 41 ms (compile), then eval
rtt **4–23 ms**. State persists across ops (`def` → visible next eval), `*1`
interned, `(println …)` streams as `out` frames while the form runs, `in-ns`
in the form moves the session's ns (read back from `current_ns` after eval).

**Completion (U2)** — corpus: **1679 public vars across all loaded nss**
(:global). Two query strategies, same corpus:

- direct scan (`Env/namespaces` × `Env/public_names` per keystroke):
  **~100–500 ms/query** — too slow, and it degrades under load (other bl runs
  on the host pushed single queries past 500 ms)
- prebuilt index (one 67–113 ms build, then filter): **1.5–2.6 ms/query**

∴ the final impl needs the materialised index + invalidation-on-intern, as
planned. Direct ETS access is *not* the answer; the enumeration, not the
lookup, is the cost.

**Docs (U2)** — `Env/doc_string` returns the **info map** `{:name :doc :ns}`
directly (not `{:ok doc}`, not a string). **`:arglists` is NOT in var meta**
(meta of a defn = `%{doc}` only). Arities live in `Env/ns_defs` entries
`{:fixed arity name clause-map module}`; real arglists would need the def_ast
walked. Phase-2 design: doc from `doc_string`'s map, arglist display from
ns_defs (arities cheap, full arglists a follow-up).

**Interrupt (U3)** — probe2 frame trace: runaway `(loop [] (recur))` starts;
400 ms later a `complete` op **still answers in 364 ms** (one eval per session,
other ops stay responsive — proven); `interrupt` → worker killed, error frame
**6 ms** later ("eval ended: :killed"); next eval on the same session fine.
Design that made it clean: eval runs in a spawn_monitor'd worker; a runner
process owns the monitor and does ALL cleanup in its DOWN clause — one cleanup
path, no interrupt/finish race.

**Transport/frontend (U4)** — WS eval rtt 51 ms cold, 4–20 ms warm. Browser
drove the real UI: dropdown with 33 items on `(ma`, ns shown per item, docs in
the side panel; clojure-mode highlighting live (shot-completion.png,
shot-eval2.png). Two adapter-level traps that WILL bite the final impl if not
recorded:

1. inbound WS frames are **bl Vectors** `[:text payload]`, not Erlang tuples
   (`BeamLisp.WebSocket.frame_vector`) — `is_tuple` silently never matches
2. CM6 keymap precedence: `basicSetup`'s Enter binding wins over a later
   `keymap.of` — the eval-on-Enter keymap must come BEFORE basicSetup (or use
   `Prec.high`)

**balanced? (U5)** — the parity harness (JS port vs server truth over 13
fixtures) flagged exactly one mismatch, and it was a **real bug in bl.repl**,
not the port: the `comment?` clause recurs with `(= ch "\n")`, ending comment
state after one character — brackets in comments miscount, so `(+ 1 2) ; oops
)` hangs the terminal repl. Filed as **BUG-087, fixed, and pinned by
test/bl/repl_test.bl (19 assertions green)**.

**wry (U6)** — `examples/wry_hello.bl` opens a WebKitGTK window on this
Wayland session, `wry/eval` mutates the live page, clean close. The desktop
shell for the final REPL is a thin page-load, no Electron.

## Operational findings (change the plan, not the code)

- **Cold boot is 54 s** with a warm shared cache but a private AOT dir (this
  worktree); the spike server then answers evals in ms. A REPL must attach to
  a warm daemon — cold-boot-per-command is the entire latency problem, already
  solved by `bl daemon` + vm.manager's warm project VMs.
- **`bl run` holds the AOT cache lock for its whole lifetime.** A long-lived
  REPL server must be a `daemon`/`serve`-class verb (lock-exempt) or take a
  private cache dir; as a `run` it starves every other bl process on the host.
- The web face already exists in the daemon: `vm.http` (Bandit router, token
  auth, POST /intent runs commands with captured output). The REPL mounts as
  routes there, with sessions = evals routed into the project VM's forked env
  (`vm.manager/run` × `env/with-env`) — the spike's per-session `env/fork`
  model maps onto it directly.
- The daemon's :ui port loopback + token model (`x-bl-token` header, crypto
  hash_equals) is the right auth seam for the REPL page too; the spike ran
  unauthenticated on loopback only.

## Files

- `serve.bl` — the spike server: sessions in ETS, eval workers + monitor
  runners, text group-leader proxy (vm.io's protocol minus ETF), completion /
  doc / bench / balanced ops, web.bl WS + HTTP
- `page.html` — CM6 UI: dropdown completion w/ docs, highlighting, Enter =
  eval when balanced (JS port of the scanner), Shift+Enter newline, history
  (localStorage), interrupt button, bench button, parity self-check
- `probe.mjs` / `probe2.mjs` — scripted verification (no browser needed)
- `vendor/editor.bundle.js` — the CM6 bundle (395 KB, esbuild, reproducible)
- `shot-completion.png`, `shot-eval.png`, `shot-eval2.png` — visual evidence
- `server.log` — boot + request log (gitignored)
