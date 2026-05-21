{
  inputs,
  config,
  ...
}:
let
  mysecrets = inputs.mysecrets;
in
{

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # 注意：新增 EasyTier 网络需要同时在两处声明：
  #   1. 这里（sops.secrets.* 声明 SOPS 解密哪些 key）
  #   2. modules/nixos/easytier/default.nix（sops.templates.* 模板 + instances.* 实例）
  # 缺少任何一处都会导致 nixos-rebuild 失败

  sops.secrets."easytier/ali/network_secret" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };
  sops.secrets."easytier/ali/network_name" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };
  sops.secrets."easytier/ali/peer" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };

  # zen14 ↔ sg 直连 EasyTier 网络（给 build pod push 镜像到 sg zot 用，10.144.210.0/24）
  sops.secrets."easytier/zen-sg/network_secret" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };
  sops.secrets."easytier/zen-sg/peer" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };

}
