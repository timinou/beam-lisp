# `vm.*` — a pure beam-lisp VM manager (prototype)

A global daemon that hosts per-project **VMs** — built entirely from
beam-lisp's own concurrency + env primitives, no Elixir daemon code. The
premise: the Elixir daemon's whole workaround surface (single serial worker,
`owns_process?` special-casing, `BL_DAEMON=off/queue` tri-mode, "System.halt
kills the daemon") exists because it fakes isolation with one process. Give each
project a **capped env** and let its work be **ordinary BEAM processes under
that env**, and the BEAM manages the concurrency — the bugs stop being
expressible.

## The layers

| ns | role | built on |
|---|---|---|
| `vm.owner` | an env owns the processes spawned under it; teardown = `halt` over exactly that set | `proc.reg.bl` (monitor-retract registry) |
| `vm.scope` | scope `System/halt` to the calling VM — end my sandbox, never the node | process-dict scope + `vm.owner` |
| `vm.core` | a VM as data: `{id root base env caps status}` + lifecycle (`spawn-vm`/`serve`/`run`/`drain`) | `env.bl`, `vm.owner`, `vm.scope` |
| `vm.spec` | a VM spec from `env.bl` overlaid by gitignored `.env.local.bl`; collision-proof `:id` | `bl.env`, deep-merge |
| `vm.manager` | the global daemon: one node, many VMs; `ensure`/`list`/`run`/`serve`/`drain` | `defserver`, `vm.core` |

## What the primitives answer

- **GenServer** → `defserver` (real `:gen_server`)
- **Supervisor** → `super/defsupervisor` + `pool`
- **Registry (monitor-retract)** → `proc.reg/defregistry` — the key to env-scoped teardown
- **named process / routing** → `{:name …}` at start + name-as-value in `call`/`cast`
- **bounded child** → `fence`
- **content-addressed warm base** → `BeamLisp.Sandbox/warm!` (`:persistent_term`), consumed as `:base`

## The two hard properties (verified)

1. **A project VM cannot kill the node.** A VM's env is forked with op-scoped
   caps only; `op_of(System, :halt)` is nil, so the compile gate *rejects*
   `System/halt` inside the VM before bytecode. Measured: a `File`-read VM
   trying `(System/halt 0)` → compile error, node alive.
2. **Voluntary teardown is scoped.** `vm.scope/halt` reads the VM bound for the
   request and tears down exactly that VM's owned processes, returning an exit
   code to the router. Measured: a command's `(vm/halt 0)` kills its VM's
   members, every other VM and the node survive.

## The bug classes that vanish

| old failure (Elixir daemon) | why it can't happen here |
|---|---|
| one hung command wedges every client (single `:infinity` worker) | commands are independent BEAM processes under their VM's env; N run concurrently |
| `System.halt` kills the daemon (BUG-037) | capped VM can't name `halt`; `vm.scope/halt` is scoped |
| worker crash → `:noproc`, "daemon looks alive" | a crashed member self-retracts (monitor); the manager holds no worker to lose |
| acceptor DOWN-message leak / orphaned env rows | membership is a query, teardown enumerates the live set; no mailbox accumulation |
| ephemeral hostname collision across worktrees | `vm.spec` derives `<name>@<instance>` with a path-hash fallback |
| gitignored local overrides impossible | `.env.local.bl` deep-merges over `env.bl` |

## Status

Prototype: the five namespaces load, compile clean, and pass the smoke +
stress tests in `/tmp` (10 VMs × 5 members, crash-isolation, 200 concurrent
commands, scoped halt, capability denial). **Not yet wired**: the socket/HTTP
transport, the gateway routing to `vm.spec`'s hostnames, `bl` verb dispatch
(`bl vms`/`bl ps`), and warm-index caching per VM. Those are the integration
layer over this substrate.
