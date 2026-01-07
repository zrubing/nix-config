{
  config,
  lib,
  namespace,
  ...
}:
let
  hm = config.lib;
in
{

  programs.ssh = {
    enable = true;

    enableDefaultConfig = false;

    matchBlocks."*" = {
      forwardAgent = false;
      addKeysToAgent = "no";
      compression = false;
      serverAliveInterval = 60;
      serverAliveCountMax = 3;
      hashKnownHosts = false;
      userKnownHostsFile = "~/.ssh/known_hosts";
      controlMaster = "auto";
      controlPath = "~/.ssh/sockets/%r@%h-%p";
      controlPersist = "10m";
    };

    extraConfig = ''
      Host github.com
        Hostname github.com
        IdentityFile ~/.ssh/id_ed25519
        # Specifies that ssh should only use the identity file explicitly configured above
        # required to prevent sending default identity files first.
        IdentitiesOnly yes
    '';

    includes = [
      # support for fish shell
      (lib.replaceStrings [ "$\{XDG_RUNTIME_DIR}" ] [ "/run/user/1000" ]
        config.age.secrets."ssh/topsap-config".path
      )
      (lib.replaceStrings [ "$\{XDG_RUNTIME_DIR}" ] [ "/run/user/1000" ]
        config.age.secrets."ssh/work-config".path
      )
      (lib.replaceStrings [ "$\{XDG_RUNTIME_DIR}" ] [ "/run/user/1000" ]
        config.age.secrets."ssh/default-config".path
      )
    ];
  };

  # 确保 ControlMaster 的 socket 目录存在
  home.activation.createSshSocketsDir = hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p ~/.ssh/sockets
    chmod 700 ~/.ssh/sockets
  '';

}
