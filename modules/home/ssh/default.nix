{
  config,
  lib,
  pkgs,
  namespace,
  ...
}:
let
  hm = config.lib;
in

{

  home.file.".ssh/config".text = ''
    Include ${lib.replaceStrings [ "$\{XDG_RUNTIME_DIR}" ] [ "/run/user/1000" ] config.age.secrets."ssh/topsap-config".path}
    Include ${lib.replaceStrings [ "$\{XDG_RUNTIME_DIR}" ] [ "/run/user/1000" ] config.age.secrets."ssh/work-config".path}
    Include ${lib.replaceStrings [ "$\{XDG_RUNTIME_DIR}" ] [ "/run/user/1000" ] config.age.secrets."ssh/default-config".path}

    Host *
      ForwardAgent no
      AddKeysToAgent no
      Compression no
      ServerAliveInterval 60
      ServerAliveCountMax 3
      HashKnownHosts no
      UserKnownHostsFile ~/.ssh/known_hosts
      ControlMaster auto
      ControlPath ~/.ssh/sockets/%r@%h-%p
      ControlPersist 10m

    Host github.com
      Hostname github.com
      IdentityFile ~/.ssh/id_ed25519
      # Specifies that ssh should only use the identity file explicitly configured above
      # required to prevent sending default identity files first.
      IdentitiesOnly yes
  '';

  # 确保 ControlMaster 的 socket 目录存在
  home.activation.createSshSocketsDir = hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p ~/.ssh/sockets
    chmod 700 ~/.ssh/sockets
  '';

}
