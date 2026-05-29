{ pkgs, ... }:
{
  security.pki.certificateFiles = [
    ../../../certs/ecc-ca.crt
  ];

  # 26.05 默认切到 dbus-broker；实机升级时容易在 switch/boot 阶段触发已知兼容性问题。
  # 先显式固定为经典 dbus-daemon，等后续确认环境完全兼容后再单独切回 broker。
  services.dbus.implementation = "dbus";

  imports = [ ../../unix/nix-settings ];
}
