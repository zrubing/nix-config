{ config, inputs, lib, namespace, ... }:
let
  mysecrets = inputs.mysecrets;
  cfg = config.${namespace}.ssh;
in
{
  options.${namespace}.ssh = {
    agentKeyUser = lib.mkOption {
      type = lib.types.str;
      default = "jojo";
      description = ''
        读 agent-skills deploy key 的普通用户（root 另有一份 0400 的）。
        ssh 只接受 owner 为 root 或当前用户的私钥，所以按用户各放一份。
      '';
    };
  };

  config = {
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

    # agent-skills（私有 skill 仓库）的只读凭据。
    # GitHub 的 deploy key 不能跨仓库复用（Key is already in use），所以单独一把；
    # 也不能和 nix-secrets 那把共用一个 host —— GitHub 只认第一个认证成功的 key，
    # 两把一起出示时 agent-skills 会报 Repository not found（2026-11-20 实测），
    # 因此下面用独立 Host 别名 github-agent-skills 只出示这一把。
    #
    # ⚠️ 权限必须 0400：ssh 会拒绝 group/other 可读的私钥（UNPROTECTED PRIVATE KEY
    # FILE，实测 0440 连不上），且只接受 owner 为 root 或自己的文件。
    # 所以 root 和普通用户各一份，同一份密文解出两个文件。
    age.secrets.agent-skills-deploy = {
      file = "${mysecrets}/ssh/agent-skills-deploy.age";
      mode = "0400";
      owner = "root";
    };
    age.secrets.agent-skills-deploy-user = {
      file = "${mysecrets}/ssh/agent-skills-deploy.age";
      mode = "0400";
      owner = cfg.agentKeyUser;
      group = "users";
    };

    programs.ssh = {
      startAgent = true;
      extraConfig = ''
        # 只对 root 生效：/run/agenix/* 是 0400 root，jojo 的交互式 ssh 读不到，
        # 挂全局会让每次 git push 先报一次 Permission denied 再回落。
        #
        # ⚠️ 不能用 `Match user root`：ssh_config 里 Match 的 user 判据比的是
        # **远端用户名**（这里是 git），不是本地用户，写 user root 永远不命中。
        # 2026-10-22 实测：root 那次只加载了 /root/.ssh/id_* 默认身份，
        # /run/agenix/nix-secrets-deploy 根本没出现在 debug 输出里。
        # 判本地用户只能用 exec + %u（%u 展开为本地用户名）。
        #
        # ⚠️ Match 里必须用 originalhost：host 判据比的是 HostName 替换后的名字
        # （github-agent-skills 会变成 github.com），写 host 永远不命中，实测 2026-11-20。
        Match originalhost github.com exec "test %u = root"
          IdentityFile /run/agenix/nix-secrets-deploy
          IdentitiesOnly yes

        # agent-skills 专用别名：只出示它自己的 deploy key，避开 github.com 上的身份冲突。
        # 别名对所有人可用，但 key 文件按本地用户分。
        Host github-agent-skills
          HostName github.com
          User git

        Match originalhost github-agent-skills exec "test %u = root"
          IdentityFile /run/agenix/agent-skills-deploy
          IdentitiesOnly yes

        Match originalhost github-agent-skills exec "test %u != root"
          IdentityFile /run/agenix/agent-skills-deploy-user
          IdentitiesOnly yes
      '';
    };
  };
}
