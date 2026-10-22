# The self-contained `bl` drop, built entirely inside nix (no network, no Mix).
#
# It runs the same sequence as .github/workflows/release.yml's linux leg
# (deps -> prepare natives/app -> qualified floor check -> z3 -> self-build), with inputs pinned and fetched
# by nix: hex tarballs (bl.lock digests), crates (Cargo.lock, vendored), the
# pinned z3 zip and explorer's precompiled NIF. The toolchain (OTP 29, Elixir
# 1.20, rustc, gcc) comes from the pinned nixpkgs, so every ELF the drop carries
# is linked against THAT glibc. docs/native-bundler.md, "Nix-built server drop".
#
# Final step: ELF files are rewritten to the FHS loader (/lib64/ld-linux-x86-64.so.2)
# with no RUNPATH, so the drop does not depend on /nix/store paths existing on
# the target. On NixOS that loader is nix-ld's, which resolves libc from the HOST:
# the host's glibc must therefore be >= the drop's symbol floor, which is the point.
{ pkgs, rustPkgs, erlang, elixir }:
let
  inherit (pkgs) lib;

  # ── hex libraries, exactly the digests bl.lock names ─────────────────────────
  lockLines = lib.filter (l: lib.hasPrefix "[:dep " l) (lib.splitString "\n" (builtins.readFile ../bl.lock));
  hexDeps = map
    (l:
      let m = builtins.match "[[]:dep ([^ ]+) ([^ ]+) ([0-9a-f]+) hex[]]" l; in
      assert m != null;
      rec {
        name = builtins.elemAt m 0;
        vsn = builtins.elemAt m 1;
        sha = builtins.elemAt m 2;
        tarball = pkgs.fetchurl {
          url = "https://repo.hex.pm/tarballs/${name}-${vsn}.tar";
          sha256 = sha;
        };
      })
    lockLines;
  # the store layout `bl deps` reads: <name>-<vsn>-<sha8>/ + .hex-sha
  hexStore = pkgs.runCommand "bl-hex-store" { } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (d: ''
      d=$out/${d.name}-${d.vsn}-${builtins.substring 0 8 d.sha}
      t=$(mktemp -d)
      mkdir -p $d
      tar -xf ${d.tarball} -C $t
      tar -xzf $t/contents.tar.gz -C $d
      printf %s ${d.sha} > $d/.hex-sha
      rm -rf $t
    '') hexDeps}
  '';

  # ── crates: one merged vendor dir per Cargo.lock set ─────────────────────────
  mkVendor = name: locks:
    let vs = map (l: pkgs.rustPlatform.importCargoLock { lockFile = l; }) locks; in
    pkgs.runCommand name { } ''
      mkdir -p $out
      for v in ${toString vs}; do
        for c in $v/*; do
          n=$(basename $c)
          [ "$n" = Cargo.lock ] && continue
          [ -e $out/$n ] || ln -s $(readlink -f $c) $out/$n
        done
      done
    '';
  cargoEnv = vendorDir: ''
    export HOME=$TMPDIR/home CARGO_HOME=$TMPDIR/cargo CARGO_NET_OFFLINE=true
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=${pkgs.stdenv.cc}/bin/cc
    mkdir -p $HOME $CARGO_HOME
    cat > $CARGO_HOME/config.toml <<EOF
    [source.crates-io]
    replace-with = "vendored"
    [source.vendored]
    directory = "${vendorDir}"
    [net]
    offline = true
    EOF
  '';

  # Each derivation sees ONLY what it reads, so a change elsewhere cannot rebuild it.
  nativeCrates = [ "bl_json" "code_embed" "datom_datalog" "datom_fjall" "datom_vector" "lazy_memo" ];
  nativeSrc = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions (map (c: ../native + "/${c}") nativeCrates);
  };
  toolSrc = lib.fileset.toSource { root = ../.; fileset = ../tooling/drop; };

  # 1. launcher + pack tool — keyed on tooling/drop only.
  drop-tools = pkgs.stdenv.mkDerivation {
    pname = "bl-drop-tools";
    version = "0.1.0";
    src = toolSrc;
    nativeBuildInputs = [ rustPkgs.rustc rustPkgs.cargo pkgs.gcc ];
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      ${cargoEnv (mkVendor "bl-vendor-tools" [ ../tooling/drop/Cargo.lock ])}
      cargo build --release --offline --manifest-path tooling/drop/Cargo.toml --target-dir $TMPDIR/t
    '';
    installPhase = ''
      install -Dm755 $TMPDIR/t/release/drop-launcher $out/bin/drop-launcher
      install -Dm755 $TMPDIR/t/release/drop $out/bin/drop
    '';
  };

  # 2. the NIFs — keyed on native/** (the six server crates) + their Cargo.locks.
  natives = pkgs.stdenv.mkDerivation {
    pname = "bl-natives";
    version = "0.1.0";
    src = nativeSrc;
    nativeBuildInputs = [ rustPkgs.rustc rustPkgs.cargo pkgs.gcc ];
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      ${cargoEnv (mkVendor "bl-vendor-natives" (map (c: ../native + "/${c}/Cargo.lock") nativeCrates))}
      mkdir -p $out
      for c in ${toString nativeCrates}; do
        # in the crate dir, so its .cargo/config.toml (dynamic_lookup) applies
        (cd native/$c && cargo build --release --offline --target-dir $TMPDIR/t-$c)
        install -m755 $TMPDIR/t-$c/release/lib$c.so $out/$c.so
      done
    '';
    installPhase = "true";
  };

  # `bl build` runs `cargo build --release --target-dir D` per crate and looks for
  # D/release/lib<crate>.so. This answers that one call from the `natives` output
  # (so the bl build step needs no Rust compile); everything else is real cargo.
  cargoShim = pkgs.writeShellScriptBin "cargo" ''
    if [ "$1" = build ] && [ -f ${natives}/$(basename "$PWD").so ]; then
      while [ $# -gt 0 ]; do [ "$1" = --target-dir ] && td=$2; shift; done
      mkdir -p "$td/release"
      cp ${natives}/$(basename "$PWD").so "$td/release/lib$(basename "$PWD").so"
      exit 0
    fi
    exec ${rustPkgs.cargo}/bin/cargo "$@"
  '';

  # ── pinned binary assets ─────────────────────────────────────────────────────
  z3 = pkgs.fetchurl {
    url = "https://github.com/Z3Prover/z3/releases/download/z3-4.16.0/z3-4.16.0-x64-glibc-2.39.zip";
    sha256 = "7288c49a5bd6dbafd7b0b0d1f65956b91672da24b08f09242919af159be3418e";
  };
  # explorer's polars NIF (rustler_precompiled), the non-legacy-CPU build; its
  # sha256 is the one explorer's own checksum file pins. glibc floor 2.35.
  explorerNif = pkgs.fetchurl {
    url = "https://github.com/elixir-explorer/explorer/releases/download/v0.12.0/libexplorer-v0.12.0-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz";
    sha256 = "4315e0dcc03fdd48e4861c5ea02ccf3e65a0a7a2646fad0c57367d1c6eb68114";
  };

  # The SDK's terminal seam is also a Rustler precompiled dependency. Seed its
  # locked-package checksum explicitly: an ordinary derivation must not need
  # Rustler to reach GitHub during `bl deps compile`.
  ratatuiNif = pkgs.fetchurl {
    url = "https://github.com/mcass19/ex_ratatui/releases/download/v0.13.0/libex_ratatui-v0.13.0-nif-2.17-x86_64-unknown-linux-gnu.so.tar.gz";
    sha256 = "95a23a060aadc58adea3fefd724dc7bb8ad4aead3152fac0ee62f130fe510320";
  };

  # The checkout, as the build needs it. wry_webview (gtk/webkit, desktop only)
  # is left out: a server drop does not carry it, and `wry/*` reads as ABSENT.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../bin ../priv ../env.bl ../bl.lock ../scripts/prepare-release.bl
      ../native/bl_json ../native/code_embed ../native/datom_datalog
      ../native/datom_fjall ../native/datom_vector ../native/lazy_memo
      ../tooling/drop/src ../tooling/drop/Cargo.toml ../tooling/drop/Cargo.lock
    ];
  };

  # 3. the bl build + self-build + ELF retarget. Compiles no Rust: NIFs and the
  # launcher come from the two derivations above.
  bl-drop = pkgs.stdenv.mkDerivation {
    pname = "bl-drop";
    version = "0.1.0";
    inherit src;
    nativeBuildInputs = [ erlang elixir cargoShim pkgs.patchelf pkgs.binutils pkgs.unzip pkgs.git pkgs.gnutar pkgs.gzip pkgs.findutils ];
    dontConfigure = true;
    dontFixup = true; # the drop is one opaque file

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR/home XDG_CACHE_HOME=$TMPDIR/home/.cache
      export BL_DAEMON=off LANG=C.UTF-8 ELIXIR_ERL_OPTIONS="+fnu"
      export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=$TMPDIR/rp-cache
      export EXPLORER_USE_LEGACY_ARTIFACTS=false
      mkdir -p $HOME $XDG_CACHE_HOME/beam_lisp $RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH

      cp ${explorerNif} $RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH/libexplorer-v0.12.0-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz
      cp ${ratatuiNif} $RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH/libex_ratatui-v0.13.0-nif-2.17-x86_64-unknown-linux-gnu.so.tar.gz
      cp -r ${hexStore} $XDG_CACHE_HOME/beam_lisp/lib
      chmod -R u+w $XDG_CACHE_HOME/beam_lisp/lib

      # the writable working copy bin/bl builds inside (it links .bl/ + build/ into the tree)
      cp -r $src $TMPDIR/tree && chmod -R u+w $TMPDIR/tree
      cd $TMPDIR/tree
      patchShebangs bin

      # the one native the boot itself needs (see release.yml "Bootstrap the native crates")
      mkdir -p priv/native
      install -m755 ${natives}/lazy_memo.so priv/native/lazy_memo.so

      # Bootstrap commands use the source launcher directly. The native
      # transport client is already built in drop-tools; compiling another
      # client here would attempt a crates.io fetch inside the offline sandbox.
      # Keep the provisioning verb first: the bare bootstrap can run before
      # application dependencies exist. bin/bl recognizes --cold anywhere.
      ./bin/bl deps verify --cold
      ./bin/bl deps compile --cold
      ./bin/bl --cold run scripts/prepare-release.bl
      # Package the source-validated compiler floor. Compiler regeneration is
      # a bare-VM operation, independent of the runtime's retained SDK lease.
      ./bin/bl --cold seed --check

      # pinned z3, laid out as `bl install z3` leaves it
      unzip -q ${z3} -d $TMPDIR/z3
      mkdir -p priv/z3/bin
      cp $TMPDIR/z3/*/bin/z3 $TMPDIR/z3/*/bin/libz3.so priv/z3/bin/
      cp $TMPDIR/z3/*/LICENSE.txt priv/z3/
      echo 7288c49a5bd6dbafd7b0b0d1f65956b91672da24b08f09242919af159be3418e > priv/z3/.fetched

      # the launcher the target executes: FHS loader, no store RUNPATH
      cp ${drop-tools}/bin/drop-launcher $TMPDIR/launcher
      cp ${drop-tools}/bin/drop $TMPDIR/drop
      chmod u+w $TMPDIR/launcher
      patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath $TMPDIR/launcher

      ./bin/bl --cold self-build --reuse-floor --bin $TMPDIR/launcher --out $TMPDIR/selfbuilt.drop --jobs $NIX_BUILD_CORES

      # unpack, retarget every ELF at the FHS loader, repack with the same launcher
      $TMPDIR/drop unpack $TMPDIR/selfbuilt.drop --dir $TMPDIR/payload
      chmod -R u+w $TMPDIR/payload
      find $TMPDIR/payload -type f | while read -r f; do
        if [ "$(head -c4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ]; then
          if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
            patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath "$f"
          else
            patchelf --remove-rpath "$f" 2>/dev/null || true
          fi
        fi
      done
      $TMPDIR/drop pack --release $TMPDIR/payload --launcher $TMPDIR/launcher --out $TMPDIR/bl.drop
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp $TMPDIR/bl.drop $out/bl.drop
      runHook postInstall
    '';
  };
in
{ inherit bl-drop drop-tools natives; }
