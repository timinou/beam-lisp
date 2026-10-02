# Commands

Two nouns on the command line, one rule:

> **`bl realm` is about the project in front of you. `bl vm` is about the machine.**

Every flag below belongs to the shared argv table (`bl.cli/parse-argv`). A verb
that parses its own flags is one the dispatcher rejects as unknown before it
runs.

## `bl vm` — the machine

```
bl vm [ls] [--all] [--json]       the tree: VMs → realms → routes
bl vm show ID [--json]            one VM in full
bl vm ui [--open]                 the machine console
bl vm logs ID [--lines N] [--follow]   what a VM printed: its boot and its errors
bl vm start gateway [--foreground]   the gateway (systemd unit when installed)
bl vm stop ID… | gateway | --all [--force]   ask, then TERM; --force adds KILL
bl vm prune [--dry-run]           remove what dead VMs left behind
```

### `bl vm`

```
VM               ROLE     BUILD     UP      MEM    STATE
a238fa91-4821    warm     a238fa91  4h      212M   up
  blueprint  ui      http://blueprint.test/
  knowledger ui      http://knowledger.test/
gateway-3302     gateway  a238fa91  4h      18M    up
c7704-12         warm     277640b0  2d15h   7.0G   up (old)

! 2 name(s) are claimed, and nothing answers them
    → bl vm start gateway
```

| column | meaning |
|---|---|
| `VM` | `<build>-<pid>`: unique for the life of the VM |
| `ROLE` | `warm`, `gateway`, `job` |
| `STATE` | `up`, `up (old)` (started before the registry), `gone` (with `--all`) |
| `MEM` | resident **plus swapped**, read live |

`--all` adds records whose VM is gone, so you can see what `prune` would remove.
`--json` prints `{vms, attention}`; every row carries `realms` and `routes`.

### `bl vm show ID`

One VM in full: build, pid, uptime, memory, log path, and each realm with its
routes.

### `bl vm stop`

`ID` is any of: an id, a pid, a unique id prefix, a label, or a build that
exactly one VM runs. **Nothing guesses.** An ambiguous `ID` lists the candidates
and stops none.

| exit | meaning |
|---|---|
| 0 | stopped, or already gone |
| 1 | no match, ambiguous, refused, or still running (try `--force`) |

The ladder (ask → TERM → KILL) is described in
[`architecture.md`](architecture.md). `bl vm stop --all` never includes the VM
the command itself runs in.

### `bl vm prune`

Removes stale registry records and the endpoint files of VMs that accept
nobody. `--dry-run` lists and removes nothing.

## `bl realm` — the project

```
bl realm [show] [--json]            this project's VM, routes, address, status
bl realm open [NAME] [--open]       the address of a route (default: ui)
bl realm start [--foreground] [--idle SECONDS]   start this project's warm VM
bl realm stop                       stop it
```

The realm is found the way the warm VM finds it: the nearest `env.bl` (or tree
root) above the current directory, or the directory `--root DIR` names.

Today one VM serves one realm, so `bl realm stop` stops the VM. When one VM hosts
many realms, `stop` drains only this realm and the VM stays for the others. The
verb does not change.

## Global flags

These work on every command, before a literal `--`:

| flag | meaning |
|---|---|
| `--cold` | run in a fresh VM; never use a warm one |
| `--warm` | use the warm VM, and start one if none runs |
| `--root DIR` | key the realm on `DIR` instead of the current directory |
| `--idle SECONDS` | `realm start`: stop the VM after this long unused (default 28800; 0 never) |
| `--log PATH` | `realm start`: where the VM writes what it prints |
| `--lines N`, `--follow` | `vm logs`: how much to show, and whether to keep going |

A project or `~/.config/bl/config.bl` can declare `:warm "off" \| "attach" \| "start"`.
The order is flag, then `env.bl`, then config, then the built-in default (`attach`).
Warm is the preferred path; `--cold` is the exception.

Why `--cold` is still needed, and what would remove each reason:

| reason | structural fix |
|---|---|
| testing a packaged image itself, not a warm VM | none: this is the flag's purpose |
| a child `bl` run under `timeout`: a killed client cannot cancel the command a warm VM keeps running | cancel a request when its client disconnects (follow-up) |

## Planned, not built

| command | does |
|---|---|
| `bl vm restart ID` | stop, then start the same role on the same build |
| `bl vm top` | live terminal view of the same rows |
| `bl realm restart` | drain and respawn this realm only |
| `bl realm members` | the processes a realm owns, with elapsed time |
