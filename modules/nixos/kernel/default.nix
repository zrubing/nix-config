{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  cfg = config.${namespace}.kernel.cachyos;
in
{
  options.${namespace}.kernel.cachyos = with lib; {
    enable = mkEnableOption ''
      CachyOS 7.3.0 server 内核（BBR 作为默认拥塞控制）。

      这段 override 与 nix-config-vps 的服务端配置逐字相同：同一个
      nix-cachyos-kernel rev + 同一套 override 才得到同一个内核派生
      （= 已构建并推到 zrubing.cachix.org 的那份）。任何一台机器换上它都只是
      替代，不重编整颗内核。改这里就必须三处（本模块 / zen14 / nova13）一起看，
      因为它们共用同一个派生。
    '';
  };

  config = lib.mkIf cfg.enable {
    # 上游 flake 的 version.json 稳定线还停在 7.2.11、7.3 只有 rc，而 CachyOS
    # 自己的 7.3 分支已是 7.3.0 正式版，所以覆盖版本三件套（源码 tarball /
    # config / patch 集）。等上游 stable 提到 7.3 后，删掉 override、改回
    # `pkgs.cachyosKernels.linuxPackages-cachyos-server`。
    #
    # bbr3 = true → CONFIG_TCP_CONG_BBR=y、CONFIG_DEFAULT_TCP_CONG="bbr"：BBR
    # 编进内核并作为默认拥塞控制。桌面侧不再加 net.* sysctl，队列规则用内核默认值。
    boot.kernelPackages = pkgs.linuxKernel.packagesFor (
      pkgs.cachyosKernels.linux-cachyos-server.override {
        version = "7.3.0";

        src = pkgs.fetchurl {
          url = "https://github.com/CachyOS/linux/releases/download/cachyos-7.3.0-2/cachyos-7.3.0-2.tar.gz";
          hash = "sha256-y3CpbBP0kSMDZlltcmmPUZL5B+bEV+8lsD0o6syZojo=";
        };

        cachyosConfigFile = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/CachyOS/linux-cachyos/e76369fe53901040b306fe813497277750e13f78/linux-cachyos-server/config";
          hash = "sha256-gftW/jJmEqDcRwX8XsMJ0EvP/7SH2wy1hDkY/pKVGSc=";
        };

        cachyosPatchesSrc = pkgs.fetchgit {
          url = "https://github.com/CachyOS/kernel-patches.git";
          rev = "6266b5f33f4e8caaa452174f0132c8c82f919267";
          rootDir = "7.3/";
          hash = "sha256-ofHoJDLnuwjt7LMLlYzLDoKt1wwTD+YQhiY1j9hQWuE=";
        };

        bbr3 = true;
      }
    );
  };
}
