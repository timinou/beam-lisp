# flake.nix — the self-contained `bl` drop, built entirely by nix.
#
# Why: a drop built on a rolling-release workstation links that machine's glibc
# (Arch 2.43), and a NixOS 25.05 host (glibc 2.40) cannot run it. Building the
# drop with the TARGET HOST's nixpkgs makes the drop's glibc floor <= the host's.
# docs/native-bundler.md "Nix-built server drop — glibc floor = host".
#
# nixpkgs is pinned to the SAME rev as apps/foundry/infra/flake.lock (nixos-25.05).
# Keep the two in step: `nix flake lock --override-input nixpkgs <rev>`.
{
  description = "beam-lisp: nix-built self-contained bl drop (glibc floor = host)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/ac62194c3917d5f474c1a844b6fd6da2db95077d";
    # nixos-25.05 ships rustc 1.86; rustler 0.38 needs >= 1.91. Only the Rust
    # TOOLCHAIN comes from here; every link step still uses the pinned gcc + glibc.
    nixpkgs-rust.url = "github:NixOS/nixpkgs/nixos-unstable";
    # nixos-25.05 ships OTP 28 / Elixir 1.18; the language needs OTP 29 / Elixir 1.20.
    # Both are built with the PINNED nixpkgs' toolchain, so their glibc is the pin's.
    otp-src = { url = "github:erlang/otp/OTP-29.0.1"; flake = false; };
    elixir-src = { url = "github:elixir-lang/elixir/v1.20.2"; flake = false; };
  };

  outputs = { self, nixpkgs, nixpkgs-rust, otp-src, elixir-src }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      beam = import ./nix/beam.nix { inherit pkgs otp-src elixir-src; };
      rustPkgs = nixpkgs-rust.legacyPackages.${system};
      drop = import ./nix/bl-drop.nix { inherit pkgs rustPkgs; inherit (beam) erlang elixir; };
    in
    {
      packages.${system} = {
        inherit (beam) erlang elixir;
        bl-drop = drop.bl-drop;
        default = drop.bl-drop;
      };

      # `nix flake check` — the gate (CI runs it too). Fails loudly when the build
      # or its contract (runs; glibc floor <= the servers' 2.40) breaks.
      checks.${system} = {
        # the drop starts and evaluates, with no /nix/store paths on its PATH/LD path
        drop-runs = pkgs.runCommand "bl-drop-runs" { } ''
          export HOME=$TMPDIR/home BL_DAEMON=off
          mkdir -p $HOME
          cp ${drop.bl-drop}/bl.drop ./bl.drop && chmod +x ./bl.drop
          got=$(./bl.drop eval '(+ 1 2)')
          [ "$got" = 3 ] || { echo "drop eval (+ 1 2) = '$got', want 3" >&2; exit 1; }
          touch $out
        '';
        glibc-floor = pkgs.runCommand "bl-glibc-floor" { nativeBuildInputs = [ pkgs.binutils pkgs.findutils ]; } ''
          export DROP_BIN=${drop.drop-tools}/bin/drop
          got=$(sh ${./tooling/drop/glibc-floor.sh} ${drop.bl-drop}/bl.drop)
          echo "$got"
          v=$(echo "$got" | cut -d' ' -f1)
          [ "$(printf '%s\n2.40\n' "$v" | sort -V | tail -1)" = 2.40 ] \
            || { echo "glibc floor $v > 2.40 (the servers' glibc)" >&2; exit 1; }
          touch $out
        '';
      };
    };
}
