let
  sources = import ./npins;
in
  {pkgs ? import sources.nixpkgs {}}: let
    # Linux 7.1 dropped linux/scc.h, which zig 0.16.0's bundled libtsan still
    # includes, so -fsanitize-thread cannot build libtsan against our glibc
    # headers (whose linux/ is a symlink into linux-headers).
    #
    # This has to be CPATH: zig builds libtsan as a sub-compilation that
    # ignores -I/-isystem/-idirafter from the outer command, so an env var is
    # the only lever. The directory holds this one header and nothing else, so
    # it cannot shadow any other include.
    #
    # DROP once zig's libtsan no longer includes it.
    tsanSccShim = pkgs.runCommand "tsan-scc-shim" {} ''
      mkdir -p $out/linux
      cp ${pkgs.zig_0_16}/lib/zig/libc/include/any-linux-any/linux/scc.h $out/linux/
    '';
  in
    pkgs.mkShell {
      NIX_PATH = "nixpkgs=${sources.nixpkgs}:home-manager=${pkgs.home-manager.src}";

      CPATH = "${tsanSccShim}";

      packages = [
        pkgs.zig_0_16
        pkgs.tlaplus
        pkgs.coreutils
        pkgs.pkg-config
        pkgs.ripgrep
        pkgs.hyperfine
        pkgs.curl
        pkgs.libgit2
        pkgs.mercurial
        pkgs.gnutar
      ]
      ++ pkgs.lib.optionals pkgs.stdenv.isLinux [pkgs.perf];
    }
