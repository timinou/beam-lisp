# flake.nix — the below-OTP stratum as one evaluable value.
#
# This is the DECLARATIVE ARTIFACT the VPS design's `bootstrap.md` refers to:
# everything a bl node needs to boot, and nothing else. It is not applied in
# the spike host (which has `nix` but not `nixos-rebuild`); it stands as the
# concrete shape of the design's rule —
#
#   Nix declares what must exist for the node to boot.
#   Datom declares what may change while it runs.
#
# The whole machine below OTP is here; the whole machine above OTP is datoms
# transacted into the running node (see the sibling .bl spikes).
{
  description = "A bl VPS node — the below-OTP stratum";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
  };

  outputs = { self, nixpkgs, disko, ... }: {
    nixosConfigurations.vps-1 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ({ pkgs, ... }: {
          # ── disk: one btrfs pool, a nodatacow subvolume for datom ──────────
          disko.devices.disk.main = {
            device = "/dev/sda";
            type = "disk";
            content.type = "gpt";
            content.partitions = {
              ESP = { size = "512M"; type = "EF00";
                      content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; }; };
              root = { size = "100%";
                       content = { type = "btrfs";
                                   subvolumes."/var/lib/beam-lisp" =
                                     { mountpoint = "/var/lib/beam-lisp"; mountOptions = [ "nodatacow" ]; }; }; };
            };
          };

          # ── the firewall: the one kernel surface, declared, never hand-touched
          networking.firewall = {
            enable = true;
            allowedTCPPorts = [ 80 443 2222 ];   # gateway + capped bl ssh
            # cluster distribution ports ride the private interface only
          };

          # ── one user, no login; the node runs as itself ────────────────────
          users.users.beam-lisp = { isSystemUser = true; group = "beam-lisp"; };
          users.groups.beam-lisp = { };

          # ── the gateway: a SEPARATE OS process holding :80/:443 ────────────
          #    (its separateness is what makes the node blue/green swap seamless
          #     — see zero-downtime.md; the spike models the swap in 04_*.bl)
          systemd.services.bl-gateway = {
            description = "bl gateway — reverse proxy by Host:, TLS by name";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "/run/current-system/sw/bin/bl gateway run";
              User = "beam-lisp";
              Restart = "always";
              AmbientCapabilities = "CAP_NET_BIND_SERVICE";   # bind 80/443 unprivileged
            };
          };

          # ── the node: the long-lived BEAM, everything-above-OTP lives here ──
          systemd.services.bl-node = {
            description = "bl node — the whole machine, above OTP";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "/run/current-system/sw/bin/bl node run";
              User = "beam-lisp";
              Restart = "always";
              StateDirectory = "beam-lisp";
              # hardening floor (docs/deployment-os-floor.md)
              ProtectSystem = "strict";
              ReadWritePaths = "/var/lib/beam-lisp";
              NoNewPrivileges = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              PrivateTmp = true;
            };
          };

          system.stateVersion = "24.11";
        })
      ];
    };
  };
}
