#import "../_preamble.typ": *

#wave("W3", "The session's address — named ports, one URL, and MCP on it", status: "shipped")[

A project declares the ports it serves on, the session claims them by name, and
the session itself answers on one of them:

```clojure
{:ports {:web 4000 :metrics {:port 0} :ui 7700}}
```

`bl daemon start` prints what it became:

#ran("bl daemon start",
"bl daemon up for /home/user/code/undefine/beam-lisp\n  ui:   http://127.0.0.1:44779   (ephemeral — pin it in env.bl with :ports {:ui 7700})\n  mcp:  http://127.0.0.1:44779/mcp   (the same MCP `bl mcp` serves over stdio)",
note: "the port is ephemeral unless the project pins it, and the message says exactly how to pin it")

#decision([
  The registry is FILES — one per claim, under the runtime dir — not a table in
  the daemon.
], because: [
  The collision worth catching is between *trees*: two checkouts, two daemons,
  one port 4000. A table inside one VM cannot see the other. A file can, it
  survives a crash (which is exactly when a stale claim needs sweeping), and it
  carries the owner — so the refusal can say *whose* port it is:

  #ran("a second session claims a port the first holds",
  "  {:error, {:taken, %{name: \"web\", port: 4000, root: \"/code/pulse\", pid: 90210}}}",
  note: "an error that names the tree, the pid and the port — not `address already in use`")
], instead: [
  a `GenServer` mirroring `WatchRegistry` (the plan's original sketch), which
  would have been one more in-VM table that cannot answer the cross-daemon
  question.
])

#law("a port nobody chose is nobody's")[
  `{:port 0}` asks the OS and records what it chose, so two trees on one machine
  never fight over a number. A pinned number that is taken is REFUSED, never
  quietly replaced by another — a URL that silently moves is worse than a
  startup that fails.
]

= One URL for the whole session

The `:ui` port serves the session page *and* the MCP endpoint. An editor, an
agent and a browser need one address, not a registry of them.

#figure(
  image("../img/session-page.png", width: 100%),
  caption: [The session page, as served by a live daemon on this checkout: the tree, its age, its ports, its tasks, and how to reach MCP.],
)

#proof("The page, the port table and the MCP endpoint are one server")[
  #ran("curl -s http://127.0.0.1:44779/ports",
  "[{\"claimed_at\":1789215018,\"name\":\"ui\",\"pid\":1683430,\"port\":44779,\n  \"root\":\"/home/user/code/undefine/beam-lisp\",\"tree\":\"57461829a20cc2af\"}]")

  #ran("bl ports",
  "  ui  44779  beam-lisp (pid 1683430)",
  note: "the verb reads the same claims the page shows — the registry, not a copy of it")
]

#proof("MCP over HTTP is the same server as MCP over stdio")[
  #raw("POST /mcp") with #raw("tools/list") returns the tools of #raw("mcp.server")
  — the dispatch the stdio transport calls. Two transports, one server,
  identical capabilities.

  #ran("POST /mcp  (a tools/list request with the protocol version in _meta)",
  "{\"result\": {\"tools\": [{\"name\": \"code/list\", …}, {\"name\": \"code/query\", …}, …]}}")

  The daemon-side test asserts exactly this (`test/beam_lisp/daemon_ports_test.exs`),
  because "the HTTP endpoint exists" is not the claim — "it is the same MCP" is.
]

#decision([
  The MCP index mounts on the FIRST `/mcp` request, not at boot.
], because: [
  Mounting the codebase takes seconds, and a session nobody asks for MCP should
  not pay for it — the same rule every lazy verb follows. The cost lands on the
  request that wants it, where it is visible, rather than in a warm-up thread
  nobody can see.
])

= The bug this wave uncovered

The first `/mcp` request failed with `no source for codebase on the load path`,
in a namespace that ships in `priv/std`. The cause was in the loader, and it was
not MCP-specific: a namespace whose `ns` form carries reader metadata declares
itself as

```clojure
(ns ^{:instr {:for "mcp" …}} codebase …)
```

and `declared_ns/1` — the function that checks a candidate file really declares
the namespace being loaded — read the token after `ns`, which is `^{…}` rather
than the name. So `find_file/1` rejected the file as `{:wrong_ns, …}` and
`source_content("codebase")` answered `nil` for a file sitting in the search
path. `examples/mcp-demo.bl` had been failing this way already.

#decision([
  `declared_ns/1` now skips reader metadata before the name — repeated, because
  metadata stacks (`^:private ^:const x`), and with nesting and strings honoured
  (`^{:doc "a } in a string"}` is not a delimiter).
], because: [
  The declared name is the first SYMBOL after `ns`. Metadata is not a symbol, so
  reading it as the name was never a correct parse — it merely went unnoticed
  until a namespace that ships in priv used the form.
])

#proof("The fix, on the example that had been failing")[
  #ran("bl run examples/mcp-demo.bl",
  "✓ All 11 exchanges passed (2026-07-28 envelopes, real self-index)",
  note: "11 MCP exchanges — discover, tools, resources, prompts, subscribe/poll, a bad version — end to end")
]

= Numbers, and how they were checked

#measure("new module", "lib/beam_lisp/daemon/ports.ex — claim · release · list · port_of · holder")
#measure("new module", "lib/beam_lisp/daemon/http.ex — the page · /ports · /mcp")
#measure("tests", "9 ExUnit (test/beam_lisp/daemon_ports_test.exs) + 6 bl (test/bl/system/ports_test.bl)",
  note: "ephemeral assignment · idempotence · cross-session refusal · stale sweep · busy port · the page · the MCP dispatch · the message's three shapes")

#dogfooded[
  The screenshot above is a real daemon for this checkout, opened in a real
  browser, and the transcripts are that session's own output. The port claim in
  the screenshot (`ui 44779`) is the claim `bl ports` printed and `/ports`
  served — one registry, three readers.
]

]
