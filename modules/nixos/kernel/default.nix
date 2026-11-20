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
      CachyOS 7.3.5 server 内核（BBR 作为默认拥塞控制）。

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
        version = "7.3.5";

        src = pkgs.fetchurl {
          url = "https://github.com/CachyOS/linux/releases/download/cachyos-7.3.5-2/cachyos-7.3.5-2.tar.gz";
          hash = "sha256-uyKtmeEEL66IO6txNm+DOTZ7dMBFAE/pKtSSMzkJLgc=";
        };

        cachyosConfigFile = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/CachyOS/linux-cachyos/6c4d2ba46a5ed60c88c7d49c77b0fd1c500c2df5/linux-cachyos-server/config";
          hash = "sha256-ZFljMB3bv37+lN3rjqRKJl+reUYufr4688YKlP17Peg=";
        };

        cachyosPatchesSrc = pkgs.fetchgit {
          url = "https://github.com/CachyOS/kernel-patches.git";
          rev = "664442dd1a913ef8838453828d26ae13b2e7334d";
          rootDir = "7.3/";
          hash = "sha256-yH6bT7EYPTP9ecaYk+JG771JSYkQgRtSlY0QWq5/VJ4=";
        };

        bbr3 = true;
      }
    );
  };
}
