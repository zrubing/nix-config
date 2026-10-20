{ inputs, lib, config, pkgs, ... }:
let
  isNixOS = config ? systemd;

  # cargo-nix-plugin（anthropics）：Rust 包的 crate 级构建。
  #
  # 插件给 nix 进程加一个 primop `builtins.resolveCargoWorkspace`，eval 期直接
  # 把 Cargo.lock 解析成 crate 图，每个 crate 一个 buildRustCrate 派生——依赖的
  # 编译结果因此能进 store / 二进制缓存，改自身源码只重建自己的 crate。
  # 相比之下 rustPlatform.buildRustPackage 是「依赖 + 源码」一个派生，任何源码
  # 变动都要全量重编（实测 cliphist-gui：130 个 crate 全编 85 s / 16 核）。
  #
  # ⚠️ 插件 ABI 与 nix 版本严格绑定：版本错配时 nix 启动即报错，所有 nix 命令
  # 不可用。所以 components 不写死，直接从「本系统实际装的 nix」版本推出——
  # 2.35.3 → nixComponents_2_35；nixpkgs 换 nix 版本时两者一起动，不会错配。
  #
  # 用法（packages/<name>/default.nix）：
  #   { inputs, pkgs, ... }:
  #   let cargoNix = inputs.cargo-nix-plugin.lib { inherit pkgs; src = ./.; };
  #   in cargoNix.workspaceMembers.<member>.build
  # 注意：默认（lockfile resolve）模式在 eval 期要联网查 crates.io sparse index，
  # 破坏纯求值（离线重建 / CI 会失败）；这种场景改用
  #   metadata = builtins.readFile ./metadata.json;
  #   cargoLock = builtins.readFile ./Cargo.lock;
  # 的显式模式，把 metadata.json 入库。
  #
  # 实测两个必须补的坑（用 cliphist-gui 全程跑通验证过，产物二进制可执行、链接正常）：
  #   1. 原生库依赖走 crateOverrides：nixpkgs 的 defaultCrateOverrides 已覆盖
  #      gtk4-sys / gdk4-sys / glib-sys / gdk-pixbuf-sys 等常见 crate；冷门的要自己加，
  #      例如 gtk4-layer-shell-sys 需 pkg-config + buildInputs = [ gtk4-layer-shell ]，
  #      否则 system-deps 在沙箱里找不到 .pc 而失败。
  #   2. buildRustCrate 固定 -C opt-level=3、无 LTO、不读 Cargo.toml 的 [profile.*]，
  #      也不会 wrapProgram：同一份源码产物 1.7 MB（原 buildRustPackage 版是
  #      opt-level=s + LTO + panic=abort 的 776 KB），PATH 里的辅助命令
  #      （cliphist / wl-copy / magick / notify-send）得自己 postFixup 包一层。
  #
  # 迁移顺序（重要）：plugin-files 是本次 rebuild 后才进 /etc/nix/nix.conf 的，
  # 所以先把本模块上线，再让包引用 cargoNix；否则求值期没有 primop，直接报错。
  nixComponents =
    pkgs.nixVersions."nixComponents_${
      lib.replaceStrings [ "." ] [ "_" ] (lib.versions.majorMinor config.nix.package.version)
    }";
  cargoNixPlugin = pkgs.callPackage "${inputs.cargo-nix-plugin}/nix/plugin.nix" {
    inherit nixComponents;
  };
in
{
  nix = {
    # 插件只有加载进评估用的 nix 才有 primop；路径指向目录，nix 自己挑 .so。
    settings.plugin-files = lib.mkIf isNixOS [ "${cargoNixPlugin}/lib/nix/plugins" ];
    extraOptions = ''
      trusted-users = root jojo

      extra-substituters = https://devenv.cachix.org https://noctalia.cachix.org
      extra-trusted-public-keys = devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw= noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=
    '';
    # TODO try this?
    # enable = config.host.role != "cloud-server";

    # Disable channels
    channel.enable = false;

    # Pin <nixpkgs> for nix-shell and so on
    nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];

    # Pin nixpkgs in the registry to this flake's version
    registry.nixpkgs.flake = inputs.nixpkgs;

    # From flake-utils-plus
    # TODO enable and delete the line above
    # generateRegistryFromInputs = true;

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      log-lines = 50;
      use-xdg-base-directories = true;
      warn-dirty = false;
      trusted-users = [
        "@wheel"
        "jojo"
      ]; # TODO revise this?

      allow-import-from-derivation = true;
      accept-flake-config = true;
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
        "https://niri.cachix.org"

        "https://numtide.cachix.org"
        "https://cache.numtide.com"
        # lantian（nix-cachyos-kernel）：2026-10-15 起作者遭入侵关停全部服务器
        # （xddxdd/nix-cachyos-kernel#110），恢复后如需再启用这两行。
        # "https://attic.xuyh0120.win/lantian"
        "https://noctalia.cachix.org"

        # dsh 打包仓（Moraxyc/deepseek-harness.nix）自己推的缓存。kernel 从源码构建
        # 整个 monorepo，本地命中它才不用重建 76 个 derivation；dsh-tui 这类 bundle
        # 的 pnpm 构建同样在里面。放末位：它只覆盖 dsh 一族，热路径（nixpkgs）先命中
        # cache.nixos.org，不必让每个 path 都先问一次小缓存。
        "https://deepseek-harness-nix.cachix.org"

        # 自建缓存（cachix 账号 zrubing，公开可读）：放本仓库自有的派生包
        # （cliphist-gui 等 nixpkgs 里没有的东西），zen14 构建后 cachix push，
        # nova13 直接替代、不必重建。nixpkgs 里已有的依赖不必推——两台机器
        # 都从 cache.nixos.org 命中。放在末位，理由同上。
        "https://zrubing.cachix.org"
      ];

      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
        "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        # "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
        "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
        "deepseek-harness-nix.cachix.org-1:5NrkwLN9veNMhiINtU5ZeV4isXFhFsOwn6Ms7J1M+TA="
        "zrubing.cachix.org-1:UhoPG6Vn30/rA1Wb5CB8dWMHH6rnk64J31SSibqxVcA="
      ];
    };

    gc = {
      automatic = lib.mkDefault false;
      options = "--delete-older-than 1d";
    };
  };

  services.fast-nix-gc = lib.mkIf isNixOS {
    enable = lib.mkDefault true;
    automatic = lib.mkDefault false;
    dates = lib.mkDefault "03:15";
    randomizedDelaySec = lib.mkDefault "45min";
    persistent = lib.mkDefault true;
    deleteOlderThan = lib.mkDefault "7d";
    keepRecent = lib.mkDefault "1d";
    extraArgs = lib.mkDefault [ "--delete-old" ];
  };

  # fast-nix-gc 以 root 跑，profile_dirs 默认只扫 /nix/var/nix/profiles。
  # use-xdg-base-directories=true 使 jojo 的 home-manager profile 位于
  # $XDG_STATE_HOME/nix/profiles，不指过去则旧代永远不会被清理
  # （nova13 实测：home-manager 339 代堆积，system 仅 1 代）。
  systemd.services.fast-nix-gc.serviceConfig.Environment = lib.mkIf isNixOS [
    "XDG_STATE_HOME=/home/jojo/.local/state"
  ];
}
