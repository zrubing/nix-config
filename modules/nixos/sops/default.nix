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
  # ⚠️ 历史遗留：zot 已退役（2026-08-14），该网络不再有消费者，仅保留声明以免
  #    删除 secrets 时 nixos-rebuild 报错。新集群用下面的 sg-prod 网络。
  sops.secrets."easytier/zen-sg/network_secret" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };
  sops.secrets."easytier/zen-sg/peer" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };

  # 新集群 hinihao-sg-prod 的 EasyTier 网络（2026-10-11 起，zen14 加入该集群）。
  #
  # ⚠️ 为什么这三个值（含 peer 的公网 IP）放 sops 而不是 lib/constants.nix：
  #    本仓库是**公开 GitHub 仓库**（git@github.com:zrubing/nix-config.git），
  #    peer 里的公网 IP 写进代码即全球可见。放 sops 后代码里只有占位符，
  #    值在运行期从 /run/secrets 读出（0600 root，非全局可读）。
  #    —— 与既有的 easytier/ali/* 同款做法（那里 peer 也是 tcp://<IP>:11010）。
  sops.secrets."easytier/sg-prod/network_name" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };
  sops.secrets."easytier/sg-prod/network_secret" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };
  sops.secrets."easytier/sg-prod/peer" = {
    sopsFile = "${mysecrets}/secrets/env.yaml";
  };

}
