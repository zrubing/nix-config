{ lib, ... }:
{
  # ssh-agent is used to pull my private secrets repo from github when deploying my nixos config.
  # 这个和下面的冲突了，先关了，不知道是哪个地方的服务
  services.gnome.gcr-ssh-agent.enable = false;
  programs.ssh.startAgent = true;
  programs.ssh = {
    extraConfig = ''
      Host github.com
        Hostname github.com
        IdentityFile /etc/ssh/ssh_host_ed25519_key
        # Specifies that ssh should only use the identity file explicitly configured above
        # required to prevent sending default identity files first.
        IdentitiesOnly yes
    '';
  };

}
