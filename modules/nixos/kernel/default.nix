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
      CachyOS 7.3.3 server 内核（BBR 作为默认拥塞控制）。

      这段 override 与 nix-config-vps 的服务端配置逐字相同：同一个
      nix-cachyos-kernel rev + 同一套 override 才得到同一个内核派生
      （= 已构建并推到 zrubing.cachix.org 的那份）。任何一台机器换上它都只是
      替代，不重编整颗内核。改这里就必须三处（本模块 / zen14 / nova13）一起看，
      因为它们共用同一个派生。
    '';
  };

  config = lib.mkIf cfg.enable {
    # 本仓库钉的 nix-cachyos-kernel rev 里 version.json 还停在 7.2.0，所以覆盖
    # 版本三件套（源码 tarball / config / patch 集）。取值与上游 master 的
    # version.json（linux-cachyos-server）逐字相同，因此升 flake input 之后
    # 删掉 override、改回 `pkgs.cachyosKernels.linuxPackages-cachyos-server`
    # 得到的仍是同一个内核派生。
    #
    # bbr3 = true → CONFIG_TCP_CONG_BBR=y、CONFIG_DEFAULT_TCP_CONG="bbr"：BBR
    # 编进内核并作为默认拥塞控制。桌面侧不再加 net.* sysctl，队列规则用内核默认值。
    boot.kernelPackages = pkgs.linuxKernel.packagesFor (
      pkgs.cachyosKernels.linux-cachyos-server.override {
        version = "7.3.3";

        src = pkgs.fetchurl {
          url = "https://github.com/CachyOS/linux/releases/download/cachyos-7.3.3-1/cachyos-7.3.3-1.tar.gz";
          hash = "sha256-VKUHF2vCscTIoU8IetoI+S1HPGryjs/D6a2x1cYgIKw=";
        };

        cachyosConfigFile = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/CachyOS/linux-cachyos/55c2df2a43ac1908dc7e5722f6b22508b0e8e55e/linux-cachyos-server/config";
          hash = "sha256-gftW/jJmEqDcRwX8XsMJ0EvP/7SH2wy1hDkY/pKVGSc=";
        };

        cachyosPatchesSrc = pkgs.fetchgit {
          url = "https://github.com/CachyOS/kernel-patches.git";
          rev = "706b5652a82404eb2a75c79da3b726eec07a5642";
          rootDir = "7.3/";
          hash = "sha256-zVriutJQGugyguVAwl3l0m2e6ylGBDKsqyLWdwC7b5E=";
        };

        bbr3 = true;
      }
    );
  };
}
