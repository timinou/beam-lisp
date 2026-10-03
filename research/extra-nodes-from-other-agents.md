# Extra nodes from other agents

Findings made in OTHER repositories and sessions that bear on this spike. The
rule of the file: one node per finding, each stating WHAT was decided, WHERE the
code lives, and WHAT it changes for a VPS. Written so this spike does not have to
rediscover it.

---

## Node: the access log ships to journald — journald owns retention

**Date:** 2026-09-20. **From:** the Cabinet Filali incident (a 500 with no log
line naming the request) + the language-level access log that came out of it.
**Lives in:** `beam-lisp` — `priv/lib/web.bl` (`web/serve`'s plug wrapper),
`priv/lib/live/app.bl` (`serve` forwards `:log` / `:log-pretty`; `router` stashes
the principal on the conn), `priv/std/bl/serve.bl.md` (`bl.serve/pretty`,
`--pretty-log` / `--no-pretty-log`, `env.bl`'s `:serve {:access-log {:pretty …}}`).

### What was decided

The HTTP edge logs ONE EDN record per request to **stderr**, ON by default:

```
{:at 1758354722135 :method "get" :path "/queries/q:filali:-4DO2A5OXWARZ" :status 200 :ms 3.2 :me "partner:filali"}
```

- `:log` = `:stderr` (default) | `:off` | a 1-arg fn (the record as data).
- `:log-pretty` = one field per line — a FOREGROUND shape, off by default.
- The wrapper owns a `try/catch` because the status of a raising screen exists
  nowhere in bl: Bandit maps the exception itself (`Plug.Exception.status/1`),
  replies 500 with an EMPTY body, and logs it. A log that does not catch there
  is blind exactly when it matters; the record carries `:err`.

### Why stderr, and what that means on a VPS

`config/config.exs` points the Elixir logger at `:standard_error` and reserves
**stdout for a program's own DATA** (`bl run --json`). A log on stdout would
corrupt machine-readable runs. So the access log is stderr — and under systemd,
a unit's stderr IS the journal.

Consequences, in order of how much they bite:

1. **This server must never own a log file.** No app-side rotation, no
   `logrotate`, no `SystemMaxUse` in the app. Retention, rotation and the disk
   budget are journald policy. If the spike proposes a log file, it is proposing
   a second implementation of something the unit already gets for free.
2. **`Storage=volatile` is the trap.** Volatile storage keeps the journal in
   `/run/log/journal` — it dies with the reboot that you most want to
   investigate (the crashing server is usually the one that took the machine
   down). Want persistent storage, sized deliberately:
   `/etc/systemd/journald.conf` → `Storage=persistent`, `SystemMaxUse=…`,
   `SystemKeepFree=…`, `MaxRetentionSec=…`. Verify with `journalctl --disk-usage`
   and `systemctl cat systemd-journald`.
3. **User unit or system unit decides the door.** A `--user` unit (the shape the
   Filali instance uses today) logs to the USER journal:
   `journalctl --user -u <unit>`. A system unit needs `journalctl -u <unit>`
   (and root, or a `systemd-journal`/`adm` group membership). The trap is
   symmetric: after a VPS move, an operator greps the wrong journal and
   concludes "no logs".
4. **One entry per LINE.** journald gives every line its own record, so the
   multi-line `:log-pretty` shape is a foreground-terminal shape and must stay
   OFF in a unit (that is why the default is off and why the flag exists).
5. **Free metadata, and one redundancy.** journald already stamps
   `__REALTIME_TIMESTAMP`, `_SYSTEMD_UNIT`, `_PID` and priority on every entry,
   so the record's `:at` (epoch-ms) is redundant — it exists for the case the
   log is tailed by hand or shipped off-box. `journalctl -o cat -u <unit>` then
   emits PURE EDN lines, which `bl` itself can read back.
6. **Both halves of a 500 are in the journal.** Bandit logs the exception and
   its stack trace; the access record logs the status and one line of message.
   `journalctl -u <unit> | grep ':status 500'` finds the requests without
   reading tracebacks.

### What this spike should decide

- Does the client instance's journal need to survive a reboot? (If yes:
  `Storage=persistent` + a size budget for THIS box, not the default.)
- Is the journal shipped anywhere (a collector, `systemd-journal-upload`,
  `journalctl -f -o json` into Garage S3), or is it local-only with a retention
  cap? Local-only means a lost box is a lost incident history.
- Does the unit need `--pretty-log` ever? (Default: no. Its only legitimate use
  is a human watching `journalctl -f` during a live debugging session, and the
  one-line EDN record already greps better.)
- The verb's banner line now says where the log goes
  (`bl serve: access log → stderr, one EDN line per request`), so the answer to
  "where did my logs go" is on screen at boot. Keep that line in any wrapper.
