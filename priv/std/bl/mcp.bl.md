# bl.mcp — the codebase served as facts, over the Model Context Protocol

The MCP surface turns beam-lisp's code into a **fact database** and answers a
model's questions over it. The tools are `code/list`, `code/query`,
`code/ask`, `code/verify`, `code/subscribe` and `code/poll`: ask who calls a
function, what it reaches, whether an invariant holds, what breaks if it
changes. Only answers cross the wire — never whole files.

`bl mcp` runs that server on standard input and output. An MCP client — an
editor plugin, an agent runtime, `claude mcp add`, anything speaking the
protocol — starts `bl mcp` as a child process and exchanges one JSON object per
line. The transport lives in `mcp.transport-stdio`; this verb is the CLI door
to it.

```beam-lisp
(ns bl.mcp
  (:require [bl.util :as u]
            [mcp.transport-stdio :as transport]))
```

## The verb

`run` registers the command's library roots (so the indexed sources resolve
under the client's tree) and hands the process to the transport, which blocks
until the client closes the stream. The transport writes protocol to stdout and
diagnostics to stderr, so nothing here prints.

```beam-lisp
(defn run
  "`bl mcp` — speak MCP on stdin/stdout. Returns 0 when the client disconnects."
  [_args st]
  (u/register-paths st)
  (transport/main)
  0)
```
