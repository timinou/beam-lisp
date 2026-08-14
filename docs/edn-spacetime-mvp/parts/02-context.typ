#import "../_preamble.typ": *

= Context: what exists today

This spec assumes the Spacetime improvement plans already recorded in
`verse/!tasks` are implemented. §3 lists exactly which ones the duet leans
on. This section states the ground truth both sides start from.

== The beam-lisp spell

`spell/` is a first-principles recreation of `spell.jank`: a stateful,
process-heavy, self-modifying beam-lisp application, organised in clusters:

#table(
  columns: (auto, auto, 1fr),
  inset: 6pt,
  stroke: 0.4pt + tint(mutec, 60%),
  fill: (x, y) => if y == 0 { panelbg },
  [*namespace*], [*status*], [*role*],
  [`spell.ui`],    [implemented], [pure EDN view constructors (`el`, `text`), `realize`; retired by this spec],
  [`spell.clay`],  [stub],        [renderer Port client; retired by this spec],
  [`spell.store`], [implemented], [named Agents, reload-proof state, wire taps; kept],
  [`spell.fence`], [implemented], [unlinked monitored eval with deadlines; kept],
  [`spell.self`],  [stub],        [compile/load/verify/revert self-rewrite; kept, extended (§8)],
  [`spell.providers`], [stub],    [model/tool/agent contracts; orthogonal],
)

Relevant primitives that survive:

#bl(```
(fence f args timeout-ms)            ;; isolated, deadline-bound eval
(state-ensure :session [])           ;; named, code-independent state
(state-swap! :session (fn [s] ...))
(tap! :frame-log value)              ;; bounded wire-tap ring buffer
(tap-contains? :frame-log "…")       ;; test discipline: assert on the wire
```)

#note[
  The wire-tap discipline — assert on emitted frames/commands, not app
  internals — generalises cleanly: in the duet, the "wire" is the set of MCP
  tool calls and signal envelopes sent to `spacetime live`. `spell.store/tap!`
  stays the testing backbone.
]

== Spacetime: the live environment (`spacetime mcp`)

`spacetime mcp` is a stateful, line-delimited JSON-RPC 2.0 server over
stdio, registered with Spell via `spell.kdl`:

#raw(lang: "kdl", block: true, ```
mcp {
    server "spacetime" type=stdio {
        command "cargo"
        args "run" "--quiet" "--" "mcp"
    }
}
```.text)

It owns a `LiveStore` (functions, instances, event sequences, cursors) behind
a lazily started HTTP live plane. Browser actions enter one generic sink
(`POST /__mcp/signal/{id}`); the agent consumes them with bounded pull
(`st_await`). The tool surface the duet builds on:

#table(
  columns: (auto, 1fr),
  inset: 6pt,
  stroke: 0.4pt + tint(mutec, 60%),
  fill: (x, y) => if y == 0 { panelbg },
  [*tool*], [*purpose*],
  [`st_fn_put`],   [register/update live `.st` function source + revision + compile artifacts],
  [`st_mount`],    [mount a function as a browser instance; returns URL / input / events resource],
  [`st_await`],    [bounded wait for the next agent-audience event from an instance],
  [`st_inspect`],  [contract, diagnostics, input, event history of functions/instances],
  [`st_unmount` / `st_fn_delete`], [lifecycle teardown],
  [`st_env_open` / `st_tab_open` / `st_env_close`], [environment + tab management],
  [`st_elicit`],   [server→client typed prompt (`elicitation/create`)],
  [`st_workbench`],[mount the unified workbench shell],
)

The interaction kit (`stdlib/__mcp__/kit/{picker,confirm,form,review}.st`) is
already ordinary `.st` functions over this machinery: `@mcp-input` declares
the payload, `@mcp-action` marks async buttons, `@mcp-submit` collects form
values into `payload.values`, and the agent's `st_await` returns the result.
Markdown rendering ships as `stdlib/md` (`render-markdown`, snarkdown-based).

== Spacetime: the LiveView bridge (`elixir/spacetime_lv`)

The Elixir bridge proves the second half of the duet: Spacetime as a
#emph[component inside a state-owning host]. The thesis, verbatim from the
architecture research: “The host is config. The page is the program.”

#st(```
@host $counter : live("SpacetimeLvWeb.CounterLive")

@data subscribe $count from $counter : count ;

@data stream $fx from $counter {
  receive to Effect { "flash" => Flash($.payload.message); }
}

@data signal $inc() to $counter {
  send emit "inc"
  receive to IncResult { "ok" => Bumped($.reply as number); _ => Failed($.reply); }
  policy latest
}
```)

#bl(```
;; the mirror-image contract on the Elixir side (use-macro DSL):
;;   events do event(:inc) end
;;   assigns do assign(:count, :integer) end
;;   pushes  do push(:flash, message: :string, kind: :atom) end
```)

Assigns flow server→browser as diffed `st-set` payloads into
compiler-registered setters (`phx-update="ignore"` — templates are never
diffed, only data). Events flow browser→server through `handle_event` with
correlated `{:reply, …}` decode. A `<Module>.contract.json` sidecar +
SHA-256 fingerprint lets the Rust checker prove the seam. This is the exact
pattern the duet generalises: #emph[half the state machine in the BEAM, half
in the browser, and the compiler proves the seam.]

== Spacetime signals: the canonical model

The S1 signal model (PLAN-038, FEAT-110) is the shipped direction and the
duet's contract vocabulary:

+ `@host` — transport/config binding (`http`, `ws`, `live`).
+ `@data signal` — one correlated reply; `@data stream` — many.
+ one matcher family shared by `@match`, `receive` decode, and `@handle`.
+ `@handle $sig { optimistic … receive … }` with scoped cascade.
+ `policy latest|queue|parallel|drop [timeout] [retry]`.
+ `as Type` ascription; `receive to Sum` names the response sum; `final`
  marks terminal stream arms.

The compiler registry introspection this enables — a function exposing its
inputs, transports, and response variants without a hand-fed contract — is
what the EDN load gate (§5.4) queries.
