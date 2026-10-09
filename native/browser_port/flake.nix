{
  description = "Native Chromium display runtime; no container engine";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }: let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    each = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
  in {
    packages = each (pkgs: {
      runtime = pkgs.buildEnv { name = "native-browser-runtime"; paths = [ pkgs.chromium pkgs.xorg-server pkgs.x11vnc ]; };
    });
    devShells = each (pkgs: { default = pkgs.mkShell { packages = [ pkgs.cargo pkgs.rustc pkgs.chromium pkgs.xorg-server pkgs.x11vnc ]; }; });
  };
}
