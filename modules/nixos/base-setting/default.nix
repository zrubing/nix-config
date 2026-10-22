{ pkgs, ... }:
{
  security.pki.certificateFiles = [
    ../../../certs/ecc-ca.crt
    # nova13 Caddy 本地 CA（tls internal）：信任后 dsh.local 的 HTTPS 证书才有效。
    ../../../certs/caddy-local-nova13.crt
    # zen14 Caddy 本地 CA（tls internal）：信任后 dsh-zen14.local 的 HTTPS 证书才有效。
    # （crypto.randomUUID 等安全上下文 API 需要 HTTPS）
    ../../../certs/caddy-local-zen14.crt
  ];

  # eMudhra 2026-10 事件：8 张中间 CA 证书的私钥因弱随机数（取值 4~237）可被还原，
  # Firefox/Chrome/Apple/微软均已封锁。Mozilla 经 NSS 3.131.1 移除 emSign ECC Root CA - G3，
  # Chrome 定于 2026-10-27 从根库删除。nixpkgs 的 nss-cacert 仍是 3.126，尚未包含该移除，
  # 故在此显式拉黑，避免 OpenSSL 侧（curl / git / PHP / python ssl）继续接受其伪造链。
  # 注意：只影响 NixOS 生成的 CA bundle；Java cacerts、Node/Rust/Go 自带根库、
  # Python certifi、Firefox 自带库需各自更新，不受此项控制。
  security.pki.caCertificateBlacklist = [ "emSign ECC Root CA - G3" ];

  # 26.05 默认切到 dbus-broker；实机升级时容易在 switch/boot 阶段触发已知兼容性问题。
  # 先显式固定为经典 dbus-daemon，等后续确认环境完全兼容后再单独切回 broker。
  services.dbus.implementation = "dbus";

  imports = [ ../../unix/nix-settings ];
}
