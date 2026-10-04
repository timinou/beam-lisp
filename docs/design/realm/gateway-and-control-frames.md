# The gateway, and how it asks a VM about a realm

For the curious: why the console never reads a project's files, and what it says to a VM instead.

## The problem

A machine runs several VMs. Each VM hosts one or more realms (a project alive inside it). A console page about a realm needs that realm's live facts: its members, its schedules, its log tail, which libraries it shadows. Those facts exist only inside the VM that hosts the realm. Three ways to get them:

| way | why not |
|---|---|
| read the project's files from the console | the files say what a project *declares*, not what is *alive*; and the console would need every project's path and permissions |
| talk to a dashboard HTTP server inside the project | a shared VM serves none (one page cannot read many roots); and every project would carry a web server for the console's benefit |
| **ask the VM** | the VM already knows; it already has an authenticated control socket for `bl realm stop` and `bl vm stop` |

So the gateway asks.

## The shape

```
 browser ──► gateway ───────────────► VM (control socket) ──► realm
              one process               <runtime>/<id>.sock
              per machine               {:bl 1 :control id {:op :realm-show :root R}}
                                        ◄── {:bl 1 :control-reply id {...data...}}
```

- The **gateway** is one process per machine. It outlives every VM, holds the port a URL may omit (80, else 7777), and serves the console. It starts lazily, on the first name anyone claims.
- A **control frame** is one request on a VM's socket: a map with an `:op`. The VM answers with data, never HTML. The gateway renders. (`wire/CONTROL-OPS` is the closed list of ops; an op not on it is refused.)
- The gateway authenticates the way `bl` does: it reads the VM's token file from the runtime directory (same user, mode 0600) and sends it in the hello. It binds `127.0.0.1` only, and every route passes the Host guard.

## The frames

| op | answers | status |
|---|---|---|
| `:realms` | the roots the VM serves | built |
| `:members` | what a realm owns: pid, role, age | built |
| `:close` / `:restart` | end or reopen one realm | built |
| `:realm-show` | one realm: alias, key, root, routes, schedules, **shadows**, deps | planned |
| `:realm-log` | the tail of the realm's log | planned |

Each reply is plain data. `bl realm show` prints the same data as text; the page renders it as HTML. One truth, two renderers, so the page and the command can never disagree (a test compares their strings).

## Naming a realm in a URL

`/realm/<alias>`. The alias is for people: `{:realm "pulse"}` in `env.bl`, else the project directory's name, de-duplicated (`pulse`, `pulse-2`). The **key** (the first 8 hex of the sha-256 of the realpath) names modules and registry rows and appears in `/api`; it is stable across restarts and bounded, which matters because every key becomes part of a module-name atom, and atoms are never collected.

## What a realm may carry that others do not see

A realm owns its namespaces by default (`BeamLisp.Ns.R<key>.<Ns>`). It may also *shadow* a library namespace, declared in `env.bl` with `:shadow`, to try a local improvement before it merges to main. The page marks such a realm with a chip (`◇ shadows 2: …`), and `bl realm diff NS` prints the difference from the library's version. See [`namespace-ownership.md`](namespace-ownership.md).

## Why not push the console into every VM

A VM can die, restart or be stopped *from the console*. A page served by the thing it stops cannot show that it stopped. The gateway is the one part of the machine that is never a realm, so it can describe all of them, including the ones that are gone.

## Cost

The gateway becomes load-bearing for the console (not for `bl`: every command works without it). It stays small: it holds a route table and renders rows; it compiles nothing and loads no project code.
