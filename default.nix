let
  npins = import ./npins;
  overlay = final: _prev: {
    fix = final.callPackage ./nix/fix.nix {};
  };
in
  {
    nixpkgs ? npins.nixpkgs,
    pkgs ? import nixpkgs {},
  }: let
    finalPkgs = pkgs.extend overlay;
    inherit (finalPkgs) fix;
    vhsDemo = finalPkgs.callPackage ./nix/vhs-demo.nix {inherit fix;};
    bench = finalPkgs.callPackage ./bench/harness.nix {inherit fix;};
    benchFix = finalPkgs.callPackage ./bench/harness.nix {
      inherit fix;
      nix = null;
      detsys = null;
      lix = null;
    };
    demos = {
      explorer = vhsDemo {tape = ./demo/explorer.tape;};
      debugger = vhsDemo {
        tape = ./demo/debugger.tape;
        fixtures."debug-target.nix" = ./demo/debug-target.nix;
      };
      nixosDebugger = vhsDemo {
        tape = ./demo/nixos-debugger.tape;
        environment.NIX_PATH = "nixpkgs=${npins.nixpkgs}";
        fixtures."debug-target.nix" = ./demo/debug-target.nix;
        fixtures."nixos-system.nix" = ./demo/nixos-system.nix;
      };
    };
  in {
    packages = {
      inherit
        fix
        bench
        benchFix
        vhsDemo
        demos
        ;
    };
    inherit overlay;
    shell = import ./shell.nix {pkgs = finalPkgs;};
    default = fix;

    # Flat back-compat aliases: `fix` (and the derived outputs) all come from
    # `finalPkgs.fix`, so the overlay is the single source of truth.
    inherit
      fix
      bench
      benchFix
      vhsDemo
      demos
      ;

    # Import into your system/user config to get `programs.fix.enable` (installs
    # the CLI) and `programs.direnv.fix.enable` (auto-enabled with direnv; adds
    # the `use fix` helper). See contrib/direnv/README.md.
    nixosModules.fix = import ./nix/modules/nixos.nix;
    darwinModules.fix = import ./nix/modules/darwin.nix;
    homeManagerModules.fix = import ./nix/modules/home-manager.nix;
  }
