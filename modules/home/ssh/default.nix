{
  config,
  lib,
  namespace,
  ...
}:
{

  programs.ssh = {
    enable = true;

    enableDefaultConfig = false;

    matchBlocks."*" = {
      forwardAgent = false;
      addKeysToAgent = "no";
      compression = false;
      serverAliveInterval = 0;
      serverAliveCountMax = 3;
      hashKnownHosts = false;
      userKnownHostsFile = "~/.ssh/known_hosts";
      controlMaster = "no";
      controlPath = "~/.ssh/master-%r@%n:%p";
      controlPersist = "no";
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

}
