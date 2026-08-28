{
  lib,
  pkgs,
  inputs,
  ...
}:
let
  inherit (inputs) deepseek-harness-src;

  # ---- Moraxyc kernel 链（官方 dsh CLI）----
  importPnpmLock = (import ../../pkgs/dsh-moraxyc/importPnpmLock/package.nix {
    inherit lib;
    inherit (pkgs) stdenvNoCC fetchurl fetchgit fetchPnpmDeps runCommand pnpm writers;
  });
  dshWorkspacePatchHook = pkgs.callPackage ../../pkgs/dsh-moraxyc/dshWorkspacePatchHook/package.nix { };
  dsh-workspace = pkgs.callPackage ../../pkgs/dsh-moraxyc/dsh-workspace/package.nix {
    inherit deepseek-harness-src importPnpmLock dshWorkspacePatchHook dsh-landlock-run;
  };
  dsh-landlock-run = pkgs.callPackage ../../pkgs/dsh-moraxyc/dsh-landlock-run/package.nix { inherit dsh-workspace; };
  dsh-kernel = pkgs.callPackage ../../pkgs/dsh-moraxyc/dsh-kernel/package.nix { inherit dsh-workspace; };

  # ---- composition 层：官方 bundles + dsh 组合 -------
  buildDshBundle = (import ../../pkgs/dsh-moraxyc-lib/mk-dsh-bundle.nix {
    inherit (pkgs) lib buildNpmPackage jq nodejs nodejs-slim pnpm_11 stdenvNoCC writeShellApplication writers;
  });
  bundles = {
    base = buildDshBundle.fromWorkspace (_: {
      pname = "dsh-base";
      packageName = "@deepseek-ai/dsh-base";
      inherit dsh-kernel dsh-workspace;
      linkKernelNodeModules = dsh-kernel;
      runtimeDeps = [ pkgs.ripgrep ] ++ lib.optionals pkgs.stdenvNoCC.hostPlatform.isLinux [ pkgs.bubblewrap ];
      meta = { description = "Foundation shared by all dsh profiles"; homepage = "https://github.com/deepseek-ai/deepseek-harness"; license = lib.licenses.mit; platforms = lib.platforms.unix; };
    });
    headless = buildDshBundle.fromWorkspace (_: {
      pname = "dsh-headless";
      packageName = "@deepseek-ai/dsh-headless";
      inherit dsh-kernel dsh-workspace;
      linkKernelNodeModules = dsh-kernel;
      meta = { description = "Run dsh without a graphical interface"; homepage = "https://github.com/deepseek-ai/deepseek-harness"; license = lib.licenses.mit; platforms = lib.platforms.unix; };
    });
    web-app = buildDshBundle.fromWorkspace (_: {
      pname = "dsh-web-app";
      packageName = "@deepseek-ai/dsh-web-app";
      inherit dsh-kernel dsh-workspace;
      linkKernelNodeModules = dsh-kernel;
      artifacts = [
        { source = "frontends/web"; target = "lib/node_modules/@deepseek-ai/dsh-web-frontend"; }
      ];
      passthru = { requiresWeb = true; };
      meta = { description = "Web interface for dsh"; homepage = "https://github.com/deepseek-ai/deepseek-harness"; license = lib.licenses.mit; platforms = lib.platforms.unix; };
    });
  };

  dshBundleCheckHook = pkgs.callPackage ../../pkgs/dsh-moraxyc/dshBundleCheckHook/package.nix { };
  dsh = pkgs.callPackage ../../pkgs/dsh-moraxyc/dsh/package.nix {
    inherit buildDshBundle bundles dsh-kernel dshBundleCheckHook;
    inherit dsh;
  };
in
dsh
