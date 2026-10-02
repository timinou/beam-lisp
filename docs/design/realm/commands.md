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
bl vm stop ID… | --all [--force]  ask, then TERM; --force adds KILL
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
    → bl gateway start
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

Removes stale registry records and the endpoint files of daemons that accept
nobody. `--dry-run` lists and removes nothing.

## `bl realm` — the project

```
bl realm [show] [--json]     this project's realm: VM, routes, address
bl realm open [NAME] [--open]   the address of a route (default: ui)
bl realm stop                 drain this project's realm
```

The realm is found the way the daemon finds it: the nearest `env.bl` (or tree
root) above the current directory, or `BL_DAEMON_ROOT`.

Today one VM serves one realm, so `bl realm stop` stops the VM. When one VM hosts
many realms, `stop` drains only this realm and the VM stays for the others. The
verb does not change.

## The top level stays small

| old | new |
|---|---|
| `bl daemon start\|stop\|status` | `bl realm …` (start is implicit; see [`migration.md`](migration.md)) |
| `bl ports` | the tree in `bl vm`, and `bl realm show` |
| `bl open NAME` | `bl realm open NAME` |
| `bl gateway start\|stop\|status` | `bl vm` lists it; `bl vm stop gateway` |
| `bl ui` | stays: the one human front door |

The first slice adds `vm` and `realm` and leaves the old verbs working. The
cutover removes them (see the migration plan).

## Planned, not built

These are in the plan and are not in the first slice:

| command | does |
|---|---|
| `bl vm logs ID [-f]` | tail a VM's log (needs detached VMs to write one) |
| `bl vm restart ID` | stop, then start the same role on the same build |
| `bl vm start [warm\|gateway]` | start a VM explicitly |
| `bl vm top` | live terminal view of the same rows |
| `bl realm start` | explicit, foreground (systemd, CI) |
| `bl realm restart` | drain and respawn this realm only |
| `bl realm members` | the processes a realm owns, with elapsed time |
| `bl vm config` | show and set auto-start, idle timeout, scope |
