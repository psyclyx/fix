{
  lib,
  stdenv,
  cpu ? "baseline",
  release ? "fast",
  zig_0_16,
  mercurial,
  openssh,
  gnutar,
  installShellFiles,
  makeWrapper,
}:
let
  zig = zig_0_16;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "fix";
  version = "0.3.0";
  # Only the files the build actually consumes (mirrors build.zig.zon's
  # `.paths`), so unrelated churn — .git, .zig-cache, zig-out, result*,
  # bench/, docs/ — does not invalidate the build or bloat the src copy.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../LICENSE
      ../LICENSES
      ../build.zig
      ../build.zig.zon
      ../model
      ../src
      ../test
      ../tools
    ];
  };

  zigDeps = zig.fetchDeps {
    inherit (finalAttrs) pname version src;
    hash = "sha256-Pn++iuvuuqwRQJ+0dHQXJZx4QliNfUzh49wdhukNvgc=";
  };

  postConfigure = ''
    ln -s $zigDeps $ZIG_GLOBAL_CACHE_DIR/p
  '';

  nativeBuildInputs = [
    zig.hook
    installShellFiles
    makeWrapper
  ];

  # The direnv library (`use fix` / `use fix_flake`) is a plain shell file, so
  # it installs on every platform. Completions need to run the freshly-built
  # binary, so they are gated on the host being executable by the builder.
  postInstall = ''
    install -Dm444 ${../contrib/direnv/fix.sh} $out/share/fix/direnv/fix.sh
    install -Dm444 ${../LICENSE} $out/share/licenses/fix/LICENSE
    install -Dm444 ${../LICENSES/nlohmann-json-MIT.txt} $out/share/licenses/fix/nlohmann-json-MIT.txt
    install -Dm444 ${../LICENSES/zig-MIT.txt} $out/share/licenses/fix/zig-MIT.txt
  ''
  + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    installShellCompletion --cmd fix \
      --bash <($out/bin/fix completions bash) \
      --fish <($out/bin/fix completions fish) \
      --zsh <($out/bin/fix completions zsh)
  '';

  # Mercurial, archive extraction, and ssh-ng daemon transport remain
  # subprocess adapters. Git source transport and local-worktree plumbing
  # are both provided by ziggit, a Zig package.
  postFixup = ''
    wrapProgram $out/bin/fix \
      --prefix PATH : ${
        lib.makeBinPath [
          mercurial
          openssh
          gnutar
        ]
      }
  '';

  zigBuildFlags =
    (lib.optional (release != null) "--release=${release}")
    ++ (lib.optional (cpu != null) "-Dcpu=${cpu}");

  dontSetZigCheck = true;
  dontSetZigDefaultFlags = true;

  meta = {
    description = "Blazing fast nix evaluator";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
