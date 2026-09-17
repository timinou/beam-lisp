# The warm daemon, and the names it answers to

A cold `bl` starts a fresh BEAM, loads what your command touches, runs it, and
exits. That is the right shape for one program. It is the wrong shape for a
day of programs: every `bl test`, every `bl ask`, every save-and-reload pays
the same startup and warms the same caches from nothing, over and over.

The daemon is the warm shape of the same `bl`. One VM per checkout, alive
between commands, holding what a cold run throws away — the compiled image, the
analysis cache, a code index built and kept warm, the ports your apps serve on.
You talk to it with the exact commands you already know; they just answer
sooner. And because it is one long-lived place, it can do something a cold run
never could: give every port a **name**, so nothing you open is a number you
had to remember.

This chapter is that loop, end to end.

---

## 1. One tree, one daemon

```
bl daemon start      # become the warm VM for this checkout (blocks; run detached)
bl daemon status     # what it is and what it holds
bl daemon stop       # let it go
```

The daemon is keyed by the checkout root — the directory `env.bl` lives in. One
tree, one daemon. Two checkouts of the same project are two daemons that never
contend, because each owns its own `build/` and its own image. You never name
the daemon or pick a port for it; the tree it sits in is its identity.

`start` becomes the daemon and blocks, so in real use it runs detached — a
`systemd --user` unit, or the launcher's background start. `status` and `stop`
are ordinary clients: they find the tree's socket, ask one question, and exit.

`status` is the whole daemon in one view:

```
bl daemon
  tree          pulse  (/tmp/pulse)
  pid           2731855
  tree_id       704adf131eb5572e
  compiler_key  3d7b098478aad42bb60b1550f4bab8bf58bfbb0a6ad87b3224df26032645d1d9
  uptime_ms     19000
  port          ui = http://pulse.test/  → 56377  (pulse, pid 2731855)
  ui            http://pulse.test/
  mcp           http://pulse.test/mcp  (the same MCP `bl mcp` serves over stdio)
  task          demo  — the pulse web app

  index         building  0/?
```

Every line here is read from **one model**. The terminal renders it; the
dashboard page renders it; the JSON endpoint serves it. They cannot disagree,
because none of them owns the truth — they are three renderings of the same
value. Add a fact to the model and it appears in all three at once.

---

## 2. Every command runs in the tree's VM

When you run a command inside a checkout that has a daemon, `bl` hands it to the
daemon instead of starting a fresh VM:

```
bl test test/foo_test.bl     # runs in the warm image — image already built
bl ask "where is auth?"      # the code index is already warm — no cold scan
bl eval '(* 6 7)'            # → 42, from a VM that was already alive
```

The command is the same command. What changes is where it runs and how fast it
answers. The image is compiled once and reused; the analysis cache is warm; the
code index built at boot is already there for the first question.

Two things make this safe to lean on:

- **Each request is its own process.** Ten commands at once are ten processes
  in the one VM, not a queue — a long `bl test` never blocks a quick `bl eval`.
- **Each request runs in a capped env.** Your shell's environment for that
  command is bound *process-locally* for the duration — never written into the
  daemon's global table, never leaking into the next command. The daemon runs a
  hundred commands and its own environment never drifts.

Your file arguments resolve against **your** working directory, not the
daemon's checkout, so `bl test test/foo_test.bl` means the file you're looking
at. The daemon is where the command runs; it is not where the command *is*.

---

## 3. Ports have names

An app serves on a port. The OS picks a number; nobody wants to type a number.
So the daemon keeps a registry of named ports, and turns each name into a host.

You declare a port in `env.bl`:

```beam-lisp
{:name "pulse"
 :ports {:web 0}}          ; 0 = let the OS choose; the name is what matters
```

and your program asks for it by name where it would otherwise write a literal:

```beam-lisp
(bl.serve/port :web 4000)  ; claim the :web port; 4000 is only the fallback
```

Now the number the OS chose stays in the registry, and the name carries the
address:

```
:web   in a project named "pulse"   →   http://web.pulse.test/
:ui    (the session's own address)  →   http://pulse.test/
```

The rule is small and total:

- The project name is the base label (`pulse`), slugged to one DNS label.
- A port name prefixes it (`web.pulse`), **except** `:ui`, which *is* the
  session's own address and answers at the bare base.
- Every name answers under `.test` and `.localhost`, nearest first:
  `["web.pulse.test" "web.pulse.localhost"]`.

If the checkout is on a non-default git branch — anything but `main`/`master`/
`trunk` — the branch qualifies the base, so a feature branch gets its own names
(`pulse-featurex.test`) and its own daemon, and never collides with `main`.
Declare `:instance "..."` in `env.bl` to pin that qualifier yourself.

Ask about names without opening anything:

```
bl ports              # every named port this session holds, with its URL
bl open web           # print the address behind the :web port
bl open web --open    # …and open it in a browser
bl ui                 # the session's own URL (the dashboard)
```

---

## 4. The gateway makes the names resolve

`http://web.pulse.test/` is a name. Something has to turn it into the right
port. That is the gateway — one process per machine, holding the port a URL is
allowed to omit (80 when it can bind it, else 7777), reading each request's
`Host:` and splicing the connection through to whichever live port **claimed**
that name.

```
bl gateway start      # the machine's name-router (one, shared by every tree)
bl gateway status
bl gateway stop
```

The gateway reads no `env.bl` and knows no projects. Its entire routing table
*is* the port registry: a claim carries the hosts it answers to, so when
`pulse` claims `:web`, the route `web.pulse.test → 56377` exists the instant the
claim lands and vanishes when the app stops. Nothing to configure, nothing to
reload.

Two more things it serves, both about making a fresh machine trust the names:

- **`/bl.pac`** — a proxy-autoconfig file. Point your browser or OS at it and
  every `*.test` / `*.localhost` host routes through the gateway automatically,
  with no `/etc/hosts` editing. Everything else stays `DIRECT`.
- **`/bl-ca.crt`** — the root certificate of the daemon's own certificate
  authority. `https://web.pulse.test/` works because the gateway mints a leaf
  certificate for each name on the fly, signed by this root. Trust the root
  once and every name your machine serves is https, no per-app setup.

`bl install gateway` and `bl install redirect` wire the gateway into a
`systemd --user` unit and forward `:80` to it, so the names survive reboots and
answer without a port at all.

---

## 5. The dashboard is the status you can click

The daemon's `:ui` port serves a page at its own address — `http://pulse.test/`
above. It is the `status` model with buttons:

| path | method | what it is |
|---|---|---|
| `/` | GET | the dashboard — the read-model, rendered as a page |
| `/model` | GET | the same model, as JSON |
| `/ports` | GET | the port table alone, as JSON |
| `/index` | GET | the code index's phase |
| `/mcp` | POST | the **same** MCP server `bl mcp` serves over stdio |
| `/intent` | POST | run one of the project's declared tasks |
| `/index` | POST | ask the index to rebuild |

The dashboard shows every declared task as a button. `env.bl` said:

```beam-lisp
:tasks {:demo {:run "src/app.bl" :doc "the pulse web app"}}
```

so the page offers **demo**, and pressing it POSTs to `/intent`, which runs the
task on the daemon's sequencer — the same place a save-triggered reload runs, so
a task you launch and a reload you triggered take turns instead of racing.

That `/mcp` row is the quiet strength: your agent tools and your browser reach
the identical MCP server, one over stdio and one over HTTP, both answering from
the warm VM that already has the index built. The tool your editor talks to and
the page you have open are the same running program.

Writes (`/intent`, `/index`, `/mcp`) carry a token the daemon minted into its
endpoint file at boot; reads are open. Loopback is not a trust boundary — any
page you visit can POST to localhost — so the token is what says *this request
came from you*.

---

## 6. The loop, in a sentence

Start the daemon in your checkout; every `bl` you already run answers from a
warm VM in a capped env; declare a port and it becomes a name; start the gateway
and the name just opens; the dashboard is that whole state, live, with a button
for every task. One VM per tree, one gateway per machine, and not a port number
in sight.
