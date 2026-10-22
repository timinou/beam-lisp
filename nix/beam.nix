# Keep the pinned OTP/Elixir sources, using the current nixpkgs builders.
# The private beamLib and packagesWith APIs were removed upstream.
{ pkgs, otp-src, elixir-src }:
let
  erlangBuilder = import (pkgs.path + "/pkgs/development/interpreters/erlang/generic-builder.nix") {
    version = "29.0.1";
    wxSupport = false;
    systemdSupport = false;
  };
  erlang = (pkgs.callPackage erlangBuilder { }).overrideAttrs (_: {
    src = otp-src;
    installTargets = [ "install" ];
  });
  elixirBuilder = import (pkgs.path + "/pkgs/development/interpreters/elixir/generic-builder.nix") {
    version = "1.20.4";
    hash = null;
    minimumOTPVersion = "27";
    maximumOTPVersion = "29";
  };
  elixir = (pkgs.callPackage elixirBuilder { inherit erlang; debugInfo = true; }).overrideAttrs (_: {
    src = elixir-src;
  });
in
{ inherit erlang elixir; }
