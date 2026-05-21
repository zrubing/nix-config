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

  # SG 专用 Zot 上游 registry：zen14 写入公网 TOS/S3，SG 只读同一 backend。
  # 这些 key 只给 zen14 本机 registry 使用，不影响 ali 现有 zot/CI。
  sops.secrets."zot/sg_s3/region" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
    path = "/run/secrets/zot_sg_s3_region";
  };
  sops.secrets."zot/sg_s3/region_endpoint" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
    path = "/run/secrets/zot_sg_s3_region_endpoint";
  };
  sops.secrets."zot/sg_s3/bucket" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
    path = "/run/secrets/zot_sg_s3_bucket";
  };
  sops.secrets."zot/sg_s3/access_key" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
    path = "/run/secrets/zot_sg_s3_access_key";
  };
  sops.secrets."zot/sg_s3/secret_key" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
    path = "/run/secrets/zot_sg_s3_secret_key";
  };

}
