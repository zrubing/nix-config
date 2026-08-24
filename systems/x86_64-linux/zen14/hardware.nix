{ pkgs, ... }:
{
  imports = [ ../../../hardware/zen14.nix ];

  # bootloader
  boot.loader.efi.canTouchEfiVariables = true;

  boot.loader.systemd-boot.enable = false;

  # Pin 到 7.1：kernel 7.2 的 BPF verifier 加固（bpf_set_retval 参数必须为标量，
  # torvalds/linux@b1f7f67b74c2e，v7.2-rc1 合入）导致 Cilium ≤1.20 的 CGroupSock
  # feature probe 被拒、agent fatal CrashLoop。上游修复未 backport，等 Cilium 出
  # 修复版本后再放开。
  # 上游 issue: https://github.com/cilium/cilium/issues/48016
  # 本地事故: 2026-08-23 zen14 升到 7.2.0 后 kube-system/cilium-ddzzb CrashLoopBackOff
  boot.kernelPackages = pkgs.linuxPackages_7_1;

  boot.loader = {
    grub = {
      device = "nodev";
      enable = true;
      efiSupport = true;
      gfxmodeEfi = "640x480";
    };
  };

}
