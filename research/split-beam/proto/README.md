# Split on BEAM — prototype slices

Throwaway slices that settle the questions deciding whether a `split/defapp`
can run its authority natively on BEAM, behind `web.bl`, while the browser keeps
the compiled JS half. Each one runs from the repository root. The research
sources (`research/js-actors/split-server.bl`, `split-wire.bl`, `apps/*.bl`)
are used **unchanged**: `assemble.sh` concatenates them with a head and a tail,
and three one-line `sed` shims stand in for what a real namespace provides.

| Slice | Question | Run | Answer (measured 2026-09-26) |
|---|---|---|---|
| S0 | Does the authority loop, written for the JS target, decide the same on BEAM? | `assemble.sh s0 > /tmp/s0.bl; bl run /tmp/s0.bl` | Yes. A tick commits (rev 1), an add commits (rev 2), a stale proposal is refused `stale-revision`, a missing id gives `no-such-item`, a repeated nonce gives `duplicate`, and a wrong digest gives `client-outdated`. |
| S0 | Can the glue be derived from the app *value* instead of generated source? | same | Yes. A `defapp` macro keeps the declaration twice: quoted (for the contract) and evaluated (symbols resolve to the functions). The dispatchers are ordinary functions that look up `[:intents op :check]`. |
| S0 | Is the contract digest the same on both sides? | same | Yes. The BEAM-side canonical JSON hashes to the digest the JS build stamped into `out/groceries.contract.json` (`bbf37e37…`). A browser built by the JS compiler speaks to the BEAM authority with no change. |
| S1 | Can `web.bl` host the transport (static files, `/api/app`, `/api/intent`, `/api/events` SSE)? | `assemble.sh s1 > /tmp/s1.bl; bl run /tmp/s1.bl`, then `node s1-drive.mjs` | Yes. HTTP 200 for commits, 400 `malformed-args`, 409 `stale-revision` and `client-outdated`, a duplicate answered `duplicate`. SSE: the hello carries the board and every commit is pushed as a `snapshot`. |
| S1 | Does the unchanged browser half (Worker + page + compiled client) work against it? | open `http://127.0.0.1:8791/` | Yes. See `s1-browser.png`: the page reads `live · rev 3` with the item the Node driver added, and a click ticks Cherry tomatoes, predicted and then confirmed by BEAM. |
| S2 | Can the durable log be datom facts on fjall? | `bl run s2-log.bl -- write`, then `-- read` | Yes. One entity per commit (`:split.commit/app revision actor op args nonce`), with args stored as an untyped attribute, so a BL map round-trips as itself. It reopens in a fresh VM and lists the commits in revision order. Tempids are negative integers. |
| P4 | Edge semantics BEAM ≠ JS | `bl run p4-edges.bl` | Several gaps, listed below. |

## Differences found (each becomes a rule in the plan)

- **`boolean?`** is not a core function on BEAM; the JS target accepts it. →
  add it to core (`rt.bl`), since a split app must be portable in both directions.
- **Text length.** BEAM `count` of a string counts graphemes (`"e\u0301"` → 1);
  JS `s.length` counts UTF-16 units (→ 2; `"🍌"` → 2). The wire bound
  `[:text min max]` must mean ONE thing on both sides → define it as codepoints
  and make both checks (BL `wire-ok?`, JS codec) count codepoints.
- **JSON numbers.** `bl.json` decodes `1.0` and `1e3` as floats and big integers
  exactly. `:int`/`:exact` must refuse floats (they do: `int?`).
- **Bad UTF-8 / lone surrogates** are refused by `bl.json/decode` → 400
  `malformed-json`, as on Node.
- **Arity of `:apply`.** A single-arity fn reports its exact arity with
  `BeamLisp.Ns.Rt/invocable?` (so a 2-arity apply is never called with 3); the
  real design reads arity from the declaration at macro time instead.
- **Build output depends on build order.** `split-plan` resets the fresh-name
  counter before compiling the APP, but the shells (`runtime.bl`,
  `split-*.bl`) are compiled afterwards in `split-emit!` and continue from
  wherever the counter stands. A one-app build (`JS_ACTORS_APP=groceries`)
  therefore names generated locals differently (`v_fnself_95_361` →
  `v_fnself_95_1882`) than the full build does: the same program, different
  bytes. → reset the counter per half, so a bundle's bytes depend only on its
  inputs.
