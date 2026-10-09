{
  description = "Opt-in native browser runtime; Wayland first, no containers";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    each = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
  in {
    # No default package: consumers must choose a browser runtime explicitly.
    packages = each (pkgs: rec {
      runtime = runtime-wayland;
      runtime-wayland = pkgs.buildEnv { name = "native-browser-wayland"; paths = [ pkgs.chromium pkgs.sway-unwrapped pkgs.wayvnc ]; };
      runtime-x11 = pkgs.buildEnv { name = "native-browser-x11"; paths = [ pkgs.chromium pkgs.xorg-server pkgs.x11vnc ]; };
    });
    # Entering the development shell does not pull a browser closure.
    devShells = each (pkgs: { default = pkgs.mkShell { packages = [ pkgs.cargo pkgs.rustc ]; }; });
  };
}
