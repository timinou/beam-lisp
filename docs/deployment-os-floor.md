# The OS floor — deployment hardening for beam-lisp nodes

PLAN-047 W7. The capability stack narrows rights **inside** the VM:
Biscuit token → `auth/sandbox-fork` → env caps → the interop gate. This
document is the layer **below** that: what the OS should guarantee about
the one process every sandbox shares.

## Why not gVisor

Rejected (analysis recorded in PLAN-047): `runsc` draws its boundary at
the OS process. Beam-lisp envs are BEAM processes inside **one** OS
process — gVisor cannot see, let alone differentiate, in-VM rights. It
would add syscall-interposition cost to buy a boundary at the wrong
granularity. Reach for it only if the VM itself is distrusted; with the
interop gate total over all four call paths, it isn't.

## What the OS floor is for

Defense in depth against the failures the gate cannot see:

- a NIF or linked-in driver bug (outside the gate's vocabulary entirely)
- an operator mistake that runs untrusted code at `:global`
- resource exhaustion of the *node* (the per-env `max_heap_words` bounds
  handle process-level heap; the unit handles the rest)

## systemd unit (per node-class)

```ini
# /etc/systemd/system/beam-lisp-node.service
[Service]
ExecStart=/opt/beam-lisp/bin/beam_lisp start
User=beam-lisp
Group=beam-lisp

# ── filesystem: the node reads its own tree, writes only its data dir
ProtectSystem=strict
ReadWritePaths=/var/lib/beam-lisp
PrivateTmp=true

# ── no privilege growth, ever
NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=

# ── kernel surface
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true

# ── syscall surface: the BEAM needs no bpf, no mount, no swap
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false   # the JIT needs W^X relaxation — see below
RestrictRealtime=true
RestrictSUIDSGID=true

# ── network: client nodes only; drop entirely for batch nodes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# ── resources: the node-level ceiling under the per-env bounds
MemoryMax=8G
TasksMax=1000000               # BEAM processes are not tasks; this caps threads
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Notes:

- `MemoryDenyWriteExecute=false` is **required** — the BEAM's JIT (OTP
  26+) maps writable-executable pages. If you run `+JPperf false` and
  disable the JIT, flip this to `true` for a real gain.
- `RestrictAddressFamilies` is the knob that turns a node *class* into a
  policy: batch/eval nodes that should never talk to the network get
  `RestrictAddressFamilies=AF_UNIX` and the question "can this sandbox
  exfiltrate?" stops depending on the interop gate alone.
- `ProtectSystem=strict` + `ReadWritePaths=` is the coarse version of
  per-path fs rights. If a deployment ever needs *per-sandbox* path
  nuance (sandbox A may read /data/x, sandbox B may not), that is the
  one case where a [Landlock](https://docs.kernel.org/userspace-api/landlock.html)
  launcher wrapper earns its complexity: a small setuid-root helper that
  applies a Landlock ruleset before `exec`. File a FUP when the need is
  concrete; do not build it ahead of it.

## Verification

```sh
systemd-analyze security beam-lisp-node   # aim: exposure ≤ 2.0
systemctl cat beam-lisp-node              # confirm the drop-ins you think you have
```

The interop gate's deny-corpus (`test/beam_lisp/caps_test.exs`,
`test/bl/auth_caps_test.bl`) proves the in-VM layer; this unit is the
belt under it. Neither substitutes for the other.
