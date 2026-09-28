{
  lib,
  pkgs,
  inputs,
  # dsh-tap bundle 需要本仓库的 llm-pi-ai providers 映射来做构建期合并
  # （理由见 pkgs/bundles/dsh-tap/package.nix 头部）。它是 modules/home/dsh
  # 渲染出的 YAML 文本，必须由调用方传入——routes.nix 的单一事实来源在
  # modules/ 下，pkgs/ 不该反向依赖它。
  #
  # 这里**不给兜底值**：传空映射会让 bundle 悄悄只剩 dsh-tap 自带的
  # codebuddy 一条路由，本仓库那 7 条凭空消失，是最难查的一类退化。
  # 但也不能写成必填参数——Snowfall 会把本目录自动暴露成
  # packages.x86_64-linux.dsh-source 并用 callPackageWith 调用，缺必填参数
  # 直接让整个 flake 的 packages 输出 eval 失败。所以用 throw 做默认值：
  # 不传又没有别的东西逼出 bundles.dsh-tap 时（比如构建 dsh 本体，它只用
  # defaultBundles 的 headless/web-app）行为不变，一旦真的要构建 dsh-tap
  # 就立刻报出这句话。
  dshTapProviders ? throw "packages/dsh-source: 构建 bundles.dsh-tap 必须传入 dshTapProviders（本仓库的 llm-pi-ai providers 映射，见 modules/home/dsh/default.nix 的 llmPiAiProviders）",
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
  # 运行时专用的官方 Node 二进制（见该文件注释：nixpkgs Node 会让
  # node-addon-require-builtin 的机器码扫描失败）。
  dsh-nodejs-bin = pkgs.callPackage ../../pkgs/dsh-moraxyc/dsh-nodejs-bin/package.nix { };

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
    # dsh-tui 不在上游 monorepo 里，是独立仓库 ccch1mneyyy/dsh-TUI 的源码 bundle，
    # 所以走 buildDshBundle 的通用形态而不是 fromWorkspace。
    # 此前这里是死代码：pkgs/dsh-moraxyc/dsh/package.nix 里有 `tuiBundle = bundles.tui`，
    # 但没人定义 bundles.tui——Nix 惰性让它在没有任何 profile 声明 requiresTui 时
    # 一直不报错，一旦声明就 "attribute 'tui' missing"。
    tui = pkgs.callPackage ../../pkgs/bundles/tui/package.nix {
      inherit buildDshBundle dsh-kernel;
    };
    # dsh-tap 自带 dsh.bundle.patch，装成依赖后 dsh plugin 的 reconcile 会把它
    # 并入 profile 的 bundles —— 那条 patch 里就带着（已与我们的路由合并过的）
    # llm-pi-ai 行。三条 profile（web / dsh-tui / headless）都装它，理由见
    # modules/home/dsh 的 llmPiAiProviders 注释。
    dsh-tap = pkgs.callPackage ../../pkgs/bundles/dsh-tap/package.nix {
      inherit buildDshBundle dsh-kernel dshTapProviders;
    };
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
    inherit buildDshBundle bundles dsh-kernel dshBundleCheckHook dsh-nodejs-bin;
    inherit dsh;
  };
in
dsh
