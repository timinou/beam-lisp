# 09 — Platform swap: blue-green is for the floor

A platform update — a new container image, OTP, or OS closure that cannot
hot-load — cuts over behind one stable public port, and a concurrent request
stream sees one clean blue→green transition with at most one in-flight request
lost.

## The claim

From `docs/design/vps/zero-downtime.md` **§L3 — the node swap**: a new bl
closure or generation *cannot* hot-load, so the node itself is treated as a
deployable unit — build the next generation off the critical path, boot it as a
second node process, then have the gateway re-claim each name so connections
splice across. `bootstrap.md` (**the OS floor**) supplies the precondition: the
gateway is a *separate OS process* holding the public port, so a node swap is
to it just a re-claim — it never lets go of the ports. The spike proves the
load-bearing half of that: a platform generation is replaced across real
containers behind a port that never moves, and the honest bar is met — both
generations served, exactly one transition, ≤1 in-flight drop.

It also carries the *scope* correction the suite makes explicit: **blue-green is
for the platform floor only**. Everything that is bl — an app namespace, the
language's own stdlib — updates by hot reload inside the one long-lived node
(spike 04). Blue-green is reserved for what cannot hot-load.

## The idea

A conventional deploy has a boot-shaped hole in it. To put new code or a new
runtime on a box you stop the old process, swap something on disk, and start the
new one — and during that gap the port is dark. Users hit connection refused.
The fix that "eliminates" the gap is blue-green: run the old version (**blue**)
and the new version (**green**) side by side, point the public port at blue,
bring green up warm, then flip the pointer. Measured correctly, *nothing the
client can see changed*: the public port stayed bound the whole time, and the
flip is a re-point, not a restart.

The thing that makes blue-green safe is a stable front: one port, one listener,
constant across the swap. The thing that makes it *hard* is that "point the port
at green" is not free — if you tear the listener down and rebuild it, there is a
sub-second window where nobody is listening, and a request that lands in that
window dies. A real reverse proxy closes the window by *draining*: keep the old
connections alive, stop sending them new ones, splice fresh ones to green, only
close blue when it is empty. A dumb re-point loses at most the one request that
was mid-flight at the instant of the re-bind.

Why this matters for devops: the alternative is a maintenance window nobody
wants and a rollback procedure nobody has rehearsed. If the platform is a
deployable unit flipped behind a stable name, then a platform upgrade is an
ordinary transaction with a declared transition — and the old generation stays
bootable, so a failed swap is a re-point back, not a rescue.

```
blue serving ─┐
              ├─→ stable public port (never dark) ─→ client stream
green warm ───┘        flip = re-point, not restart
∴ a platform swap is: warm standby + one atomic re-point + retire the old
```

This spike builds exactly that in miniature, measures the request stream across
the flip, and asserts the result.

## Walkthrough

The spike is a shell script (`research/vps_spike/podman/blue_green.sh`) plus a
tiny bl node it runs inside each container (`podman/node.bl`), wrapped by a
cgroup launcher (`podman/scoped.sh`). Read them in order.

### Step 0 — the constants and the honesty in the header

```bash
BL=/home/user/code/undefine/beam-lisp/bl-v2026.4
DROP=/home/user/.local/share/drop
HERE="$(cd "$(dirname "$0")" && pwd)"
NODE_BL="$HERE/node.bl"
BASE=docker.io/library/archlinux:latest
GW_PORT=19090
BLUE_PORT=18091; GREEN_PORT=18092
STREAM=$(mktemp)
```

One bl drop, one shared cache drop, one node program. The *public* port is
`19090`; each generation gets its own internal port (`18091` blue, `18092`
green). `BASE` is the stock `archlinux` image — chosen so the container glibc
matches the host drop's build. `STREAM` is a temp file the request stream appends
to; every line is one answer or `ERR`. The header states the shape being tested
and its limit up front: a re-point may lose **at most one in-flight request** in
the sub-second bind window, and a connection-draining gateway closes even that.

### Step 1 — `gw_to`: the stable gateway and its re-point

```bash
gw_to(){ # (re)point the stable gateway at a backend port. ONE listener at a
  local old="${GWPID:-0}"
  [ "$old" -gt 0 ] 2>/dev/null && { kill "$old" 2>/dev/null; wait "$old" 2>/dev/null; }
  socat TCP-LISTEN:$GW_PORT,reuseaddr,fork TCP:127.0.0.1:$1 >/dev/null 2>&1 & GWPID=$!
  sleep 0.2
}
```

This is the whole gateway: `socat` bound to `GW_PORT`, forwarding every accepted
connection to `127.0.0.1:$1` (the backend port). `fork` gives one handler per
connection, so the concurrent probes never queue behind one another.
`reuseaddr` lets the new bind take the port the old listener just freed. A
re-point is: kill the old listener, `wait` for the port to free, then bind the
new one — a fresh bind on a just-freed port, which is near-atomic. The `sleep
0.2` after the bind is a settle pause so the next probe does not race the
listener's own startup. The public port number is a constant; only the *backend*
it points at changes. That constant is what the client experiences as
"nothing happened".

The comment above it is the spike being honest about the primitive: socat has no
live re-point and no draining, so this is "the honest shape of the primitive" —
and the ≤1-drop bar is the consequence.

### Step 2 — `cleanup` and `trap`: nothing outlives the run

```bash
cleanup(){ podman rm -f bl-blue bl-green >/dev/null 2>&1; killpid "${GWPID:-0}"; killpid "${LOADPID:-0}"; pkill -f "socat TCP-LISTEN:$GW_PORT" 2>/dev/null; rm -f "$STREAM"; }
trap cleanup EXIT
```

On any exit — pass, fail, or error — both containers are force-removed, the
gateway and the load process are killed, any stray socat on the port is reaped,
and the stream file is deleted. A platform-swap demo must not leave a generation
running: the retired blue is gone, and so is the green it just promoted. The
`trap cleanup EXIT` makes that unconditional.

### Step 3 — `run_node`: a generation is a real container

```bash
run_node(){ # name port gen
  podman rm -f "$1" >/dev/null 2>&1
  podman run -d --name "$1" -p "$2:8080" \
    -v "$BL:/bl:ro" -v "$DROP:/root/.local/share/drop:ro" -v "$NODE_BL:/node.bl:ro" \
    -e BL_DAEMON=off -e "GEN=$3" "$BASE" /bl run /node.bl >/dev/null 2>&1
}
```

Each generation is a **real rootless-podman container**. It is started detached
(`-d`) with a name (`bl-blue`/`bl-green`), publishing the host port `$2` to the
container's `:8080`. It mounts three things read-only: the bl drop at `/bl`, the
shared drop cache at `/root/.local/share/drop`, and this node program at
`/node.bl`. Two env vars configure it: `BL_DAEMON=off` runs the node in the
foreground (so the container's PID 1 is the node), and `GEN=$3` is the
generation label — `blue` or `green` — that the node will answer with. The
command is `/bl run /node.bl`: the real bl runtime executing the real node
program. This is why an image swap is a *platform* event — the container is the
floor, and it cannot hot-load a new floor.

### Step 4 — `wait_up`: warm means reachable

```bash
wait_up(){ for _ in $(seq 1 40); do curl -sf --max-time 2 "http://127.0.0.1:$1/" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
```

Up to 20 seconds of polling (`40 × 0.5s`) against the generation's internal port
until it answers a real HTTP request. A generation is not "warm" because the
container started; it is warm because it *serves*. Booting green but pointing
the public port at it before this returns is the classic blue-green bug — see
Exercise 1.

### Step 5 — the node itself

`node.bl` is the workload each container runs. It answers its generation string
on `:8080`:

```clojure
(def gen-raw (erlang/apply :os :getenv (list (erlang/binary_to_list "GEN"))))
(def genb (if (list? gen-raw) (erlang/list_to_binary gen-raw) (erlang/list_to_binary "?")))

(defn- resp []
  (erlang/iolist_to_binary
    (list "HTTP/1.1 200 OK\r\nContent-Length: "
          (erlang/integer_to_binary (erlang/byte_size genb))
          "\r\nConnection: close\r\n\r\n" genb)))
```

It reads `GEN` from the environment and renders a minimal HTTP/1.1 `200 OK` whose
body is just that generation label (`blue` or `green`). This is deliberately the
smallest possible server: the spike measures *which generation answered*, not
what it said.

```clojure
(defn- handle [s]
  (erlang/apply :gen_tcp :recv (list s 0 2000))       ; drain request
  (erlang/apply :gen_tcp :send (list s (resp)))
  (erlang/apply :gen_tcp :close (list s)))
```

The handler reads the request (enough to consume it), sends the response, and
closes — matching the `Connection: close` it advertised.

```clojure
(def lsock
  (elem (erlang/apply :gen_tcp :listen
          (list 8080 (list :binary (tuple :active false)
                           (tuple :reuseaddr true) (tuple :backlog 128)))) 1))

(println (str "node gen=" genb " listening :8080 (concurrent)"))

(loop []
  (let [r (erlang/apply :gen_tcp :accept (list lsock :infinity))]
    (when (= :ok (elem r 0))
      (let [s (elem r 1)]
        (erlang/spawn (fn [] (handle s))))))
  (recur))
```

A real `gen_tcp` listener on `:8080` with a `:reuseaddr` socket and a backlog of
128. The accept loop **spawns a handler per accepted connection**, so the
gateway's concurrent probes never serialize — the node is genuinely concurrent.
That matters: the stream and the gateway's own probe overlap, so the node must
serve them in parallel for the measured stream to reflect the swap rather than
the node's queueing discipline.

### Step 6 — start BLUE, point the gateway at it

```bash
say "── start BLUE (generation 1) ──"
run_node bl-blue "$BLUE_PORT" blue;   wait_up "$BLUE_PORT" || { say "blue failed to boot"; exit 1; }
gw_to "$BLUE_PORT"; sleep 1
say "  gateway → $(curl -s --max-time 2 http://127.0.0.1:$GW_PORT/)"
```

Blue is the incumbent. It is booted, confirmed serving, and then the gateway is
pointed at it. The printed `gateway → blue` is a real request through the public
port proving the route works before the swap begins.

### Step 7 — pre-boot GREEN as a warm standby

```bash
say "── pre-boot GREEN (generation 2) as a warm standby ──"
run_node bl-green "$GREEN_PORT" green; wait_up "$GREEN_PORT" || { say "green failed to boot"; exit 1; }
say "  green warm on :$GREEN_PORT (not yet serving public traffic)"
```

Green is booted and made warm **while blue keeps serving**. It listens on its own
internal port and takes no public traffic yet. This is the load being moved off
the critical path of the swap: by the time the flip happens, green is already
up and answering — the flip itself is not a boot.

### Step 8 — the concurrent stream spanning the swap

```bash
( for _ in $(seq 1 50); do
    r=$(curl -s --max-time 2 "http://127.0.0.1:$GW_PORT/" 2>/dev/null)
    printf '%s\n' "${r:-ERR}" >> "$STREAM"; sleep 0.1
  done ) & LOADPID=$!

sleep 2                                          # stream runs on BLUE for ~2s
say "── CUT OVER: gateway re-claims the public port → GREEN ──"
gw_to "$GREEN_PORT"                             # atomic re-point; listener never down
say "  gateway → $(curl -s --max-time 2 http://127.0.0.1:$GW_PORT/)  (cut over)"
wait "$LOADPID" 2>/dev/null                     # stream keeps running on GREEN for ~3s
podman rm -f bl-blue >/dev/null 2>&1            # old generation retired
```

A background subshell issues **50 requests through the stable public port**,
0.1 s apart (~5 s total), appending each answer — or the literal `ERR` on failure
— to the stream file. It starts on blue. After ~2 s the script **cuts over**:
`gw_to "$GREEN_PORT"` re-points the gateway to green, and the printed `gateway →
green (cut over)` confirms the new backend is live. The stream keeps running for
another ~3 s, now answered by green; then the old generation is retired with
`podman rm -f bl-blue`. Throughout, the client only ever knew port `19090` — the
transition is that the *answers* change from `blue` to `green`, once.

### Step 9 — the verdict: exactly one transition, ≤1 drop

```bash
mapfile -t seen < "$STREAM"
errs=$(printf '%s\n' "${seen[@]}" | grep -c ERR || true)
runs=$(printf '%s\n' "${seen[@]}" | uniq | grep -cE 'blue|green' || true)
answers=$(printf '%s\n' "${seen[@]}" | grep -E 'blue|green' | sort -u | tr '\n' ' ')
say "── request stream across the platform swap ──"
say "  total: ${#seen[@]}  errors: $errs  answers: $answers  segments(uniq-runs): $runs"
```

`seen` is every stream line in order. `errs` counts failed requests. `runs`
passes the stream through `uniq` — which collapses *adjacent* duplicates — and
counts how many contiguous `blue`/`green` **segments** remain: `2` means one
blue→green transition, a higher count would mean flapping. `answers` is the
sorted set of distinct labels the stream saw. The line printed is the evidence
line: total requests, errors, which generations answered, and how many segments.

```bash
if [ "${#seen[@]}" -gt 10 ] && [ "$errs" -le 1 ] && [ "$runs" -eq 2 ] \
   && printf '%s\n' "${seen[@]}" | grep -q blue && printf '%s\n' "${seen[@]}" | grep -q green; then
  say ""; say "PASS 09_platform_swap  (blue-green is for the PLATFORM; apps stay hot; ≤1 in-flight drop at cutover)"
else
  say ""; say "FAIL 09_platform_swap  errors=$errs segments=$runs answers=$answers"
fi
```

The bar has four conjuncts: the stream actually ran (`>10` requests), **at most
one** request failed, there were **exactly two** segments (one transition, no
flapping, no extended outage), and *both* generations were observed. The comment
above the assertion states the honest standard: a real process cutover may lose
at most the one request in flight at the instant of re-claim; the real gateway
closes even that gap, but the *shape* the primitive must guarantee here is
"exactly one clean transition".

### Step 10 — `scoped.sh`: the harness runs under its own blast radius

```bash
exec systemd-run --user --scope --collect \
  -p MemoryMax="$MEM" -p MemorySwapMax=0 -p TasksMax="$TASKS" \
  -p RuntimeMaxSec=200 \
  --unit="bl-vps-spike-$$" \
  "${CMD[@]}"
```

`scoped.sh` runs any command inside a **hard resource cgroup**. `MemoryMax=1G`
caps memory; **`MemorySwapMax=0` forbids swap**, so memory pressure cannot be
pushed into swap/zram — a runaway is killed within its scope instead of dragging
the host into zram thrash. `TasksMax=96` caps process/thread count (a fork bomb
dies here, not on the host). `RuntimeMaxSec=200` bounds wall time. `--collect`
cleans the unit up afterward; `--scope` runs synchronously in the caller's scope.
With no arguments it defaults to running `blue_green.sh`.

This is the design's **blast-radius thesis turned on the harness itself**: the
same rule that makes an untrusted workload safe — *a runaway dies in its own
scope and never starves the host* — is applied to a demo that boots two
containers and a container runtime. It exists because a synchronous heavy run
**twice froze the agent host** (memory pressure plus zram). The fix is structural:
give the experiment its own ceiling, so it cannot take the machine down.

## What's real vs modelled

The most important section, organ by organ.

**Real — exercised as-is:**

- **Rootless podman and real containers.** `podman run` boots real containers
  from `docker.io/library/archlinux:latest`, with real port publishing, real
  read-only bind mounts, and real env injection. Nothing about the container
  boundary is simulated.
- **A real bl node in each generation.** Each container runs the real bl runtime
  (`/bl run /node.bl`) executing a real `gen_tcp` listener and answering real
  HTTP over `:8080`, spawning a handler per connection. These are two genuinely
  separate OS processes in two genuinely separate namespaces.
- **A real stable port and a real request stream.** `socat` holds `19090` for the
  whole run and forwards over loopback; the stream is 50 real `curl` requests
  spanning the cutover on the wire. The measurement — which generation answered,
  how many errors, how many segments — is taken from actual TCP responses, not
  from a model of them.
- **Real kernel-enforced containment.** `MemoryMax`, `MemorySwapMax=0`,
  `TasksMax`, `RuntimeMaxSec` under a systemd `--user` transient unit/scope are
  enforced by the kernel/cgroup, not advisory.
- **The archlinux base is chosen for glibc/ABI parity** so the host-built bl drop
  runs unchanged inside the container — the container is a true platform floor,
  not a re-linked shim.

**Modelled / simplified — named honestly:**

- **The gateway is socat, not `vm/gateway.bl`.** This is the load-bearing
  simplification. `gw_to` is a *kill-old, bind-new* re-point: it tears the
  listener down and rebuilds it on the new backend. Because the rebind hits a
  just-freed port it is near-atomic, but it is **not** drain-aware — it can drop
  at most the one request in flight in the sub-second window between `kill` and
  `bind`. The **real `vm/gateway.bl`** — the separate OS process that holds the
  public port and the route table (`vm.ports`, on disk via port claims) — closes
  that window with **connection draining**: it stops feeding the old backend, lets
  its live connections finish, splices new ones to green, and only then retires
  blue. The spike's `≤1 error` bar is exactly the price of using a primitive that
  lacks draining, and the header says so.
- **Routing is by port, not by name.** The real gateway reads a request's `Host:`
  and splices to whichever live port *claimed* that name, and re-claims a name on
  swap. Here `gw_to` forwards every connection to one backend port with no name
  in the decision. The transition shape (a re-point under a constant public
  address) is faithful; the name-claim machinery is not present.
- **No Nix closure build, no OS generation (`bootstrap.md`).** In the design,
  §L3 step 1 is `flake builds generation N+1` and step 2 boots
  `bl-node@next` from it; the old closure stays on disk and bootable. Here both
  "generations" run the **same** archlinux base and the **same** bl drop — only a
  `GEN` env var and the container name differ. The spike proves the *transition
  mechanism* (warm standby + constant port + single re-point), **not** that a
  genuinely different platform version was built and rolled out. There is no
  flake, no `systemd` node unit, no closure on disk.
- **No state migration or drain.** §L3 steps 3 and 5 are "envs migrate live:
  checkpoint to datom on drain, rehydrate on the new node" and "old node drains
  to empty, unit stops". `node.bl` is **stateless** — it answers a constant — so
  nothing is checkpointed, rehydrated, or drained. The old generation is not
  drained to empty; it is force-retired with `podman rm -f` once the stream is
  done. The suite's live-state handoff (the level-2 mechanism, `zero-downtime.md`
  §L2) is exercised elsewhere, not here.
- **Blue-green is scoped to the platform floor only — and this demo shows why.**
  The whole point of the spike (per its header and spike 04) is that *app and bl
  updates never do this*. They hot-reload inside the long-lived node with zero
  restarts, because a `defn` swap is atomic per var. Blue-green is the fallback
  for exactly the things that cannot hot-load: a new container image, OTP, OS
  closure. Tuning the stream's cadence or the sleep windows changes which request
  is the unlucky in-flight one; it does not change the fact that a restart is what
  the platform floor requires and bl code does not.
- **Timing is paced by `sleep`, not by events.** The swap is sequenced with
  `sleep 0.2` (post-bind settle), `sleep 1`/`sleep 2` (stream on blue), and
  `wait "$LOADPID"` (stream on green) — a demo harness, not a drain protocol. A
  real gateway decides when blue is empty; here the script decides by clock.

## Run it

```sh
research/vps_spike/run.sh --podman
```

This runs the light bl spikes **and** 09. The 09 run is launched **detached under
a systemd `--user` transient unit** named `bl-bg` — never synchronously in the
calling shell — with hard caps: `MemoryMax=1200M`, `MemorySwapMax=0`,
`TasksMax=96`, `RuntimeMaxSec=150`, output redirected to `/tmp/bg.out`. `run.sh`
polls `systemctl --user is-active bl-bg` until it goes inactive, then reads the
verdict from `/tmp/bg.out`. Detaching under a capped cgroup is the containment:
a runaway platform-swap cannot starve the agent host, which is the same
blast-radius rule the design applies to untrusted workloads, applied to the
harness that demonstrates it.

`run.sh --podman` skips 09 cleanly when `podman` or `systemd-run` is absent. You
can also invoke the wrapper directly — `research/vps_spike/podman/scoped.sh` runs
`blue_green.sh` under a `1G/96` scope by default, or
`scoped.sh 2G 128 -- bash podman/blue_green.sh` for custom caps.

Expected tail (the intermediate lines are the stage prints; values are the real
stream result):

```
── start BLUE (generation 1) ──
  gateway → blue
── pre-boot GREEN (generation 2) as a warm standby ──
  green warm on :18092 (not yet serving public traffic)
── CUT OVER: gateway re-claims the public port → GREEN ──
  gateway → green  (cut over)
── request stream across the platform swap ──
  total: 50  errors: 0  answers: blue green  segments(uniq-runs): 2

PASS 09_platform_swap  (blue-green is for the PLATFORM; apps stay hot; ≤1 in-flight drop at cutover)
```

The final line is the assertion verdict: 50 requests, at most one error, exactly
two segments, both generations seen.

## Exercises

Each changes only `blue_green.sh` (or the caps in `scoped.sh`); predict the
verdict before you look.

1. **Flip before green is warm.** Move `gw_to "$GREEN_PORT"` to *before* the
   `wait_up "$GREEN_PORT"` line. Predict the stream and the verdict. → The
   gateway is re-pointed at a backend that is not yet accepting connections, so
   the probes in that window return `ERR`. With more than one error the
   `errs -le 1` conjunct fails, and if green is slow enough the blue segment may
   be cut short too. `FAIL`. The lesson: a standby must be genuinely serving, not
   merely started — "pre-boot green" exists precisely so the flip is not a boot.

2. **Drop the re-point (kill without rebinding).** Change `gw_to` to only kill
   the old listener and not bind a new one — e.g. comment out the `socat … & GWPID=$!`
   line. Predict the verdict. → After the cutover, nothing listens on `19090`, so
   every remaining request errors; `errs` far exceeds 1 and `runs` never reaches 2
   (green is never seen). `FAIL`. The lesson: the *constant bound port* is the
   whole mechanism. A gap in the listener is an outage, not a swap.

3. **Make the generations indistinguishable.** Start green with the same label as
   blue: change `run_node bl-green "$GREEN_PORT" green` to
   `... "$GREEN_PORT" blue`. Predict `answers`, `segments`, and the verdict. →
   The stream still sees 50 clean answers, but every one is `blue` and `uniq`
   collapses them to a single segment (`runs = 1`); the `grep -q green` and
   `runs -eq 2` conjuncts both fail. `FAIL`. The lesson: the assertion demands a
   *real* transition between two distinct generations — a swap that never swaps
   is not a pass.

4. **Flap the gateway.** After the cutover, re-point back: add
   `gw_to "$BLUE_PORT"` immediately after the green re-point line. Predict
   `segments` and the verdict. → The stream now visits blue → green → blue, so
   `uniq` yields **three** segments and `runs -eq 2` fails. `FAIL`. The lesson:
   the bar is not just "no outage", it is "exactly one transition" — flapping is
   its own kind of failure, and the single-versus-many distinction is what
   `segments(uniq-runs)` measures.

5. **Remove the swap cap and watch the thesis.** In `podman/scoped.sh` (or the
   `run.sh` caps), drop `MemorySwapMax=0` and raise `MemoryMax` to something
   absurd. Predict what changes. → Nothing in the verdict — but you have just
   given a container-booting demo permission to exhaust physical memory and spill
   into zram, which is the exact condition that twice froze the agent host. The
   lesson is the containment section itself: on a shared machine the *caps*, not
   the workload's good behaviour, are what keep a runaway inside its own blast
   radius.
