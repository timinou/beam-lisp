# The self-contained `bl` drop, built entirely inside nix (no network, no Mix).
#
# It runs the same sequence as .github/workflows/release.yml's linux leg
# (deps -> bl build -> z3 -> bl self-build), with every input pinned and fetched
# by nix: hex tarballs (bl.lock digests), crates (Cargo.lock, vendored), the
# pinned z3 zip and explorer's precompiled NIF. The toolchain (OTP 29, Elixir
# 1.20, rustc, gcc) comes from the pinned nixpkgs, so every ELF the drop carries
# is linked against THAT glibc. docs/native-bundler.md, "Nix-built server drop".
#
# Final step: ELF files are rewritten to the FHS loader (/lib64/ld-linux-x86-64.so.2)
# with no RUNPATH, so the drop does not depend on /nix/store paths existing on
# the target. On NixOS that loader is nix-ld's, which resolves libc from the HOST:
# the host's glibc must therefore be >= the drop's symbol floor, which is the point.
{ pkgs, rustPkgs, self, erlang, elixir }:
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

  # ── crates: one merged vendor dir for every Cargo.lock we build ──────────────
  crateLocks = [
    ../native/bl_json/Cargo.lock
    ../native/code_embed/Cargo.lock
    ../native/datom_datalog/Cargo.lock
    ../native/datom_fjall/Cargo.lock
    ../native/datom_vector/Cargo.lock
    ../native/lazy_memo/Cargo.lock
    ../tooling/drop/Cargo.lock
  ];
  vendors = map (l: pkgs.rustPlatform.importCargoLock { lockFile = l; }) crateLocks;
  vendorDir = pkgs.runCommand "bl-cargo-vendor" { } ''
    mkdir -p $out
    for v in ${toString vendors}; do
      for c in $v/*; do
        n=$(basename $c)
        [ "$n" = Cargo.lock ] && continue
        [ -e $out/$n ] || ln -s $(readlink -f $c) $out/$n
      done
    done
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

  # The checkout, as the build needs it. wry_webview (gtk/webkit, desktop only)
  # is left out: a server drop does not carry it, and `wry/*` reads as ABSENT.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../bin ../priv ../env.bl ../bl.lock
      ../native/bl_json ../native/code_embed ../native/datom_datalog
      ../native/datom_fjall ../native/datom_vector ../native/lazy_memo
      ../tooling/drop
    ];
  };

  bl-drop = pkgs.stdenv.mkDerivation {
    pname = "bl-drop";
    version = "0.1.0";
    inherit src;
    nativeBuildInputs = [ erlang elixir rustPkgs.rustc rustPkgs.cargo pkgs.gcc pkgs.patchelf pkgs.binutils pkgs.unzip pkgs.git pkgs.gnutar pkgs.gzip pkgs.findutils ];
    dontConfigure = true;
    dontFixup = true; # the drop is one opaque file

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR/home XDG_CACHE_HOME=$TMPDIR/home/.cache
      export BL_DAEMON=off LANG=C.UTF-8 ELIXIR_ERL_OPTIONS="+fnu"
      export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=${pkgs.stdenv.cc}/bin/cc
      export CARGO_HOME=$TMPDIR/cargo CARGO_NET_OFFLINE=true CARGO_TARGET_DIR=$TMPDIR/cargo-target
      export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=$TMPDIR/rp-cache
      export EXPLORER_USE_LEGACY_ARTIFACTS=false
      mkdir -p $HOME $XDG_CACHE_HOME/beam_lisp $CARGO_HOME $RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH

      cat > $CARGO_HOME/config.toml <<EOF
      [source.crates-io]
      replace-with = "vendored"
      [source.vendored]
      directory = "${vendorDir}"
      [net]
      offline = true
      EOF

      cp ${explorerNif} $RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH/libexplorer-v0.12.0-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz
      cp -r ${hexStore} $XDG_CACHE_HOME/beam_lisp/lib
      chmod -R u+w $XDG_CACHE_HOME/beam_lisp/lib

      # the writable working copy bin/bl builds inside (it links .bl/ + build/ into the tree)
      cp -r $src $TMPDIR/tree && chmod -R u+w $TMPDIR/tree
      cd $TMPDIR/tree
      patchShebangs bin

      # the launcher + pack tool; the launcher is the file the target executes
      cargo build --release --offline --manifest-path tooling/drop/Cargo.toml

      # the one native the boot itself needs (see release.yml "Bootstrap the native crates")
      mkdir -p priv/native
      cargo build --release --offline --manifest-path native/lazy_memo/Cargo.toml
      install -m755 $CARGO_TARGET_DIR/release/liblazy_memo.so priv/native/lazy_memo.so

      ./bin/bl deps verify
      ./bin/bl deps compile
      ./bin/bl build --force

      # pinned z3, laid out as `bl install z3` leaves it
      unzip -q ${z3} -d $TMPDIR/z3
      mkdir -p priv/z3/bin
      cp $TMPDIR/z3/*/bin/z3 $TMPDIR/z3/*/bin/libz3.so priv/z3/bin/
      cp $TMPDIR/z3/*/LICENSE.txt priv/z3/
      echo 7288c49a5bd6dbafd7b0b0d1f65956b91672da24b08f09242919af159be3418e > priv/z3/.fetched

      # the launcher the target executes: FHS loader, no store RUNPATH
      cp $CARGO_TARGET_DIR/release/drop-launcher $TMPDIR/launcher
      cp $CARGO_TARGET_DIR/release/drop $TMPDIR/drop
      chmod u+w $TMPDIR/launcher
      patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --remove-rpath $TMPDIR/launcher

      ./bin/bl self-build --bin $TMPDIR/launcher --out $TMPDIR/selfbuilt.drop --jobs $NIX_BUILD_CORES

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
{ inherit bl-drop; }
