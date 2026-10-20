{ pkgs, drop }:
pkgs.runCommand "bl-drop-runs" {
  nativeBuildInputs = [ pkgs.proot ];
} ''
  export HOME=$TMPDIR/home BL_DAEMON=off
  export ELIXIR_ERL_OPTIONS="+fnu +S 2:2 +SDcpu 1:1 +SDio 1"
  mkdir -p "$HOME" "$TMPDIR/fhs/lib64" "$TMPDIR/fhs/bin" "$TMPDIR/fhs/usr/bin"
  ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 "$TMPDIR/fhs/lib64/ld-linux-x86-64.so.2"
  ln -s ${pkgs.bash}/bin/sh "$TMPDIR/fhs/bin/sh"
  ln -s ${pkgs.coreutils}/bin/env "$TMPDIR/fhs/usr/bin/env"
  cp ${drop}/bl.drop ./bl.drop
  chmod +x ./bl.drop
  # The shipped artifact deliberately uses the FHS loader. A strict Nix
  # sandbox has no /lib64; supply that target filesystem without modifying
  # the drop or relaxing the build sandbox. PRoot is a test-only adapter.
  got=$(PROOT_NO_SECCOMP=1 proot -r "$TMPDIR/fhs" \
    -b /nix/store -b "$TMPDIR" -b /dev -b /proc -w "$PWD" \
    ${pkgs.coreutils}/bin/env \
    LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.ncurses pkgs.openssl pkgs.brotli pkgs.zstd ]} \
    ./bl.drop --cold eval '(+ 1 2)')
  [ "$got" = 3 ] || { echo "drop eval = '$got', want 3" >&2; exit 1; }
  touch $out
''
