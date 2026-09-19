# Bootstrap — from bare VPS to living node

> Day 0 is the only imperative day. This document is the whole of it: one
> flake, one command, one systemd unit — and then the machine is declarative
> forever.

## The rule of two strata

> **Nix declares what must exist for the node to boot.
> Datom declares what may change while it runs.**

Bootstrap is entirely below the line, so bootstrap is entirely Nix.

## The flake

One repository describes every node you will ever run:

```nix
# flake.nix (sketch)
{
  outputs = { self, nixpkgs, disko, ... }: {
    nixosConfigurations.vps-1 = nixpkgs.lib.nixosSystem {
      modules = [ disko.nixosModules.disko ./nodes/vps-1.nix ];
    };
  };
}
```

`nodes/vps-1.nix` declares, completely:

- **disk layout** (disko) — btrfs, a subvolume for `/var/lib/beam-lisp`
- **firewall** — nftables: 22 (provisioning ssh, disabled after day 0),
  2222 (bl ssh), 80/443 (gateway), cluster ports on the private interface
- **users** — one `beam-lisp` user, no login
- **the unit** — `bl-node.service`: execs the bl closure, hardening per
  `docs/deployment-os-floor.md` (`ProtectSystem=strict`,
  `NoNewPrivileges=true`, read-write only its data dir)
- **the gateway unit** — `bl-gateway.service`: the small OS process that holds
  :80/:443 (`vm/gateway.bl` runs outside the node on purpose — see
  `zero-downtime.md`)

Nothing else. The flake *is* the machine's below-OTP identity; the same flake,
evaluated per hostname, is the whole fleet (`fleet.md`).

## The one command

```
nixos-anywhere --flake .#vps-1 root@<ip>
```

Disko partitions, NixOS installs, the unit starts. There is no step 2.

## The birth transaction

First boot is the node's one act of self-declaration. It transacts:

```clojure
{:host       "vps-1"
 :born-at    1790000000000
 :bl-version "2026.4"
 :flake-rev  "a1b2c3"}
```

then generates its CA (`vm/ca.bl`), opens the capped ssh executor on :2222
(`executor/ssh.bl`), and asks the reconciler for its slice of desired state.
A fresh cluster bootstraps datom empty; a joining node syncs from its peers.

From this moment the machine is convergent. Every later change arrives as data
— a flake commit (below) or a transaction (above) — never as a hand on the
box.

## Joining a fleet

A second VPS runs the same command with a **join token**: a Biscuit attenuated
to `:fleet/join`, minted by an existing operator key. The token lets the new
node do exactly one thing — introduce itself and sync datom. Everything it
later runs comes from its reconciled slice of desired state, RLS-partitioned
to its hostname.

Revoking a machine is retracting its membership datom: its tokens stop
verifying, its routes are re-claimed elsewhere, its slice of desired state
redistributes.

## What bootstrap deliberately does not do

- no configuration of services — that is above the line, in datom
- no secrets on disk — secrets are env-fork vars, minted after the CA exists
- no golden images — the flake is smaller than any image and truer: it cannot
  drift from what is deployed, because it *is* what is deployed

## The recovery posture

Bootstrap doubles as disaster recovery. A dead node is reprovisioned by the
same command; the node then restores datom from the latest S3 checkpoint
(`backups-and-dr.md`) and converges. The test that this works is the restore
drill — a scheduled function, not a document.
