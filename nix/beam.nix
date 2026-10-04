# OTP 29 + Elixir 1.20 on the pinned nixpkgs' toolchain (glibc of the pin).
{ pkgs, otp-src, elixir-src }:
let
  erlang0 = pkgs.beam.beamLib.callErlang
    ({ mkDerivation }: mkDerivation {
      version = "29.0.1";
      src = otp-src;
    })
    { parallelBuild = true; wxSupport = false; systemdSupport = false; };
  # no man/html docs in a server drop
  erlang = erlang0.overrideAttrs (_: { installTargets = [ "install" ]; });
  elixir = (pkgs.beam.packagesWith erlang).elixir_1_18.override {
    version = "1.20.2";
    src = elixir-src;
    minimumOTPVersion = "27";
  };
in
{ inherit erlang elixir; }
