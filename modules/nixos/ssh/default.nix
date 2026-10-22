{ config, inputs, ... }:
let
  mysecrets = inputs.mysecrets;
in
{
  services.gnome.gcr-ssh-agent.enable = false;

  # root 拉 nix-secrets 的凭据：GitHub repo 级、只读 deploy key。
  #
  # ⚠️ 不要换回 /etc/ssh/ssh_host_ed25519_key（原方案）。主机密钥是「机器身份」，
  # 机器重装 / 换机 / 重生成主机密钥后，GitHub 上那条 deploy key 就作废，恢复手段
  # 是把新主机公钥再注册进 GitHub —— 一个纯本地操作被外部服务卡住。
  # 2026-10-22 就是这么坏的：`sudo nixos-rebuild`（root 身份 fetch）报
  # Permission denied (publickey)，而 jojo 的交互式 git 一切正常。
  #
  # 按主机分文件：吊销粒度到单机，换机器不用动其它机器。
  # 收件人仍是 secrets.nix 的 publicKeys（谁有权解密），与「谁能 fetch」无关。
  age.secrets.nix-secrets-deploy = {
    file = "${mysecrets}/ssh/nix-secrets-deploy-${config.networking.hostName}.age";
    mode = "0400";
    owner = "root";
  };

  programs.ssh = {
    startAgent = true;
    extraConfig = ''
      # 只对 root 生效：/run/agenix/* 是 0400 root，jojo 的交互式 ssh 读不到，
      # 挂全局会让每次 git push 先报一次 Permission denied 再回落。
      Match host github.com user root
        IdentityFile /run/agenix/nix-secrets-deploy
        IdentitiesOnly yes
    '';
  };
}
